const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");

pub fn get(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, page_id: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "pages/{s}?body-format=storage", .{page_id});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .confluence, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

pub fn create(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, body_json: []const u8) !http_client.Result {
    const url = try site.resolve(allocator, .confluence, "pages");
    defer allocator.free(url);
    return client.request(.{ .method = .POST, .url = url, .auth_header = auth, .body = body_json });
}

pub fn update(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, page_id: []const u8, body_json: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "pages/{s}", .{page_id});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .confluence, path);
    defer allocator.free(url);
    return client.request(.{ .method = .PUT, .url = url, .auth_header = auth, .body = body_json });
}

pub fn deletePage(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, page_id: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "pages/{s}", .{page_id});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .confluence, path);
    defer allocator.free(url);
    return client.request(.{ .method = .DELETE, .url = url, .auth_header = auth });
}

pub fn list(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, space_id: ?[]const u8, limit: u32) !http_client.Result {
    const path = if (space_id) |s|
        try std.fmt.allocPrint(allocator, "pages?space-id={s}&limit={d}", .{ s, limit })
    else
        try std.fmt.allocPrint(allocator, "pages?limit={d}", .{limit});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .confluence, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

test "confluence page path" {
    const site = transport.Site{ .base_url = "https://acme.atlassian.net" };
    const u = try site.resolve(std.testing.allocator, .confluence, "pages/1");
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("https://acme.atlassian.net/wiki/api/v2/pages/1", u);
}
