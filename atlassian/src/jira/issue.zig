const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");

pub fn get(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, key: []const u8) !http_client.Result {

    const path = try std.fmt.allocPrint(allocator, "issue/{s}?expand=names,schema", .{key});
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
    const url = try site.resolve(allocator, .jira, "search/jql");
    defer allocator.free(url);
    const fields = [_][]const u8{
        "summary",     "status",     "assignee", "priority", "issuetype",
        "updated",     "duedate",    "created",  "project",  "labels",
        "description", "parent",     "components", "fixVersions",
    };
    const body = try std.json.Stringify.valueAlloc(allocator, .{
        .jql = jql,
        .maxResults = max_results,
        .fields = fields[0..],
    }, .{});
    defer allocator.free(body);
    return client.request(.{ .method = .POST, .url = url, .auth_header = auth, .body = body });
}

test "issue get path includes expand=names,schema" {
    const site = transport.Site{ .base_url = "https://acme.atlassian.net" };
    const path = "issue/PROJ-1?expand=names,schema";
    const u = try site.resolve(std.testing.allocator, .jira, path);
    defer std.testing.allocator.free(u);
    try std.testing.expectEqualStrings("https://acme.atlassian.net/rest/api/3/issue/PROJ-1?expand=names,schema", u);
}
