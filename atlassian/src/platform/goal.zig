const std = @import("std");
const Allocator = std.mem.Allocator;
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");
const graphql = @import("../graphql/client.zig");

// Docs: https://developer.atlassian.com/platform/goals/goals-graphql-api/introduction/

pub fn get(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, goal_id: []const u8) !http_client.Result {
    const q =
        \\query Goal($id: ID!) { goals { goal(id: $id) { id name description } } }
    ;
    const vars = try std.fmt.allocPrint(allocator, "{{\"id\":\"{s}\"}}", .{goal_id});
    defer allocator.free(vars);
    return graphql.execute(client, allocator, site, auth, q, vars);
}

pub fn list(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, first: u32) !http_client.Result {
    const q =
        \\query Goals($first: Int) { goals { goals(first: $first) { nodes { id name } } } }
    ;
    const vars = try std.fmt.allocPrint(allocator, "{{\"first\":{d}}}", .{first});
    defer allocator.free(vars);
    return graphql.execute(client, allocator, site, auth, q, vars);
}

pub fn update(client: *http_client.Client, allocator: Allocator, site: transport.Site, auth: []const u8, variables_json: []const u8) !http_client.Result {
    // Mutation shape depends on live Goals schema; pass full variables from CLI body.
    const q =
        \\mutation UpdateGoal($input: UpdateGoalInput!) { goals { updateGoal(input: $input) { success } } }
    ;
    return graphql.execute(client, allocator, site, auth, q, variables_json);
}
