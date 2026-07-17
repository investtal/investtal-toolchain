const std = @import("std");
const Io = std.Io;
const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");
const jira_issue = @import("../jira/issue.zig");
const jira_project = @import("../jira/project.zig");
const jira_board = @import("../jira/board.zig");
const jira_sprint = @import("../jira/sprint.zig");
const util = @import("util.zig");
const session_mod = @import("session.zig");

pub fn run(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 3) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira <issue|project|board|sprint> <verb> …");
    const resource = global.rest[1];
    const verb = global.rest[2];
    const rest = global.rest[3..];

    // Catalog stubs that must not require credentials.
    if (std.mem.eql(u8, resource, "project") and (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "update") or std.mem.eql(u8, verb, "delete"))) {
        return util.notImpl(ctx, "jira project create|update|delete");
    }
    if (std.mem.eql(u8, resource, "board") and (std.mem.eql(u8, verb, "backlog") or std.mem.eql(u8, verb, "create"))) {
        return util.notImpl(ctx, "jira board");
    }
    if (std.mem.eql(u8, resource, "sprint") and (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "start") or std.mem.eql(u8, verb, "complete"))) {
        return util.notImpl(ctx, "jira sprint");
    }

    var sess = session_mod.openSession(allocator, io, global) catch |err| {
        return switch (err) {
            error.MissingCredentials => render.fail(ctx, exit_codes.auth, "missing credentials; set ATLASSIAN_USERNAME/ATLASSIAN_API_TOKEN or auth login"),
            error.MissingUrl => render.fail(ctx, exit_codes.usage, "missing ATLASSIAN_URL / atlassianUrl"),
            else => render.fail(ctx, exit_codes.generic, "failed to open session"),
        };
    };
    defer sess.deinit(allocator);

    if (std.mem.eql(u8, resource, "issue")) {
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue get KEY");
            var result = jira_issue.get(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create")) {
            const body = util.readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue create --body file.json");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue create --body file.json");
            var result = jira_issue.create(&sess.client, allocator, sess.site, sess.auth_header, b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "update")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue update KEY --body file.json");
            const body = util.readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = jira_issue.update(&sess.client, allocator, sess.site, sess.auth_header, rest[0], b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "delete")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue delete KEY");
            var result = jira_issue.deleteIssue(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "search") or std.mem.eql(u8, verb, "list")) {
            const jql = util.flagValue(rest, "--jql") orelse "order by updated DESC";
            const max: u32 = if (util.flagValue(rest, "--max")) |m| std.fmt.parseInt(u32, m, 10) catch 50 else 25;
            var result = jira_issue.search(&sess.client, allocator, sess.site, sess.auth_header, jql, max) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        return util.notImpl(ctx, "jira issue");
    }

    if (std.mem.eql(u8, resource, "project")) {
        if (std.mem.eql(u8, verb, "list")) {
            var result = jira_project.list(&sess.client, allocator, sess.site, sess.auth_header) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira project get KEY");
            var result = jira_project.get(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "update") or std.mem.eql(u8, verb, "delete")) {
            return util.notImpl(ctx, "jira project create|update|delete");
        }
        return render.fail(ctx, exit_codes.usage, "usage: atlassian jira project <list|get|…>");
    }

    if (std.mem.eql(u8, resource, "board")) {
        if (std.mem.eql(u8, verb, "list")) {
            var result = jira_board.list(&sess.client, allocator, sess.site, sess.auth_header) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira board get ID");
            var result = jira_board.get(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "backlog") or std.mem.eql(u8, verb, "create")) {
            return util.notImpl(ctx, "jira board");
        }
        return util.notImpl(ctx, "jira board");
    }

    if (std.mem.eql(u8, resource, "sprint")) {
        if (std.mem.eql(u8, verb, "list")) {
            const board_id = util.flagValue(rest, "--board") orelse return render.fail(ctx, exit_codes.usage, "usage: atlassian jira sprint list --board ID");
            var result = jira_sprint.listForBoard(&sess.client, allocator, sess.site, sess.auth_header, board_id) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira sprint get ID");
            var result = jira_sprint.get(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "start") or std.mem.eql(u8, verb, "complete")) {
            return util.notImpl(ctx, "jira sprint");
        }
        return util.notImpl(ctx, "jira sprint");
    }

    return render.fail(ctx, exit_codes.usage, "unknown jira resource");
}
