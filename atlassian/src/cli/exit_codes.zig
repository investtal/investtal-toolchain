pub const ok: u8 = 0;
pub const generic: u8 = 1;
pub const usage: u8 = 2;
pub const auth: u8 = 3;
pub const not_found: u8 = 4;
pub const rate_limit: u8 = 5;
pub const not_implemented: u8 = 6;
pub const network: u8 = 7;

test "not_implemented is 6" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u8, 6), not_implemented);
}
