//! JS flow: fetchManifest -> getDownloadURL -> requestArchive -> decompressArchive.
//! The download is the only stage that was stream-driven in JS (`stream.on('data')`),
//! so it is built from the primitives: a producer routine reads the HTTP body into
//! a buffered `Channel`, a consumer routine writes chunks to disk and reports
//! progress, and a `WaitGroup` joins them.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const prim = @import("primitives/root.zig");

const console = @import("console.zig");

const KILOBYTE = 1024;
const MAX_BYTES_READ = 800000;
const manifest_url = @import("config").manifest_url;

const InstallError = error{
    OnlyLinux64,
    OnlyMac64,
    OnlyWindows64,
    UnexpectedPlatform,
    ManifestMalformed,
    PackageTomlMalformed,
    HttpStatus,
    UnexpectedArchive,
    Download,
};

var detail_buf: [1024]u8 = undefined;
var detail: ?[]const u8 = null;

fn setDetail(comptime fmt: []const u8, args: anytype) void {
    detail = std.fmt.bufPrint(&detail_buf, fmt, args) catch null;
}

fn describe(e: anyerror) []const u8 {
    return switch (e) {
        error.OnlyLinux64 => "Only Linux 64 bits supported.",
        error.OnlyMac64 => "Only Mac 64 bits supported.",
        error.OnlyWindows64 => "Only Windows 64 bits supported.",
        error.UnexpectedPlatform => "Unexpected platform or architecture.",
        error.UnexpectedArchive, error.Download, error.HttpStatus => detail orelse @errorName(e),
        else => @errorName(e),
    };
}

fn fetchManifest(gpa: Allocator, io: Io) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(gpa);
    defer body.deinit();

    const res = try client.fetch(.{
        .location = .{ .url = manifest_url },
        .response_writer = &body.writer,
    });
    if (res.status.class() != .success) {
        setDetail("Request failed with status code {d}", .{@intFromEnum(res.status)});
        return error.HttpStatus;
    }
    return body.toOwnedSlice();
}

fn platformTag() InstallError![]const u8 {
    const arch = builtin.cpu.arch;
    return switch (builtin.os.tag) {
        .linux => switch (arch) {
            .x86_64 => "linux-amd64",
            .aarch64 => "linux-arm64",
            else => error.OnlyLinux64,
        },
        // The JS maps both 'darwin' and 'freebsd' to the darwin builds; kept as-is.
        .macos, .freebsd => switch (arch) {
            .x86_64 => "darwin-amd64",
            .aarch64 => "darwin-arm64",
            else => error.OnlyMac64,
        },
        .windows => if (arch == .x86_64) "windows-amd64" else error.OnlyWindows64,
        else => error.UnexpectedPlatform,
    };
}

fn objectField(v: std.json.Value, key: []const u8) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get(key);
}

fn urlFor(info: ?std.json.Value, tag: []const u8) ![]const u8 {
    const entry = objectField(info orelse return error.ManifestMalformed, tag) orelse return error.ManifestMalformed;
    const url = objectField(entry, "url") orelse return error.ManifestMalformed;
    if (url != .string) return error.ManifestMalformed;
    return url.string;
}

/// Minimal TOML string-field reader for `package.toml` (version = "x.y.z").
fn tomlStringField(bytes: []const u8, key: []const u8) InstallError![]const u8 {
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (!std.mem.startsWith(u8, line, key)) continue;
        var rest = std.mem.trim(u8, line[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t");
        if (rest.len < 2 or rest[0] != '"') return error.PackageTomlMalformed;
        const end = std.mem.indexOfScalar(u8, rest[1..], '"') orelse return error.PackageTomlMalformed;
        return rest[1 .. 1 + end];
    }
    return error.PackageTomlMalformed;
}

/// Prefer package.toml next to this binary (npm keeps package.json next to install.js);
/// fall back to cwd for `zig build postinstall` from the project root before install.
fn readPackageToml(gpa: Allocator, io: Io) ![]u8 {
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(io, &dir_buf)) |dir_len| {
        const beside = try std.fs.path.join(gpa, &.{ dir_buf[0..dir_len], "package.toml" });
        defer gpa.free(beside);
        if (Io.Dir.cwd().readFileAlloc(io, beside, gpa, .limited(1 << 20))) |bytes| return bytes else |_| {}
    } else |_| {}
    return Io.Dir.cwd().readFileAlloc(io, "package.toml", gpa, .limited(1 << 20));
}

fn getDownloadURL(gpa: Allocator, io: Io, manifest_json: []const u8) ![]u8 {
    const tag = try platformTag();

    var manifest = try std.json.parseFromSlice(std.json.Value, gpa, manifest_json, .{});
    defer manifest.deinit();

    // if (manifest.version !== packageMetadata.version) { look in past_releases }
    // this was selected for package.json which we will turn into a toml file for this
    // purpose.
    const pkg_bytes = try readPackageToml(gpa, io);
    defer gpa.free(pkg_bytes);
    const pkg_version = try tomlStringField(pkg_bytes, "version");

    const manifest_version = objectField(manifest.value, "version") orelse return error.ManifestMalformed;
    if (manifest_version != .string) return error.ManifestMalformed;

    if (!std.mem.eql(u8, manifest_version.string, pkg_version)) {
        if (objectField(manifest.value, "past_releases")) |past| {
            if (past == .array) for (past.array.items) |release| {
                const v = objectField(release, "version") orelse continue;
                if (v == .string and std.mem.eql(u8, v.string, pkg_version)) {
                    return gpa.dupe(u8, try urlFor(objectField(release, "info"), tag));
                }
            };
        }
    }
    return gpa.dupe(u8, try urlFor(objectField(manifest.value, "info"), tag));
}

const Chunk = struct {
    len: usize,
    data: [16 * 1024]u8,
};

const Shared = struct {
    gpa: Allocator,
    url: []const u8,
    ch: prim.Channel(Chunk),
    failed: ?anyerror = null,
};

fn produce(io: Io, s: *Shared) Io.Cancelable!void {
    produceInner(io, s) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => {
            setDetail("Error with http(s) request: {s}", .{@errorName(e)});
            s.failed = error.Download;
        },
    };
    s.ch.close(io) catch return error.Canceled;
}

fn produceInner(io: Io, s: *Shared) !void {
    var client: std.http.Client = .{ .allocator = s.gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(s.url);
    var req = try client.request(.GET, uri, .{
        // We want the archive bytes untouched.
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status.class() != .success) {
        setDetail("Request failed with status code {d}", .{@intFromEnum(response.head.status)});
        s.failed = error.HttpStatus;
        return;
    }

    var transfer_buf: [4 * 1024]u8 = undefined;
    const body = response.reader(&transfer_buf);
    while (true) {
        var chunk: Chunk = .{ .len = 0, .data = undefined };
        chunk.len = body.readSliceShort(&chunk.data) catch |e| return response.bodyErr() orelse e;
        if (chunk.len == 0) return;
        s.ch.send(io, chunk) catch |e| switch (e) {
            error.Closed => return,
            error.Canceled => return error.Canceled,
        };
    }
}

fn consume(io: Io, s: *Shared, file: Io.File) Io.Cancelable!void {
    consumeInner(io, s, file) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => {
            setDetail("Error writing archive: {s}", .{@errorName(e)});
            s.failed = error.Download;
            s.ch.close(io) catch return error.Canceled;
        },
    };
}

fn consumeInner(io: Io, s: *Shared, file: Io.File) !void {
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = file.writer(io, &wbuf);

    var count: u64 = 0;
    var notified_count: u64 = 0;
    while (true) {
        const chunk = s.ch.receive(io) catch |e| switch (e) {
            error.Closed => break,
            error.Canceled => return error.Canceled,
        };
        try fw.interface.writeAll(chunk.data[0..chunk.len]);
        count += chunk.len;
        if (count - notified_count > MAX_BYTES_READ) {
            console.write(io, "Received {d} K...\r", .{count / KILOBYTE});
            notified_count = count;
        }
    }
    try fw.interface.flush();
    if (s.failed == null) console.log(io, "Received {d} K total.", .{count / KILOBYTE});
}

fn fixFilePermissions(io: Io, file: Io.File) !void {
    if (comptime builtin.os.tag != .windows and Io.File.Permissions.has_executable_bit) {
        const st = try file.stat(io);
        if (st.permissions.toMode() & 0o100 == 0) {
            try file.setPermissions(io, .fromMode(0o755));
        }
    }
}

fn requestArchive(gpa: Allocator, io: Io, download_url: []const u8) ![]u8 {
    console.log(io, "downloading appservices cli archive from \"{s}\"", .{download_url});

    const slash = std.mem.lastIndexOfScalar(u8, download_url, '/');
    const archive_name = try gpa.dupe(u8, if (slash) |i| download_url[i + 1 ..] else download_url);
    errdefer gpa.free(archive_name);

    const buffer = try gpa.alloc(Chunk, 8);
    defer gpa.free(buffer);

    var shared: Shared = .{
        .gpa = gpa,
        .url = download_url,
        .ch = prim.Channel(Chunk).initBuffered(buffer),
    };

    const out_file = try Io.Dir.cwd().createFile(io, archive_name, .{});
    defer out_file.close(io);

    var wg = prim.WaitGroup.init(io);
    errdefer wg.cancel();
    try wg.zig(produce, .{ io, &shared });
    try wg.zig(consume, .{ io, &shared, out_file });
    try wg.join();

    if (shared.failed) |e| return e;
    try fixFilePermissions(io, out_file);
    return archive_name;
}

fn untar(io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    var f = try cwd.openFile(io, path, .{});
    defer f.close(io);

    var rbuf: [16 * 1024]u8 = undefined;
    var fr = f.reader(io, &rbuf);
    var dbuf: [std.compress.flate.max_window_len]u8 = undefined;
    var gz = std.compress.flate.Decompress.init(&fr.interface, .gzip, &dbuf);

    try std.tar.extract(io, cwd, &gz.reader, .{ .strip_components = 1 });
}

const stage_dir = ".appservices-extract";

fn unzip(gpa: Allocator, io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.deleteTree(io, stage_dir);
    try cwd.createDirPath(io, stage_dir);
    defer cwd.deleteTree(io, stage_dir) catch {};

    {
        var f = try cwd.openFile(io, path, .{});
        defer f.close(io);
        var rbuf: [16 * 1024]u8 = undefined;
        var fr = f.reader(io, &rbuf);
        var stage = try cwd.openDir(io, stage_dir, .{});
        defer stage.close(io);
        try std.zip.extract(stage, &fr, .{});
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var stage = try cwd.openDir(io, stage_dir, .{ .iterate = true });
    defer stage.close(io);

    var wrappers: std.ArrayList([]const u8) = .empty;
    var it = stage.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .directory) try wrappers.append(arena, try arena.dupe(u8, entry.name));
    }

    for (wrappers.items) |wrapper_name| {
        var wrapper = try stage.openDir(io, wrapper_name, .{ .iterate = true });
        defer wrapper.close(io);

        var children: std.ArrayList([]const u8) = .empty;
        var cit = wrapper.iterate();
        while (try cit.next(io)) |child| try children.append(arena, try arena.dupe(u8, child.name));

        for (children.items) |name| {
            cwd.deleteTree(io, name) catch {}; // overwrite semantics, like decompress()
            try wrapper.rename(name, cwd, name, io);
        }
    }

    if (comptime builtin.os.tag != .windows and Io.File.Permissions.has_executable_bit) {
        if (cwd.openFile(io, "appservices", .{})) |bin| {
            defer bin.close(io);
            bin.setPermissions(io, .fromMode(0o755)) catch {};
        } else |_| {}
    }
}

fn decompressArchive(gpa: Allocator, io: Io, filepath: []const u8) !void {
    if (std.mem.endsWith(u8, filepath, "zip")) return unzip(gpa, io, filepath);
    if (std.mem.endsWith(u8, filepath, "tar.gz")) return untar(io, filepath);
    setDetail("could not decompress archive: unexpected archive type for file: {s}", .{filepath});
    return error.UnexpectedArchive;
}

fn execute(gpa: Allocator, io: Io) !void {
    const manifest = try fetchManifest(gpa, io);
    defer gpa.free(manifest);

    const url = try getDownloadURL(gpa, io, manifest);
    defer gpa.free(url);

    const archive = try requestArchive(gpa, io, url);
    defer gpa.free(archive);

    try decompressArchive(gpa, io, archive);
}

pub fn run(init: std.process.Init) u8 {
    execute(init.gpa, init.io) catch |e| {
        console.err(io_of(init), "failed to download Atlas App Services CLI: {s}", .{describe(e)});
        return 1;
    };
    return 0;
}

inline fn io_of(init: std.process.Init) Io {
    return init.io;
}
