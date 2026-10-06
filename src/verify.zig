const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

const console = @import("console.zig");

fn kindOf(io: Io, path: []const u8) ?Io.File.Kind {
    const st = Io.Dir.cwd().statFile(
        io,
        path,
        .{ .follow_symlinks = false },
    ) catch return null;
    return st.kind;
}

fn directoryExists(io: Io, path: []const u8) bool {
    return kindOf(io, path) == .directory;
}

fn fileExists(io: Io, path: []const u8) bool {
    return kindOf(io, path) == .file;
}

fn removeFolder(io: Io, path: []const u8) !void {
    try Io.Dir.cwd().deleteTree(io, path);
}

fn tmpDir(environ: *const std.process.Environ.Map) []const u8 {
    const keys = if (builtin.os.tag == .windows) [_][]const u8{ "TEMP", "TMP" } else [_][]const u8{ "TMPDIR", "TMP" };
    for (keys) |k| if (environ.get(k)) |v| if (v.len > 0) return v;
    return if (builtin.os.tag == .windows) "C:\\Windows\\Temp" else "/tmp";
}

fn checkSpawn(io: Io, result: std.process.RunResult) error{SpawnFailed}!void {
    if (result.stdout.len > 0) {
        console.writeRaw(io, false, result.stdout);
        console.writeRaw(io, false, "\n");
    }
    if (result.stderr.len > 0) {
        console.writeRaw(io, true, result.stderr);
        console.writeRaw(io, true, "\n");
    }
    const ok = switch (result.term) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        console.err(io, "Failed when spawning.", .{});
        return error.SpawnFailed;
    }
}

fn copyFile(io: Io, src: []const u8, dst: []const u8) !void {
    const cwd = Io.Dir.cwd();
    try cwd.copyFile(src, cwd, dst, io, .{});
}

pub fn run(init: std.process.Init) u8 {
    const io = init.io;
    const strings = init.arena.allocator();

    const temp_install_path = std.fs.path.join(strings, &.{ tmpDir(init.environ_map), "baas-cli-test" }) catch return 1;

    if (directoryExists(io, temp_install_path)) {
        console.log(io, "Deleting directory '{s}'.", .{temp_install_path});
        removeFolder(io, temp_install_path) catch |e| {
            console.err(io, "Could not delete folder '{s}': {s}", .{ temp_install_path, @errorName(e) });
            return 1;
        };
    }

    Io.Dir.cwd().createDir(io, temp_install_path, .default_dir) catch |e| {
        console.err(io, "Could not create folder '{s}': {s}", .{ temp_install_path, @errorName(e) });
        return 1;
    };

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const self_len = std.process.executablePath(io, &exe_buf) catch |e| {
        console.err(io, "could not resolve self path: {s}", .{@errorName(e)});
        return 1;
    };
    const self_path = exe_buf[0..self_len];

    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = std.process.executableDirPath(io, &dir_buf) catch return 1;
    const package_toml_src = std.fs.path.join(strings, &.{ dir_buf[0..dir_len], "package.toml" }) catch return 1;
    const package_toml_dst = std.fs.path.join(strings, &.{ temp_install_path, "package.toml" }) catch return 1;

    copyFile(io, package_toml_src, package_toml_dst) catch |e| {
        // Fall back to project-root package.toml when running from zig-cache before install.
        copyFile(io, "package.toml", package_toml_dst) catch {
            console.err(io, "Could not copy package.toml: {s}", .{@errorName(e)});
            return 1;
        };
    };

    if (builtin.os.tag == .windows) {
        io.sleep(.fromMilliseconds(2000), .awake) catch return 1;
    }

    const gpa = init.gpa;
    const res = std.process.run(gpa, io, .{
        .argv = &.{ self_path, "--postinstall" },
        .cwd = .{ .path = temp_install_path },
    }) catch |e| {
        console.err(io, "Failed when spawning: {s}", .{@errorName(e)});
        return 1;
    };
    defer gpa.free(res.stdout);
    defer gpa.free(res.stderr);
    checkSpawn(io, res) catch return 1;

    const exe_name = if (builtin.os.tag == .windows) "appservices.exe" else "appservices";
    const executable = std.fs.path.join(strings, &.{ temp_install_path, exe_name }) catch return 1;

    if (fileExists(io, executable)) {
        console.log(io, "Atlas App Services CLI installed fine.", .{});
    } else {
        console.err(io, "Atlas App Services CLI did not install correctly, file '{s}' was not found.", .{executable});
        return 2;
    }

    removeFolder(io, temp_install_path) catch {
        console.err(io, "Could not delete folder '{s}'.", .{temp_install_path});
    };
    return 0;
}
