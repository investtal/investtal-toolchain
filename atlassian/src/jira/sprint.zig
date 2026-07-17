const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");
const jql_mod = @import("jql.zig");

pub fn listForBoard(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, board_id: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "board/{s}/sprint", .{board_id});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira_software, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

pub fn listForBoardState(
    client: *http_client.Client,
    allocator: Allocator,
    site: transport.Site,
    auth: []const u8,
    board_id: []const u8,
    state: []const u8,
) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "board/{s}/sprint?state={s}", .{ board_id, state });
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira_software, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

pub fn get(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, id: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "sprint/{s}", .{id});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira_software, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

pub fn issues(
    client: *http_client.Client,
    allocator: Allocator,
    site: transport.Site,
    auth: []const u8,
    sprint_id: []const u8,
    jql: ?[]const u8,
    max_results: u32,
) !http_client.Result {
    const path = try buildSprintIssuesPath(allocator, sprint_id, jql, max_results);
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira_software, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

fn buildSprintIssuesPath(allocator: Allocator, sprint_id: []const u8, jql: ?[]const u8, max_results: u32) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.print(allocator, "sprint/{s}/issue?maxResults={d}", .{ sprint_id, max_results });
    if (jql) |j| {
        const trimmed = std.mem.trim(u8, j, " \t");
        if (trimmed.len > 0) {
            const enc = try jql_mod.urlEncode(allocator, trimmed);
            defer allocator.free(enc);
            try list.print(allocator, "&jql={s}", .{enc});
        }
    }
    try list.appendSlice(allocator, "&fields=summary,status,assignee,priority,issuetype,updated,duedate,created,project,labels,description");
    return try list.toOwnedSlice(allocator);
}

pub fn firstActiveSprintId(allocator: Allocator, list_body: []const u8) !?[]u8 {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, list_body, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const values = parsed.value.object.get("values") orelse return null;
    if (values != .array or values.array.items.len == 0) return null;
    const first = values.array.items[0];
    if (first != .object) return null;
    if (first.object.get("id")) |idv| {
        switch (idv) {
            .integer => |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}),
            .string => |s| return try allocator.dupe(u8, s),
            .float => |f| return try std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(f))}),
            else => {},
        }
    }
    return null;
}

test "sprint issues path" {
    const a = std.testing.allocator;
    const p = try buildSprintIssuesPath(a, "42", "assignee = currentUser()", 10);
    defer a.free(p);
    try std.testing.expect(std.mem.startsWith(u8, p, "sprint/42/issue?"));
    try std.testing.expect(std.mem.indexOf(u8, p, "jql=") != null);
}

test "firstActiveSprintId parses values" {
    const a = std.testing.allocator;
    const body = "{\"values\":[{\"id\":7,\"name\":\"S1\",\"state\":\"active\"}]}";
    const id = try firstActiveSprintId(a, body);
    try std.testing.expect(id != null);
    defer a.free(id.?);
    try std.testing.expectEqualStrings("7", id.?);
}
