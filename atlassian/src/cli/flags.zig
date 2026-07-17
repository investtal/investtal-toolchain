const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Global = struct {
    json: bool = false,
    config_path: ?[]const u8 = null,
    verbose: bool = false,
    rest: []const []const u8 = &.{},
    rest_owned: ?[][]const u8 = null,

    pub fn deinit(self: *Global, allocator: Allocator) void {
        if (self.config_path) |p| allocator.free(p);
        if (self.rest_owned) |owned| {
            for (owned) |s| allocator.free(s);
            allocator.free(owned);
            self.rest_owned = null;
        }
        self.* = .{};
    }
};

pub fn parse(allocator: Allocator, args: []const []const u8) !Global {
    var g: Global = .{};
    errdefer g.deinit(allocator);

    if (args.len == 0) return g;

    var i: usize = 1; // skip argv0
    var rest_list: std.ArrayList([]const u8) = .empty;
    defer rest_list.deinit(allocator);
    errdefer {
        for (rest_list.items) |s| allocator.free(s);
    }

    var past_flags = false;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!past_flags and std.mem.eql(u8, a, "--")) {
            past_flags = true;
            continue;
        }
        if (!past_flags and std.mem.eql(u8, a, "--json")) {
            g.json = true;
            continue;
        }
        if (!past_flags and (std.mem.eql(u8, a, "-v") or std.mem.eql(u8, a, "--verbose"))) {
            g.verbose = true;
            continue;
        }
        if (!past_flags and std.mem.eql(u8, a, "--config")) {
            i += 1;
            if (i >= args.len) return error.MissingConfigPath;
            g.config_path = try allocator.dupe(u8, args[i]);
            continue;
        }
        if (!past_flags and std.mem.startsWith(u8, a, "--config=")) {
            g.config_path = try allocator.dupe(u8, a["--config=".len..]);
            continue;
        }
        past_flags = true;
        try rest_list.append(allocator, try allocator.dupe(u8, a));
    }

    const owned = try rest_list.toOwnedSlice(allocator);
    g.rest_owned = owned;
    g.rest = owned;
    return g;
}

test "parse extracts --json and --config" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "atlassian", "--json", "--config", "/tmp/c.toml", "config", "list" };
    var g = try parse(a, args[0..]);
    defer g.deinit(a);
    try std.testing.expect(g.json);
    try std.testing.expectEqualStrings("/tmp/c.toml", g.config_path.?);
    try std.testing.expectEqual(@as(usize, 2), g.rest.len);
    try std.testing.expectEqualStrings("config", g.rest[0]);
}
