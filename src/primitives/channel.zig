const zstd = @import("std");
const builtin = @import("builtin");
const Io = zstd.Io;

/// One `Io` instance must be used for every operation on a given channel.
/// `Io.Mutex` / `Io.Condition` do not work across Threaded and Evented.
///
/// Do not copy a `Channel` after init. A buffered channel's buffer must outlive
/// the channel. Destroying a channel with waiters is undefined — `close` then
/// drain / join first.
pub fn Channel(comptime T: type) type {
    return struct {
        fifo: Fifo,
        capacity: usize,
        slot: ?T = null,
        send_id: u64 = 0,
        acked_id: u64 = 0,
        recv_waiters: usize = 0,
        send_waiters: usize = 0,
        lock: Io.Mutex = .init,
        writeable: Io.Condition = .init,
        readable: Io.Condition = .init,
        closed: bool = false,

        const Self = @This();
        const Fifo = zstd.Deque(T);
        const Closed = error{Closed};

        pub fn init() Self {
            return .{
                .fifo = .empty,
                .capacity = 0,
            };
        }

        pub fn initBuffered(buffer: []T) Self {
            zstd.debug.assert(buffer.len > 0);
            return .{
                .fifo = Fifo.initBuffer(buffer),
                .capacity = buffer.len,
            };
        }

        fn unbuffered(self: *const Self) bool {
            return self.capacity == 0;
        }

        pub fn close(self: *Self, io: Io) Io.Cancelable!void {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            self.closed = true;
            self.writeable.broadcast(io);
            self.readable.broadcast(io);
        }

        pub fn send(self: *Self, io: Io, item: T) (Io.Cancelable || Closed)!void {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            if (self.unbuffered()) {
                try self.sendUnbuffered(io, item);
                return;
            }
            try self.sendBuffered(io, item);
        }

        pub fn trySend(self: *Self, io: Io, item: T) (Io.Cancelable || Closed || error{Full})!void {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            if (self.closed) return error.Closed;
            if (self.unbuffered()) {
                if (self.recv_waiters == 0 or self.slot != null) return error.Full;
                self.send_id += 1;
                self.slot = item;
                self.readable.signal(io);
                return;
            }
            self.fifo.pushBackBounded(item) catch return error.Full;
            self.readable.signal(io);
        }

        pub fn receive(self: *Self, io: Io) (Io.Cancelable || Closed)!T {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            if (self.unbuffered()) {
                return self.receiveUnbuffered(io);
            }
            return self.receiveBuffered(io);
        }

        pub fn tryReceive(self: *Self, io: Io) (Io.Cancelable || Closed || error{Empty})!T {
            try self.lock.lock(io);
            defer self.lock.unlock(io);
            if (self.unbuffered()) {
                if (self.slot) |v| {
                    self.slot = null;
                    self.acked_id = self.send_id;
                    self.writeable.broadcast(io);
                    return v;
                }
                if (self.closed) return error.Closed;
                return error.Empty;
            }
            if (self.fifo.popFront()) |item| {
                self.writeable.signal(io);
                return item;
            }
            if (self.closed) return error.Closed;
            return error.Empty;
        }

        fn sendBuffered(self: *Self, io: Io, item: T) (Io.Cancelable || Closed)!void {
            while (true) {
                if (self.closed) return error.Closed;
                self.fifo.pushBackBounded(item) catch {
                    {
                        self.send_waiters += 1;
                        defer self.send_waiters -= 1;
                        try self.writeable.wait(io, &self.lock);
                    }
                    continue;
                };
                self.readable.signal(io);
                return;
            }
        }

        fn sendUnbuffered(self: *Self, io: Io, item: T) (Io.Cancelable || Closed)!void {
            {
                self.send_waiters += 1;
                defer self.send_waiters -= 1;
                while (self.slot != null and !self.closed) {
                    try self.writeable.wait(io, &self.lock);
                }
            }
            if (self.closed) return error.Closed;

            self.send_id += 1;
            const my_id = self.send_id;
            self.slot = item;
            self.readable.signal(io);

            errdefer {
                if (self.acked_id < my_id and self.send_id == my_id and self.slot != null) {
                    self.slot = null;
                    self.writeable.broadcast(io);
                    self.readable.broadcast(io);
                }
            }

            while (self.acked_id < my_id and !self.closed) {
                try self.writeable.wait(io, &self.lock);
            }
            if (self.acked_id >= my_id) return;
            if (self.send_id == my_id and self.slot != null) {
                self.slot = null;
                self.writeable.broadcast(io);
            }
            return error.Closed;
        }

        fn receiveBuffered(self: *Self, io: Io) (Io.Cancelable || Closed)!T {
            while (true) {
                if (self.fifo.popFront()) |item| {
                    self.writeable.signal(io);
                    return item;
                }
                if (self.closed) return error.Closed;
                {
                    self.recv_waiters += 1;
                    defer self.recv_waiters -= 1;
                    try self.readable.wait(io, &self.lock);
                }
            }
        }

        fn receiveUnbuffered(self: *Self, io: Io) (Io.Cancelable || Closed)!T {
            {
                self.recv_waiters += 1;
                defer self.recv_waiters -= 1;
                while (self.slot == null and !self.closed) {
                    try self.readable.wait(io, &self.lock);
                }
            }
            const v = self.slot orelse return error.Closed;
            self.slot = null;
            self.acked_id = self.send_id;
            self.writeable.broadcast(io);
            return v;
        }
    };
}

const testing = zstd.testing;
const WaitGroup = @import("routine.zig").WaitGroup;
const zig = @import("routine.zig").zig;

fn sendValue(io: Io, ch: *Channel(i32), value: i32) Io.Cancelable!void {
    ch.send(io, value) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => {},
    };
}

fn recvInto(io: Io, ch: *Channel(i32), out: *i32) Io.Cancelable!void {
    out.* = ch.receive(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => return,
    };
}

fn recvUntilClosed(io: Io, ch: *Channel(i32), sum: *i32) Io.Cancelable!void {
    while (true) {
        const v = ch.receive(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return,
        };
        sum.* += v;
    }
}

fn produceThenClose(io: Io, ch: *Channel(i32), n: i32) Io.Cancelable!void {
    var i: i32 = 0;
    while (i < n) : (i += 1) {
        ch.send(io, i) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => return,
        };
    }
    ch.close(io) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
    };
}

fn mapI32(allocator: zstd.mem.Allocator, input: []const i32, comptime f: fn (i32) i32) ![]i32 {
    const out = try allocator.alloc(i32, input.len);
    for (input, 0..) |n, i| out[i] = f(n);
    return out;
}

fn reduceI32(items: []const i32, initial: i32, comptime f: fn (i32, i32) i32) i32 {
    var acc = initial;
    for (items) |n| acc = f(acc, n);
    return acc;
}

fn square(n: i32) i32 {
    return n * n;
}

fn double(n: i32) i32 {
    return n * 2;
}

fn identity(n: i32) i32 {
    return n;
}

fn add(acc: i32, n: i32) i32 {
    return acc + n;
}

fn mul(acc: i32, n: i32) i32 {
    return acc * n;
}

test "buffered trySend tryReceive map-reduce" {
    const Case = struct {
        input: []const i32,
        initial: i32,
        expected: i32,
        map_fn: fn (i32) i32,
        reduce_fn: fn (i32, i32) i32,
    };
    const cases = [_]Case{
        .{ .input = &.{ 1, 2, 3 }, .initial = 0, .expected = 14, .map_fn = square, .reduce_fn = add },
        .{ .input = &.{ 1, 2, 3, 4 }, .initial = 0, .expected = 30, .map_fn = square, .reduce_fn = add },
        .{ .input = &.{ 1, 2, 3 }, .initial = 0, .expected = 12, .map_fn = double, .reduce_fn = add },
        .{ .input = &.{ 2, 3, 4 }, .initial = 1, .expected = 24, .map_fn = identity, .reduce_fn = mul },
        .{ .input = &.{}, .initial = 0, .expected = 0, .map_fn = square, .reduce_fn = add },
        .{ .input = &.{}, .initial = 1, .expected = 1, .map_fn = identity, .reduce_fn = mul },
        .{ .input = &.{7}, .initial = 0, .expected = 49, .map_fn = square, .reduce_fn = add },
        .{ .input = &.{ -3, 4, -5 }, .initial = 0, .expected = 50, .map_fn = square, .reduce_fn = add },
    };

    const io = testing.io;
    inline for (cases) |tc| {
        const mapped = try mapI32(testing.allocator, tc.input, tc.map_fn);
        defer testing.allocator.free(mapped);

        const buf = try testing.allocator.alloc(i32, @max(mapped.len, 1));
        defer testing.allocator.free(buf);
        var ch = Channel(i32).initBuffered(buf);

        for (mapped) |item| {
            try ch.trySend(io, item);
        }

        const received = try testing.allocator.alloc(i32, mapped.len);
        defer testing.allocator.free(received);
        for (received) |*slot| {
            slot.* = try ch.tryReceive(io);
        }
        try testing.expectError(error.Empty, ch.tryReceive(io));

        const result = reduceI32(received, tc.initial, tc.reduce_fn);
        try testing.expectEqual(tc.expected, result);
    }
}

test "buffered close drain" {
    const io = testing.io;
    var buf: [4]i32 = undefined;
    var ch = Channel(i32).initBuffered(&buf);

    try ch.trySend(io, 1);
    try ch.trySend(io, 2);
    try ch.close(io);

    try testing.expectEqual(@as(i32, 1), try ch.receive(io));
    try testing.expectEqual(@as(i32, 2), try ch.receive(io));
    try testing.expectError(error.Closed, ch.receive(io));
    try testing.expectError(error.Closed, ch.send(io, 3));
    try testing.expectError(error.Closed, ch.trySend(io, 4));
    try testing.expectError(error.Closed, ch.tryReceive(io));
}

test "unbuffered rendezvous" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var ch = Channel(i32).init();
    var got: i32 = 0;
    var wg = WaitGroup.init(io);

    try wg.zig(recvInto, .{ io, &ch, &got });
    try ch.send(io, 42);
    try wg.join();
    try testing.expectEqual(@as(i32, 42), got);
}

test "unbuffered multi-sender barging" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var ch = Channel(i32).init();
    var wg = WaitGroup.init(io);

    try wg.zig(sendValue, .{ io, &ch, @as(i32, 1) });
    try wg.zig(sendValue, .{ io, &ch, @as(i32, 2) });

    const a = try ch.receive(io);
    const b = try ch.receive(io);
    try wg.join();

    try testing.expect((a == 1 and b == 2) or (a == 2 and b == 1));
}

test "buffered WaitGroup ping-pong" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var buf: [4]i32 = undefined;
    var ch = Channel(i32).initBuffered(&buf);
    var sum: i32 = 0;
    var wg = WaitGroup.init(io);

    try wg.zig(produceThenClose, .{ io, &ch, @as(i32, 8) });
    try wg.zig(recvUntilClosed, .{ io, &ch, &sum });
    try wg.join();
    try testing.expectEqual(@as(i32, 28), sum);
}

fn sendCancelable(io: Io, ch: *Channel(i32), value: i32) (Io.Cancelable || error{Closed})!void {
    try ch.send(io, value);
}

test "cancel sender after placing slot" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var ch = Channel(i32).init();

    var fut = try zig(io, sendCancelable, .{ io, &ch, @as(i32, 7) });
    try io.sleep(.fromMilliseconds(50), .awake);
    try testing.expectError(error.Canceled, fut.cancel(io));
    try testing.expectError(error.Empty, ch.tryReceive(io));

    var got: i32 = 0;
    var wg = WaitGroup.init(io);
    try wg.zig(recvInto, .{ io, &ch, &got });
    try ch.send(io, 9);
    try wg.join();
    try testing.expectEqual(@as(i32, 9), got);
}

test "cancel sender parked waiting for slot" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const io = testing.io;
    var ch = Channel(i32).init();

    var first = try zig(io, sendCancelable, .{ io, &ch, @as(i32, 1) });
    try io.sleep(.fromMilliseconds(50), .awake);
    var second = try zig(io, sendCancelable, .{ io, &ch, @as(i32, 2) });
    try io.sleep(.fromMilliseconds(50), .awake);

    try testing.expectError(error.Canceled, second.cancel(io));
    try testing.expectEqual(@as(i32, 1), try ch.receive(io));
    first.await(io) catch |err| switch (err) {
        error.Canceled => return error.TestUnexpectedResult,
        error.Closed => return error.TestUnexpectedResult,
    };
    try testing.expectError(error.Empty, ch.tryReceive(io));
}
