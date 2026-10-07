//! JS flow: fetchManifest -> getDownloadURL -> requestArchive -> decompressArchive.
//! The download is the only stage that was stream-driven in JS (`stream.on('data')`),
//! so it is built from the primitives: a producer routine reads the HTTP body into
//! a buffered `Channel`, a consumer routine writes chunks to disk and reports
//! progress, and a `WaitGroup` joins them.
const std = @import("std");
const builtin = @import("builtin");
const prim = @import("primitives/root.zig");
const console = @import("console.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

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

fn Error(comptime T: type) type {
    return struct {
        @"error": T,
        detail_buf: [1024]u8 = undefined,
        detail: ?[]const u8 = null,

        const Self = @This();

        pub fn init(err: T) Self {
            return .{ .@"error" = err };
        }

        pub fn initFmt(err: T, comptime fmt: []const u8, args: anytype) Self {
            var self: Self = .{ .@"error" = err };
            self.detail = std.fmt.bufPrint(&self.detail_buf, fmt, args) catch null;
            return self;
        }

        pub fn describe(self: *const Self) []const u8 {
            return switch (self.@"error") {
                error.OnlyLinux64 => "Only Linux 64 bits supported.",
                error.OnlyMac64 => "Only Mac 64 bits supported.",
                error.OnlyWindows64 => "Only Windows 64 bits supported.",
                error.UnexpectedPlatform => "Unexpected platform or architecture.",
                error.UnexpectedArchive, error.Download, error.HttpStatus => self.detail orelse @errorName(self.@"error"),
                else => @errorName(self.@"error"),
            };
        }
    };
}

const Fail = Error(InstallError);

fn Result(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: Fail,
    };
}

fn coerceInstall(e: anyerror) Fail {
    return switch (e) {
        error.OnlyLinux64 => Fail.init(error.OnlyLinux64),
        error.OnlyMac64 => Fail.init(error.OnlyMac64),
        error.OnlyWindows64 => Fail.init(error.OnlyWindows64),
        error.UnexpectedPlatform => Fail.init(error.UnexpectedPlatform),
        error.ManifestMalformed => Fail.init(error.ManifestMalformed),
        error.PackageTomlMalformed => Fail.init(error.PackageTomlMalformed),
        error.HttpStatus => Fail.init(error.HttpStatus),
        error.UnexpectedArchive => Fail.init(error.UnexpectedArchive),
        error.Download => Fail.init(error.Download),
        else => Fail.initFmt(error.Download, "{s}", .{@errorName(e)}),
    };
}

fn fetchManifest(allocator: Allocator, io: Io) Result([]u8) {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var body: Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    const res = client.fetch(.{
        .location = .{ .url = manifest_url },
        .response_writer = &body.writer,
    }) catch |e| return .{ .err = coerceInstall(e) };

    if (res.status.class() != .success) {
        return .{ .err = Fail.initFmt(
            error.HttpStatus,
            "Request failed with status code {d}",
            .{@intFromEnum(res.status)},
        ) };
    }
    const slice = body.toOwnedSlice() catch |e| return .{
        .err = coerceInstall(e),
    };
    return .{ .ok = slice };
}

fn platformTag() InstallError![]const u8 {
    const arch = builtin.cpu.arch;
    return switch (builtin.os.tag) {
        .linux => switch (arch) {
            .x86_64 => "linux-amd64",
            .aarch64 => "linux-arm64",
            else => error.OnlyLinux64,
        },
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

fn urlFor(info: ?std.json.Value, tag: []const u8) InstallError![]const u8 {
    const v = info orelse return error.ManifestMalformed;
    const entry = objectField(v, tag) orelse return error.ManifestMalformed;
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
fn readPackageToml(allocator: Allocator, io: Io) ![]u8 {
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    if (std.process.executableDirPath(io, &dir_buf)) |dir_len| {
        const toml_path = try std.fs.path.join(allocator, &.{ dir_buf[0..dir_len], "package.toml" });
        defer allocator.free(toml_path);
        if (Io.Dir.cwd().readFileAlloc(
            io,
            toml_path,
            allocator,
            .limited(1 << 20),
        )) |bytes| return bytes else |_| {}
    } else |_| {}
    return Io.Dir.cwd().readFileAlloc(io, "package.toml", allocator, .limited(1 << 20));
}

fn getDownloadURL(allocator: Allocator, io: Io, manifest_json: []const u8) Result([]u8) {
    const tag = platformTag() catch |e| return .{ .err = Fail.init(e) };

    var manifest = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        manifest_json,
        .{},
    ) catch |e| return .{ .err = coerceInstall(e) };
    defer manifest.deinit();

    const pkg_bytes = readPackageToml(allocator, io) catch |e| return .{ .err = coerceInstall(e) };
    defer allocator.free(pkg_bytes);

    const pkg_version = tomlStringField(pkg_bytes, "version") catch |e| return .{ .err = Fail.init(e) };
    const manifest_version = objectField(manifest.value, "version") orelse return .{ .err = Fail.init(error.ManifestMalformed) };
    if (manifest_version != .string) return .{ .err = Fail.init(error.ManifestMalformed) };

    if (!std.mem.eql(u8, manifest_version.string, pkg_version)) {
        if (objectField(manifest.value, "past_releases")) |past| {
            if (past == .array) for (past.array.items) |release| {
                const v = objectField(release, "version") orelse continue;
                if (v == .string and std.mem.eql(u8, v.string, pkg_version)) {
                    const u = urlFor(objectField(release, "info"), tag) catch |e| return .{ .err = Fail.init(e) };
                    const duped = allocator.dupe(u8, u) catch |e| return .{ .err = coerceInstall(e) };
                    return .{ .ok = duped };
                }
            };
        }
    }
    const u = urlFor(objectField(manifest.value, "info"), tag) catch |e| return .{ .err = Fail.init(e) };
    const duped = allocator.dupe(u8, u) catch |e| return .{ .err = coerceInstall(e) };
    return .{ .ok = duped };
}

const Chunk = struct {
    len: usize,
    data: [16 * 1024]u8,
};

const Shared = struct {
    gpa: Allocator,
    url: []const u8,
    // using this is just solving for a non-existing problem
    // using a direct download is actually more efficient
    ch: prim.Channel(Chunk),
    failed: ?Fail = null,
};

fn produce(io: Io, s: *Shared) Io.Cancelable!void {
    produceInner(io, s) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => {
            if (s.failed == null) {
                s.failed = Fail.initFmt(error.Download, "Error with http(s) request: {s}", .{@errorName(e)});
            }
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
        s.failed = Fail.initFmt(error.HttpStatus, "Request failed with status code {d}", .{@intFromEnum(response.head.status)});
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
            if (s.failed == null) {
                s.failed = Fail.initFmt(error.Download, "Error writing archive: {s}", .{@errorName(e)});
            }
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

fn requestArchive(gpa: Allocator, io: Io, download_url: []const u8) Result([]u8) {
    console.log(io, "downloading appservices cli archive from \"{s}\"", .{download_url});

    const slash = std.mem.lastIndexOfScalar(u8, download_url, '/');
    const archive_name = gpa.dupe(u8, if (slash) |i| download_url[i + 1 ..] else download_url) catch |e| return .{ .err = coerceInstall(e) };
    var owned = true;
    defer if (owned) gpa.free(archive_name);

    const buffer = gpa.alloc(Chunk, 8) catch |e| return .{ .err = coerceInstall(e) };
    defer gpa.free(buffer);

    var shared: Shared = .{
        .gpa = gpa,
        .url = download_url,
        .ch = prim.Channel(Chunk).initBuffered(buffer),
    };

    const out_file = Io.Dir.cwd().createFile(io, archive_name, .{}) catch |e| return .{ .err = coerceInstall(e) };
    defer out_file.close(io);

    var wg = prim.WaitGroup.init(io);
    var joined = false;
    defer if (!joined) wg.cancel();
    wg.zig(produce, .{ io, &shared }) catch |e| return .{ .err = coerceInstall(e) };
    wg.zig(consume, .{ io, &shared, out_file }) catch |e| return .{ .err = coerceInstall(e) };
    wg.join() catch |e| return .{ .err = coerceInstall(e) };
    joined = true;

    if (shared.failed) |f| return .{ .err = f };
    fixFilePermissions(io, out_file) catch |e| return .{ .err = coerceInstall(e) };
    owned = false;
    return .{ .ok = archive_name };
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

fn decompressArchive(gpa: Allocator, io: Io, filepath: []const u8) ?Fail {
    if (std.mem.endsWith(u8, filepath, "zip")) {
        unzip(gpa, io, filepath) catch |e| return coerceInstall(e);
        return null;
    }
    if (std.mem.endsWith(u8, filepath, "tar.gz")) {
        untar(io, filepath) catch |e| return coerceInstall(e);
        return null;
    }
    return Fail.initFmt(error.UnexpectedArchive, "could not decompress archive: unexpected archive type for file: {s}", .{filepath});
}

/// Runs the install pipeline. Returns a populated `Fail` on error, `null` on success.
fn execute(gpa: Allocator, io: Io) ?Fail {
    const manifest = switch (fetchManifest(gpa, io)) {
        .ok => |m| m,
        .err => |f| return f,
    };
    defer gpa.free(manifest);

    const url = switch (getDownloadURL(gpa, io, manifest)) {
        .ok => |u| u,
        .err => |f| return f,
    };
    defer gpa.free(url);

    const archive = switch (requestArchive(gpa, io, url)) {
        .ok => |a| a,
        .err => |f| return f,
    };
    defer gpa.free(archive);

    return decompressArchive(gpa, io, archive);
}

pub fn run(init: std.process.Init) u8 {
    if (execute(init.gpa, init.io)) |f| {
        console.err(init.io, "failed to download Atlas App Services CLI: {s}", .{f.describe()});
        return 1;
    }
    return 0;
}
