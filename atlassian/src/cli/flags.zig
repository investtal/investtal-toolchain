const std = @import("std");
const Allocator = std.mem.Allocator;
const OutputFormat = @import("output_format.zig").OutputFormat;

pub const Global = struct {

    format: OutputFormat = .toon,
    config_path: ?[]const u8 = null,
    verbose: bool = false,
    rest: []const []const u8 = &.{},
    rest_owned: ?[][]const u8 = null,


    pub fn json(self: Global) bool {
        return self.format.isJson();
    }

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

    var i: usize = 1;
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
            g.format = .json;
            continue;
        }
        if (!past_flags and (std.mem.eql(u8, a, "--markdown") or std.mem.eql(u8, a, "--md"))) {
            g.format = .markdown;
            continue;
        }
        if (!past_flags and std.mem.eql(u8, a, "--toon")) {
            g.format = .toon;
            continue;
        }
        if (!past_flags and std.mem.eql(u8, a, "--format")) {
            i += 1;
            if (i >= args.len) return error.MissingFormat;
            g.format = OutputFormat.parse(args[i]) orelse return error.InvalidFormat;
            continue;
        }
        if (!past_flags and std.mem.startsWith(u8, a, "--format=")) {
            g.format = OutputFormat.parse(a["--format=".len..]) orelse return error.InvalidFormat;
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
    try std.testing.expect(g.format == .json);
    try std.testing.expectEqualStrings("/tmp/c.toml", g.config_path.?);
    try std.testing.expectEqual(@as(usize, 2), g.rest.len);
    try std.testing.expectEqualStrings("config", g.rest[0]);
}

test "parse default format is toon" {
    const a = std.testing.allocator;
    const args = [_][]const u8{ "atlassian", "jira", "issue", "get", "X-1" };
    var g = try parse(a, args[0..]);
    defer g.deinit(a);
    try std.testing.expect(g.format == .toon);
}

test "parse --markdown and --format" {
    const a = std.testing.allocator;
    {
        const args = [_][]const u8{ "atlassian", "--markdown", "jira", "issue", "get", "X-1" };
        var g = try parse(a, args[0..]);
        defer g.deinit(a);
        try std.testing.expect(g.format == .markdown);
    }
    {
        const args = [_][]const u8{ "atlassian", "--format=json", "jira", "issue", "get", "X-1" };
        var g = try parse(a, args[0..]);
        defer g.deinit(a);
        try std.testing.expect(g.format == .json);
    }
    {

        const args = [_][]const u8{ "atlassian", "--json", "--toon", "jira", "issue", "get", "X-1" };
        var g = try parse(a, args[0..]);
        defer g.deinit(a);
        try std.testing.expect(g.format == .toon);
    }
}
