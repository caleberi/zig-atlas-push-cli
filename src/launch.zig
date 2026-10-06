//! Script 1 of 3: the `bin` entry point (bin.js).
//!
//! JS: resolve `appservices[.exe]` next to the script, spawn it with the
//! caller's argv and inherited stdio, and exit with the child's exit code.
//! `onExit(child)` returns a Promise; here it is a `routine.zig` future.
const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;
const prim = @import("primitives/root.zig");

const console = @import("console.zig");

/// onExit(childProcess): Promise<void> that rejects with the exit code.
/// Future payload is `u8`: 0 means resolved, anything else is the rejection.
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
    const gpa = init.gpa;

    // const __dirname = path.dirname(fileURLToPath(import.meta.url));
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir_len = std.process.executableDirPath(io, &dir_buf) catch |e| {
        console.err(io, "could not resolve executable directory: {s}", .{@errorName(e)});
        return 1;
    };
    const exe_name = if (builtin.os.tag == .windows) "appservices.exe" else "appservices";
    const binary_path = std.fs.path.join(gpa, &.{ dir_buf[0..dir_len], exe_name }) catch return 1;
    defer gpa.free(binary_path);

    // const args = process.argv.slice(2);
    var argv = std.ArrayList([]const u8).initCapacity(gpa, args.len + 1) catch return 1;
    defer argv.deinit(gpa);
    argv.appendAssumeCapacity(binary_path);
    for (args) |a| argv.appendAssumeCapacity(a);

    // spawn(binaryPath, args, { stdio: [stdin, stdout, stderr] })
    var child = std.process.spawn(io, .{
        .argv = argv.items,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |e| {
        console.err(io, "failed to spawn {s}: {s}", .{ binary_path, @errorName(e) });
        return 1;
    };

    // onExit(childProcess).catch(code => process.exit(code));
    var exited = prim.zig(io, onExit, .{ io, &child }) catch {
        child.kill(io);
        return 1;
    };
    return exited.await(io) catch 1;
}
