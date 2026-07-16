const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");

pub fn listForBoard(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, board_id: []const u8) !http_client.Result {
    const path = try std.fmt.allocPrint(allocator, "board/{s}/sprint", .{board_id});
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
