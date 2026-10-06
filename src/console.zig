//! Tiny stand-in for Node's `console.log` / `console.error` / `process.stdout.write`.
//! Every call formats into a small stack buffer and flushes immediately, so
//! output from concurrent routines interleaves per call, never mid-line.
const std = @import("std");
const Io = std.Io;

fn emit(io: Io, file: Io.File, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.print(fmt, args) catch return;
    w.interface.flush() catch return;
}

/// console.log: formatted text + newline on stdout.
pub fn log(io: Io, comptime fmt: []const u8, args: anytype) void {
    emit(io, Io.File.stdout(), fmt ++ "\n", args);
}

/// console.error: formatted text + newline on stderr.
pub fn err(io: Io, comptime fmt: []const u8, args: anytype) void {
    emit(io, Io.File.stderr(), fmt ++ "\n", args);
}

/// process.stdout.write: no newline appended.
pub fn write(io: Io, comptime fmt: []const u8, args: anytype) void {
    emit(io, Io.File.stdout(), fmt, args);
}

/// Raw bytes to stdout / stderr (used to relay captured child output).
pub fn writeRaw(io: Io, to_stderr: bool, bytes: []const u8) void {
    const file = if (to_stderr) Io.File.stderr() else Io.File.stdout();
    var buf: [1024]u8 = undefined;
    var w = file.writer(io, &buf);
    w.interface.writeAll(bytes) catch return;
    w.interface.flush() catch return;
}
