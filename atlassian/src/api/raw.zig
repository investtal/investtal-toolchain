const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");

pub fn rawRequest(
    client: *http_client.Client,
    allocator: Allocator,
    site: transport.Site,
    auth: []const u8,
    method: std.http.Method,
    product: transport.Product,
    path: []const u8,
    body: ?[]const u8,
) !http_client.Result {
    const url = try site.resolve(allocator, product, path);
    defer allocator.free(url);
    return client.request(.{
        .method = method,
        .url = url,
        .auth_header = auth,
        .body = body,
    });
}
