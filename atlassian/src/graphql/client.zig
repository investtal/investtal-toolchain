const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");
const ApiError = @import("../http/error.zig").ApiError;

pub fn execute(
    client: *http_client.Client,
    allocator: Allocator,
    site: transport.Site,
    auth: []const u8,
    query: []const u8,
    variables_json: ?[]const u8,
) !http_client.Result {
    const url = try site.resolve(allocator, .graphql, "");
    defer allocator.free(url);

    const body = if (variables_json) |v|
        try std.fmt.allocPrint(allocator, "{{\"query\":{s},\"variables\":{s}}}", .{ try jsonString(allocator, query), v })
    else
        try std.fmt.allocPrint(allocator, "{{\"query\":{s}}}", .{try jsonString(allocator, query)});
    defer allocator.free(body);

    var result = try client.request(.{
        .method = .POST,
        .url = url,
        .auth_header = auth,
        .body = body,
    });

    // Surface GraphQL errors when present with non-null errors array.
    switch (result) {
        .ok => |r| {
            if (std.mem.indexOf(u8, r.body, "\"errors\"")) |_| {
                if (std.mem.indexOf(u8, r.body, "\"data\":null") != null or std.mem.indexOf(u8, r.body, "\"data\": null") != null) {
                    var err = try ApiError.fromHttp(allocator, 200, r.body, null);
                    err.kind = .decode;
                    result.deinit(allocator);
                    return .{ .err = err };
                }
            }
        },
        .err => {},
    }
    return result;
}

fn jsonString(allocator: Allocator, s: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
    return try list.toOwnedSlice(allocator);
}

test "graphql body builder contains query" {
    const a = std.testing.allocator;
    const q = try jsonString(a, "query { x }");
    defer a.free(q);
    try std.testing.expect(std.mem.indexOf(u8, q, "query") != null);
}
