//! Library root — re-exports modules so `zig build test` picks up their tests.
const std = @import("std");

pub const cli = @import("cli/root.zig");
pub const exit_codes = @import("cli/exit_codes.zig");
pub const flags = @import("cli/flags.zig");
pub const render = @import("cli/render.zig");

test {
    // Force-import cli modules so their test blocks are linked.
    std.testing.refAllDecls(@This());
}
