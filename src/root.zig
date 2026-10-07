//! Package root. The CLI entry point is `main.zig`; these are the three
//! scripts that mirror the npm package layout:
//!
//!   package.toml            ↔ package.json (version for MANIFEST lookup)
//!   launch.zig              ↔ wrapper.js   (`bin.appservices`)
//!   install.zig             ↔ install.js   (`scripts.install`)
//!   verify.zig              ↔ testInstall.js
const std = @import("std");

pub const launch = @import("launch.zig");
pub const install = @import("install.zig");
pub const verify = @import("verify.zig");
pub const console = @import("console.zig");

test {
    _ = launch;
    _ = install;
    _ = verify;
}
