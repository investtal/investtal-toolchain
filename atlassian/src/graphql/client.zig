const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");
const ApiError = @import("../http/error.zig").ApiError;

const GqlError = struct {
    message: []const u8 = "",
};

const GqlResponse = struct {
    data: ?std.json.Value = null,
    errors: ?[]const GqlError = null,
};

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

    var body: []u8 = undefined;
    if (variables_json) |v| {
        var vars_parsed = try std.json.parseFromSlice(std.json.Value, allocator, v, .{ .allocate = .alloc_always });
        defer vars_parsed.deinit();
        body = try std.json.Stringify.valueAlloc(allocator, .{
            .query = query,
            .variables = vars_parsed.value,
        }, .{});
    } else {
        body = try std.json.Stringify.valueAlloc(allocator, .{ .query = query }, .{});
    }
    defer allocator.free(body);

    var result = try client.request(.{
        .method = .POST,
        .url = url,
        .auth_header = auth,
        .body = body,
    });

    // Surface GraphQL errors via structured JSON parse (not substring scan).
    switch (result) {
        .ok => |r| {
            var parsed = std.json.parseFromSlice(GqlResponse, allocator, r.body, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch {
                return result;
            };
            defer parsed.deinit();
            if (parsed.value.errors) |errs| {
                if (errs.len > 0 and (parsed.value.data == null or parsed.value.data.? == .null)) {
                    const msg = if (errs[0].message.len > 0) errs[0].message else "GraphQL error";
                    var err = try ApiError.fromHttp(allocator, 200, msg, null);
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

test "graphql stringify body contains query" {
    const a = std.testing.allocator;
    const body = try std.json.Stringify.valueAlloc(a, .{ .query = "query { x }" }, .{});
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "query { x }") != null);
}
