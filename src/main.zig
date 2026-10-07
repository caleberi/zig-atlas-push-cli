//! Entry point that ties the three "scripts" together. Mirrors the npm package:
//!
//!   package.toml            this binary
//!   ----------------------  --------------------------------------
//!   bin: appservices        atlas-push-cli [args...]      -> launch.zig
//!   scripts.install         atlas-push-cli --postinstall  -> install.zig
//!   testInstall.js          atlas-push-cli --test-install -> verify.zig
//!
//! Everything that is not one of the two reserved flags is forwarded untouched
//! to the real `appservices` binary, exactly like wrapper.js forwards argv.
const std = @import("std");
const launch = @import("launch.zig");
const install = @import("install.zig");
const verify = @import("verify.zig");

pub fn main(init: std.process.Init) !u8 {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const rest = if (args.len > 0) args[1..] else args;

    if (rest.len == 1 and std.mem.eql(u8, rest[0], "--postinstall")) return install.run(init);
    if (rest.len == 1 and std.mem.eql(u8, rest[0], "--test-install")) return verify.run(init);
    return launch.run(init, rest);
}

test {
    _ = @import("root.zig");
}
