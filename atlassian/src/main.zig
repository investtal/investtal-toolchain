const std = @import("std");

pub fn main(init: std.process.Init) void {
    const code = @import("cli/root.zig").run(init);
    std.process.exit(code);
}
