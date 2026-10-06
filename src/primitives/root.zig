pub const Channel = @import("channel.zig").Channel;
pub const zig = @import("routine.zig").zig;
pub const WaitGroup = @import("routine.zig").WaitGroup;

test {
    _ = @import("channel.zig");
    _ = @import("routine.zig");
}
