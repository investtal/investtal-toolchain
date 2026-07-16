const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");

pub fn list(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8) !http_client.Result {
    const url = try site.resolve(allocator, .jira, "project");
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}

pub fn get(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, id_or_key: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "project/{s}", .{id_or_key});
    defer allocator.free(path);
    const url = try site.resolve(allocator, .jira, path);
    defer allocator.free(url);
    return client.request(.{ .method = .GET, .url = url, .auth_header = auth });
}
