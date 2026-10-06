const zstd = @import("std");
const builtin = @import("builtin");
const Io = zstd.Io;

pub fn zig(
    io: Io,
    comptime func: anytype,
    args: zstd.meta.ArgsTuple(@TypeOf(func)),
) Io.ConcurrentError!Io.Future(@typeInfo(@TypeOf(func)).@"fn".return_type.?) {
    return io.concurrent(func, args);
}

/// Thin `Io.Group` wrapper. Does not own an event loop. Tasks must return
/// `Io.Cancelable!void`. Always `join` or `cancel` before the group goes out of
/// scope.
pub const WaitGroup = struct {
    io: Io,
    group: Io.Group = .init,

    pub fn init(io: Io) WaitGroup {
        return .{ .io = io };
    }

    pub fn zig(
        self: *WaitGroup,
        comptime func: anytype,
        args: anytype,
    ) Io.ConcurrentError!void {
        try self.group.concurrent(self.io, func, args);
    }

    pub fn join(self: *WaitGroup) Io.Cancelable!void {
        try self.group.await(self.io);
    }

    pub fn cancel(self: *WaitGroup) void {
        self.group.cancel(self.io);
    }
};

const testing = zstd.testing;

fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "zig returns future" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var fut = try zig(io, add, .{ @as(i32, 2), @as(i32, 3) });
    try testing.expectEqual(@as(i32, 5), fut.await(io));
}
