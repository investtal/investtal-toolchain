const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");

pub fn get(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, key: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "issue/{s}", .{key});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

pub fn create(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, body_json: []const u8) !http_client.Result {
    const url = try site.resolve(allocator, .jira, "issue");
    defer allocator.free(url);
    return client.request(.{ .method = .POST, .url = url, .auth_header = auth, .body = body_json });
}

pub fn update(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, key: []const u8, body_json: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "issue/{s}", .{key});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira, path);
    defer allocator.free(url);
    return client.request(.{ .method = .PUT, .url = url, .auth_header = auth, .body = body_json });
}

pub fn deleteIssue(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, key: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "issue/{s}", .{key});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira, path);
    defer allocator.free(url);
    return client.request(.{ .method = .DELETE, .url = url, .auth_header = auth });
}

pub fn search(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, jql: []const u8, max_results: u32) !http_client.Result {
    // Jira Cloud v3 enhanced search endpoint
    const url = try site.resolve(allocator, .jira, "search/jql");
    defer allocator.free(url);
    const jql_q = try quote(allocator, jql);
    defer allocator.free(jql_q);
    const body = try std.fmt.allocPrint(allocator, "{{\"jql\":{s},\"maxResults\":{d}}}", .{ jql_q, max_results });
    defer allocator.free(body);
    return client.request(.{ .method = .POST, .url = url, .auth_header = auth, .body = body });
}

fn quote(allocator: Allocator, s: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try list.append(allocator, '\\');
        try list.append(allocator, c);
    }
    try list.append(allocator, '"');
    return try list.toOwnedSlice(allocator);
}

test "issue get path" {
    const site = transport.Site{ .base_url = "https://acme.atlassian.net" };
    const u = try site.resolve(std.testing.allocator, .jira, "issue/PROJ-1");
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("https://acme.atlassian.net/rest/api/3/issue/PROJ-1", u);
}
