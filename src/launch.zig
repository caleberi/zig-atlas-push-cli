const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const prim = @import("primitives/root.zig");
const console = @import("console.zig");

fn onExit(io: Io, child: *std.process.Child) Io.Cancelable!u8 {
    const term = child.wait(io) catch |e| switch (e) {
        error.Canceled => return error.Canceled,
        else => return 1,
    };
    return switch (term) {
        .exited => |code| code,
        else => 1, // killed by signal: node reports a null code, which is !== 0
    };
}

pub fn run(init: std.process.Init, args: []const [:0]const u8) u8 {
    const io = init.io;
    const strings = init.arena.allocator();

    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = std.process.executableDirPath(io, &dir_buf) catch |e| {
        console.err(io, "could not resolve executable directory: {s}", .{@errorName(e)});
        return 1;
    };
    const exe_name = if (builtin.os.tag == .windows) "appservices.exe" else "appservices";
    const binary_path = std.fs.path.join(strings, &.{ dir_buf[0..dir_len], exe_name }) catch return 1;

    var argv = std.ArrayList([]const u8).initCapacity(strings, args.len + 1) catch return 1;
    argv.appendAssumeCapacity(binary_path);
    for (args) |a| argv.appendAssumeCapacity(a);

    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        console.err(io, "failed to spawn {s}: {s}", .{ binary_path, @errorName(e) });
        return 1;
    };

    var exited = prim.zig(io, onExit, .{ io, &child }) catch {
        child.kill(io);
        return 1;
    };
    return exited.await(io) catch 1;
}
