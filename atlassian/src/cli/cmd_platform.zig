const std = @import("std");
const Io = std.Io;
const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");
const platform_goal = @import("../platform/goal.zig");
const platform_team = @import("../platform/team.zig");
const util = @import("util.zig");
const session_mod = @import("session.zig");

pub fn run(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 3) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform <goal|team> <verb> …");
    const resource = global.rest[1];
    const verb = global.rest[2];
    const rest = global.rest[3..];

    if (std.mem.eql(u8, resource, "goal") and (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "delete") or std.mem.eql(u8, verb, "watch") or std.mem.eql(u8, verb, "link-team"))) {
        return util.notImpl(ctx, "platform goal");
    }
    if (std.mem.eql(u8, resource, "team") and std.mem.eql(u8, verb, "list")) {
        return util.notImpl(ctx, "platform team list (no public list endpoint)");
    }

    var sess = session_mod.openSession(allocator, io, global) catch |err| {
        return switch (err) {
            error.MissingCredentials => render.fail(ctx, exit_codes.auth, "missing credentials"),
            error.MissingUrl => render.fail(ctx, exit_codes.usage, "missing ATLASSIAN_URL"),
            else => render.fail(ctx, exit_codes.generic, "session failed"),
        };
    };
    defer sess.deinit(allocator);

    if (std.mem.eql(u8, resource, "goal")) {
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform goal get ID");
            var result = platform_goal.get(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "list")) {
            const first: u32 = if (util.flagValue(rest, "--first")) |f| std.fmt.parseInt(u32, f, 10) catch 20 else 20;
            var result = platform_goal.list(&sess.client, allocator, sess.site, sess.auth_header, first) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "update")) {
            const body = util.readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "usage: atlassian platform goal update --body vars.json");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = platform_goal.update(&sess.client, allocator, sess.site, sess.auth_header, b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "delete") or std.mem.eql(u8, verb, "watch") or std.mem.eql(u8, verb, "link-team")) {
            return util.notImpl(ctx, "platform goal");
        }
        return util.notImpl(ctx, "platform goal");
    }

    if (std.mem.eql(u8, resource, "team")) {
        const org = sess.cfg.org_id orelse return render.fail(ctx, exit_codes.usage, "set orgId / ATLASSIAN_ORG_ID for teams");
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team get TEAM_ID");
            var result = platform_team.get(&sess.client, allocator, sess.site, sess.auth_header, org, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create")) {
            const body = util.readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = platform_team.create(&sess.client, allocator, sess.site, sess.auth_header, org, b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "update")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team update TEAM_ID --body patch.json");
            const body = util.readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = platform_team.update(&sess.client, allocator, sess.site, sess.auth_header, org, rest[0], b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "delete")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team delete TEAM_ID");
            var result = platform_team.deleteTeam(&sess.client, allocator, sess.site, sess.auth_header, org, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "members")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team members TEAM_ID");
            var result = platform_team.members(&sess.client, allocator, sess.site, sess.auth_header, org, rest[0], "{\"first\":50}") catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "add-member")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team add-member TEAM_ID --account-id ID");
            const aid = util.flagValue(rest, "--account-id") orelse return render.fail(ctx, exit_codes.usage, "missing --account-id");
            const body = std.fmt.allocPrint(allocator, "{{\"accountIds\":[\"{s}\"]}}", .{aid}) catch return exit_codes.generic;
            defer allocator.free(body);
            var result = platform_team.addMembers(&sess.client, allocator, sess.site, sess.auth_header, org, rest[0], body) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "remove-member")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team remove-member TEAM_ID --account-id ID");
            const aid = util.flagValue(rest, "--account-id") orelse return render.fail(ctx, exit_codes.usage, "missing --account-id");
            const body = std.fmt.allocPrint(allocator, "{{\"accountIds\":[\"{s}\"]}}", .{aid}) catch return exit_codes.generic;
            defer allocator.free(body);
            var result = platform_team.removeMembers(&sess.client, allocator, sess.site, sess.auth_header, org, rest[0], body) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "list")) {
            return util.notImpl(ctx, "platform team list (no public list endpoint)");
        }
        return util.notImpl(ctx, "platform team");
    }

    return render.fail(ctx, exit_codes.usage, "unknown platform resource");
}
