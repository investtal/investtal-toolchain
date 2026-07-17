const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Product = enum {
    jira,
    jira_software,
    confluence,
    gateway,
    graphql,
};

pub const AuthMode = enum { basic, oauth };
pub const SiteKind = enum { cloud, server_dc };

pub const Site = struct {
    kind: SiteKind = .cloud,
    base_url: []const u8,
    cloud_id: ?[]const u8 = null,
    auth_mode: AuthMode = .basic,

    pub fn resolve(self: Site, allocator: Allocator, product: Product, path: []const u8) ![]u8 {
        const clean_path = if (path.len > 0 and path[0] == '/') path[1..] else path;
        const base = std.mem.trimEnd(u8, self.base_url, "/");

        if (self.kind == .server_dc) {
            return resolveCloudBasic(allocator, base, product, clean_path);
        }

        return switch (self.auth_mode) {
            .basic => resolveCloudBasic(allocator, base, product, clean_path),
            .oauth => resolveCloudOAuth(allocator, base, self.cloud_id, product, clean_path),
        };
    }
};

fn resolveCloudBasic(allocator: Allocator, base: []const u8, product: Product, path: []const u8) ![]u8 {
    return switch (product) {
        .jira => if (path.len == 0)
            try std.fmt.allocPrint(allocator, "{s}/rest/api/3", .{base})
        else
            try std.fmt.allocPrint(allocator, "{s}/rest/api/3/{s}", .{ base, path }),
        .jira_software => if (path.len == 0)
            try std.fmt.allocPrint(allocator, "{s}/rest/agile/1.0", .{base})
        else
            try std.fmt.allocPrint(allocator, "{s}/rest/agile/1.0/{s}", .{ base, path }),
        .confluence => if (path.len == 0)
            try std.fmt.allocPrint(allocator, "{s}/wiki/api/v2", .{base})
        else
            try std.fmt.allocPrint(allocator, "{s}/wiki/api/v2/{s}", .{ base, path }),
        .gateway => if (path.len == 0)
            try std.fmt.allocPrint(allocator, "{s}/gateway/api", .{base})
        else
            try std.fmt.allocPrint(allocator, "{s}/gateway/api/{s}", .{ base, path }),
        .graphql => try std.fmt.allocPrint(allocator, "{s}/gateway/api/graphql", .{base}),
    };
}

fn resolveCloudOAuth(allocator: Allocator, base: []const u8, cloud_id: ?[]const u8, product: Product, path: []const u8) ![]u8 {
    switch (product) {
        .jira => {
            const cid = cloud_id orelse return error.MissingCloudId;
            if (path.len == 0)
                return try std.fmt.allocPrint(allocator, "https://api.atlassian.com/ex/jira/{s}/rest/api/3", .{cid});
            return try std.fmt.allocPrint(allocator, "https://api.atlassian.com/ex/jira/{s}/rest/api/3/{s}", .{ cid, path });
        },
        .confluence => {
            const cid = cloud_id orelse return error.MissingCloudId;
            if (path.len == 0)
                return try std.fmt.allocPrint(allocator, "https://api.atlassian.com/ex/confluence/{s}/wiki/api/v2", .{cid});
            return try std.fmt.allocPrint(allocator, "https://api.atlassian.com/ex/confluence/{s}/wiki/api/v2/{s}", .{ cid, path });
        },
        .jira_software, .gateway, .graphql => return resolveCloudBasic(allocator, base, product, path),
    }
}

test "resolve jira basic cloud" {
    const site = Site{ .base_url = "https://acme.atlassian.net", .auth_mode = .basic };
    const u = try site.resolve(std.testing.allocator, .jira, "issue/A-1");
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("https://acme.atlassian.net/rest/api/3/issue/A-1", u);
}

test "resolve jira oauth cloud" {
    const site = Site{ .base_url = "https://acme.atlassian.net", .cloud_id = "cid", .auth_mode = .oauth };
    const u = try site.resolve(std.testing.allocator, .jira, "issue/A-1");
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("https://api.atlassian.com/ex/jira/cid/rest/api/3/issue/A-1", u);
}
