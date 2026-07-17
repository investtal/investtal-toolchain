const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");
const jql_mod = @import("jql.zig");

pub fn list(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8) !http_client.Result {
    const url = try site.resolve(allocator, .jira_software, "board");
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

pub fn get(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, id: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "board/{s}", .{id});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira_software, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

pub fn backlog(
    client: *http_client.Client,
    allocator: Allocator,
    site: transport.Site,
    auth: []const u8,
    board_id: []const u8,
    jql: ?[]const u8,
    max_results: u32,
) !http_client.Result {
    const path = try buildIssueListPath(allocator, "board", board_id, "backlog", jql, max_results);
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira_software, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

fn buildIssueListPath(
    allocator: Allocator,
    resource: []const u8,
    id: []const u8,
    suffix: []const u8,
    jql: ?[]const u8,
    max_results: u32,
) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.print(allocator, "{s}/{s}/{s}?maxResults={d}", .{ resource, id, suffix, max_results });
    if (jql) |j| {
        const trimmed = std.mem.trim(u8, j, " \t");
        if (trimmed.len > 0) {
            const enc = try jql_mod.urlEncode(allocator, trimmed);
            defer allocator.free(enc);
            try buf.print(allocator, "&jql={s}", .{enc});
        }
    }

    try buf.appendSlice(allocator, "&fields=summary,status,assignee,priority,issuetype,updated,duedate,created,project,labels,description");
    return try buf.toOwnedSlice(allocator);
}

test "backlog path shape" {
    const a = std.testing.allocator;
    const p = try buildIssueListPath(a, "board", "1", "backlog", "assignee = currentUser()", 25);
    defer a.free(p);
    try std.testing.expect(std.mem.indexOf(u8, p, "board/1/backlog?") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "maxResults=25") != null);
    try std.testing.expect(std.mem.indexOf(u8, p, "jql=") != null);
}
