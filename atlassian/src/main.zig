const std = @import("std");
const cli = @import("cli/root.zig");

pub fn main(init: std.process.Init) void {
    const code = cli.run(init);
    std.process.exit(code);
}
