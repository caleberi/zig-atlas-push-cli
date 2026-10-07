//! JS flow: fetchManifest -> getDownloadURL -> requestArchive -> decompressArchive.
//! Download streams the HTTP body straight into the archive file.
//! Zip extracts into cwd and hoists a common root directory when present.
const std = @import("std");
const builtin = @import("builtin");
const console = @import("console.zig");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const KILOBYTE = 1024;
const PROGRESS_BYTES = 2 * 800000; // ~1.6MB between progress updates
const manifest_url = @import("config").manifest_url;
const package_version = @import("config").package_version;

const InstallError = error{
    OnlyLinux64,
    OnlyMac64,
    OnlyWindows64,
    UnexpectedPlatform,
    ManifestMalformed,
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
        error.HttpStatus => Fail.init(error.HttpStatus),
        error.UnexpectedArchive => Fail.init(error.UnexpectedArchive),
        error.Download => Fail.init(error.Download),
        else => Fail.initFmt(error.Download, "{s}", .{@errorName(e)}),
    };
}

fn appservicesName() []const u8 {
    return if (builtin.os.tag == .windows) "appservices.exe" else "appservices";
}

/// Skip download when cwd already has a matching appservices binary.
fn alreadyCurrent(gpa: Allocator, io: Io) bool {
    const exe = appservicesName();
    _ = Io.Dir.cwd().statFile(io, exe, .{}) catch return false;

    // argv[0] must contain a path separator or spawn resolves via PATH (not cwd).
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = std.process.currentPath(io, &dir_buf) catch return false;
    const binary_path = std.fs.path.join(gpa, &.{ dir_buf[0..dir_len], exe }) catch return false;
    defer gpa.free(binary_path);

    const res = std.process.run(gpa, io, .{
        .argv = &.{ binary_path, "--version" },
    }) catch return false;
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);

    const ok = switch (res.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) return false;
    return std.mem.indexOf(u8, res.stdout, package_version) != null or
        std.mem.indexOf(u8, res.stderr, package_version) != null;
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
    const slice = body.toOwnedSlice() catch |e| return .{ .err = coerceInstall(e) };
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

fn urlFor(info: std.json.Value, tag: []const u8) InstallError![]const u8 {
    const entry = objectField(info, tag) orelse return error.ManifestMalformed;
    const url = objectField(entry, "url") orelse return error.ManifestMalformed;
    if (url != .string) return error.ManifestMalformed;
    return url.string;
}

const ManifestFile = struct {
    version: []const u8,
    info: std.json.Value,
    past_releases: []const PastRelease = &.{},
};

const PastRelease = struct {
    version: []const u8,
    info: std.json.Value,
};

fn getDownloadURL(allocator: Allocator, manifest_json: []const u8) Result([]u8) {
    const tag = platformTag() catch |e| return .{ .err = Fail.init(e) };

    var parsed = std.json.parseFromSlice(ManifestFile, allocator, manifest_json, .{
        .ignore_unknown_fields = true,
    }) catch |e| return .{ .err = coerceInstall(e) };
    defer parsed.deinit();

    const manifest = parsed.value;
    if (!std.mem.eql(u8, manifest.version, package_version)) {
        for (manifest.past_releases) |release| {
            if (std.mem.eql(u8, release.version, package_version)) {
                const u = urlFor(release.info, tag) catch |e| return .{ .err = Fail.init(e) };
                const duped = allocator.dupe(u8, u) catch |e| return .{ .err = coerceInstall(e) };
                return .{ .ok = duped };
            }
        }
    }
    const u = urlFor(manifest.info, tag) catch |e| return .{ .err = Fail.init(e) };
    const duped = allocator.dupe(u8, u) catch |e| return .{ .err = coerceInstall(e) };
    return .{ .ok = duped };
}

fn progressEnabled(io: Io) bool {
    return Io.File.stdout().isTty(io) catch false;
}

fn requestArchive(gpa: Allocator, io: Io, download_url: []const u8) Result([]u8) {
    console.log(io, "downloading appservices cli archive from \"{s}\"", .{download_url});

    const slash = std.mem.lastIndexOfScalar(u8, download_url, '/');
    const archive_name = gpa.dupe(u8, if (slash) |i| download_url[i + 1 ..] else download_url) catch |e| return .{ .err = coerceInstall(e) };
    var owned = true;
    defer if (owned) gpa.free(archive_name);

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = std.Uri.parse(download_url) catch |e| return .{ .err = coerceInstall(e) };
    var req = client.request(.GET, uri, .{
        .headers = .{ .accept_encoding = .{ .override = "identity" } },
    }) catch |e| return .{ .err = Fail.initFmt(error.Download, "Error with http(s) request: {s}", .{@errorName(e)}) };
    defer req.deinit();
    req.sendBodiless() catch |e| return .{ .err = Fail.initFmt(error.Download, "Error with http(s) request: {s}", .{@errorName(e)}) };

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |e| return .{ .err = Fail.initFmt(error.Download, "Error with http(s) request: {s}", .{@errorName(e)}) };
    if (response.head.status.class() != .success) {
        return .{ .err = Fail.initFmt(error.HttpStatus, "Request failed with status code {d}", .{@intFromEnum(response.head.status)}) };
    }

    const out_file = Io.Dir.cwd().createFile(io, archive_name, .{}) catch |e| return .{ .err = coerceInstall(e) };
    defer out_file.close(io);

    var rbuf: [64 * 1024]u8 = undefined;
    var wbuf: [64 * 1024]u8 = undefined;
    var fw = out_file.writer(io, &wbuf);
    const body = response.reader(&rbuf);
    const show_progress = progressEnabled(io);

    var count: u64 = 0;
    var notified_count: u64 = 0;
    while (true) {
        const n = body.stream(&fw.interface, .limited(PROGRESS_BYTES)) catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return .{ .err = Fail.initFmt(error.Download, "Error with http(s) request: {s}", .{@errorName(response.bodyErr() orelse e)}) },
            error.WriteFailed => return .{ .err = Fail.initFmt(error.Download, "Error writing archive: {s}", .{@errorName(e)}) },
        };
        count += n;
        if (show_progress and count - notified_count >= PROGRESS_BYTES) {
            console.write(io, "Received {d} K...\r", .{count / KILOBYTE});
            notified_count = count;
        }
    }
    fw.interface.flush() catch |e| return .{ .err = Fail.initFmt(error.Download, "Error writing archive: {s}", .{@errorName(e)}) };
    console.log(io, "Received {d} K total.", .{count / KILOBYTE});

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

fn chmodAppservices(io: Io) void {
    if (comptime builtin.os.tag != .windows and Io.File.Permissions.has_executable_bit) {
        if (Io.Dir.cwd().openFile(io, appservicesName(), .{})) |bin| {
            defer bin.close(io);
            bin.setPermissions(io, .fromMode(0o755)) catch {};
        } else |_| {}
    }
}

/// Extract zip into cwd and hoist a single common root directory (no staging tree).
fn unzip(gpa: Allocator, io: Io, path: []const u8) !void {
    const cwd = Io.Dir.cwd();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var diagnostics: std.zip.Diagnostics = .{ .allocator = arena };

    {
        var f = try cwd.openFile(io, path, .{});
        defer f.close(io);
        var rbuf: [64 * 1024]u8 = undefined;
        var fr = f.reader(io, &rbuf);
        try std.zip.extract(cwd, &fr, .{ .diagnostics = &diagnostics });
    }

    if (diagnostics.root_dir.len > 0) {
        var wrapper = try cwd.openDir(io, diagnostics.root_dir, .{ .iterate = true });
        defer wrapper.close(io);

        var children: std.ArrayList([]const u8) = .empty;
        var cit = wrapper.iterate();
        while (try cit.next(io)) |child| try children.append(arena, try arena.dupe(u8, child.name));

        for (children.items) |name| {
            cwd.deleteTree(io, name) catch {};
            try wrapper.rename(name, cwd, name, io);
        }
        try cwd.deleteTree(io, diagnostics.root_dir);
    }

    chmodAppservices(io);
}

fn decompressArchive(gpa: Allocator, io: Io, filepath: []const u8) ?Fail {
    if (std.mem.endsWith(u8, filepath, "zip")) {
        unzip(gpa, io, filepath) catch |e| return coerceInstall(e);
        return null;
    }
    if (std.mem.endsWith(u8, filepath, "tar.gz")) {
        untar(io, filepath) catch |e| return coerceInstall(e);
        chmodAppservices(io);
        return null;
    }
    return Fail.initFmt(error.UnexpectedArchive, "could not decompress archive: unexpected archive type for file: {s}", .{filepath});
}

fn execute(gpa: Allocator, io: Io) ?Fail {
    if (alreadyCurrent(gpa, io)) {
        console.log(io, "appservices {s} already present, skipping download.", .{package_version});
        return null;
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const manifest = switch (fetchManifest(arena, io)) {
        .ok => |m| m,
        .err => |f| return f,
    };

    const url_in_arena = switch (getDownloadURL(arena, manifest)) {
        .ok => |u| u,
        .err => |f| return f,
    };

    const url = gpa.dupe(u8, url_in_arena) catch |e| return coerceInstall(e);
    defer gpa.free(url);
    _ = arena_state.reset(.retain_capacity);

    const archive = switch (requestArchive(gpa, io, url)) {
        .ok => |a| a,
        .err => |f| return f,
    };
    defer {
        Io.Dir.cwd().deleteFile(io, archive) catch {};
        gpa.free(archive);
    }

    return decompressArchive(gpa, io, archive);
}

pub fn run(init: std.process.Init) u8 {
    if (execute(init.gpa, init.io)) |f| {
        console.err(init.io, "failed to download Atlas App Services CLI: {s}", .{f.describe()});
        return 1;
    }
    return 0;
}
