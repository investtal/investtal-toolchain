const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");

pub fn create(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, org_id: []const u8, body_json: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "public/teams/v1/org/{s}/teams/", .{org_id});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .gateway, path);
    defer allocator.free(url);
    return client.request(.{ .method = .POST, .url = url, .auth_header = auth, .body = body_json });
}

pub fn get(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, org_id: []const u8, team_id: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "public/teams/v1/org/{s}/teams/{s}", .{ org_id, team_id });
    defer allocator.free(path);
    const url = try site.resolve(allocator, .gateway, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

pub fn update(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, org_id: []const u8, team_id: []const u8, body_json: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "public/teams/v1/org/{s}/teams/{s}", .{ org_id, team_id });
    defer allocator.free(path);
    const url = try site.resolve(allocator, .gateway, path);
    defer allocator.free(url);
    return client.request(.{ .method = .PATCH, .url = url, .auth_header = auth, .body = body_json });
}

pub fn deleteTeam(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, org_id: []const u8, team_id: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "public/teams/v1/org/{s}/teams/{s}", .{ org_id, team_id });
    defer allocator.free(path);
    const url = try site.resolve(allocator, .gateway, path);
    defer allocator.free(url);
    return client.request(.{ .method = .DELETE, .url = url, .auth_header = auth });
}

pub fn members(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, org_id: []const u8, team_id: []const u8, body_json: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "public/teams/v1/org/{s}/teams/{s}/members", .{ org_id, team_id });
    defer allocator.free(path);
    const url = try site.resolve(allocator, .gateway, path);
    defer allocator.free(url);
    return client.request(.{ .method = .POST, .url = url, .auth_header = auth, .body = body_json });
}

pub fn addMembers(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, org_id: []const u8, team_id: []const u8, body_json: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "public/teams/v1/org/{s}/teams/{s}/members/add", .{ org_id, team_id });
    defer allocator.free(path);
    const url = try site.resolve(allocator, .gateway, path);
    defer allocator.free(url);
    return client.request(.{ .method = .POST, .url = url, .auth_header = auth, .body = body_json });
}

pub fn removeMembers(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, org_id: []const u8, team_id: []const u8, body_json: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "public/teams/v1/org/{s}/teams/{s}/members/remove", .{ org_id, team_id });
    defer allocator.free(path);
    const url = try site.resolve(allocator, .gateway, path);
    defer allocator.free(url);
    return client.request(.{ .method = .POST, .url = url, .auth_header = auth, .body = body_json });
}

test "team path contains gateway public teams" {
    const site = transport.Site{ .base_url = "https://acme.atlassian.net" };
    const u = try site.resolve(std.testing.allocator, .gateway, "public/teams/v1/org/ORG/teams/T1");
    defer std.testing.allocator.free(u);
    try std.testing.expect(std.mem.indexOf(u8, u, "/gateway/api/public/teams/v1/org/") != null);
}
