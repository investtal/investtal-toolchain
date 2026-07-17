const std = @import("std");
const Io = std.Io;
const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");
const jira_issue = @import("../jira/issue.zig");
const jira_project = @import("../jira/project.zig");
const jira_board = @import("../jira/board.zig");
const jira_sprint = @import("../jira/sprint.zig");
const jira_jql = @import("../jira/jql.zig");
const util = @import("util.zig");
const session_mod = @import("session.zig");

pub fn run(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 3) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira <issue|project|board|sprint> <verb> …");
    const resource = global.rest[1];
    const verb = global.rest[2];
    const rest = global.rest[3..];

    if (std.mem.eql(u8, resource, "project") and (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "update") or std.mem.eql(u8, verb, "delete"))) {
        return util.notImpl(ctx, "jira project create|update|delete");
    }
    if (std.mem.eql(u8, resource, "board") and std.mem.eql(u8, verb, "create")) {
        return util.notImpl(ctx, "jira board create");
    }
    if (std.mem.eql(u8, resource, "sprint") and (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "start") or std.mem.eql(u8, verb, "complete"))) {
        return util.notImpl(ctx, "jira sprint create|start|complete");
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
            const base_jql = util.flagValue(rest, "--jql");
            const max: u32 = parseMax(rest, 25);
            const jql = buildFilterJql(allocator, base_jql, util.flagValue(rest, "--assignee")) catch |err| {
                return switch (err) {
                    error.EmptyAssignee => render.fail(ctx, exit_codes.usage, "empty --assignee"),
                    else => render.fail(ctx, exit_codes.generic, "failed to build jql"),
                };
            };
            defer if (jql) |j| allocator.free(j);
            const jql_final = jql orelse "order by updated DESC";
            var result = jira_issue.search(&sess.client, allocator, sess.site, sess.auth_header, jql_final, max) catch return render.fail(ctx, exit_codes.network, "request failed");
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
        if (std.mem.eql(u8, verb, "backlog")) {
            // Preferred: Agile board backlog. Fallback: platform JQL (needs --project) when OAuth lacks Software scopes.
            const board_id = util.flagValue(rest, "--board") orelse positionalOrNull(rest);
            const project = util.flagValue(rest, "--project");
            const max: u32 = parseMax(rest, 50);
            const assignee = util.flagValue(rest, "--assignee");
            const extra = util.flagValue(rest, "--jql");

            if (board_id == null and project == null) {
                return render.fail(ctx, exit_codes.usage, "usage: atlassian jira board backlog --board ID | --project KEY [--assignee me|USER] [--jql '…'] [--max N]");
            }

            // JQL-only path (no Agile scopes needed)
            if (board_id == null) {
                const jql = buildBacklogJql(allocator, project.?, extra, assignee) catch |err| {
                    return switch (err) {
                        error.EmptyAssignee => render.fail(ctx, exit_codes.usage, "empty --assignee"),
                        else => render.fail(ctx, exit_codes.generic, "failed to build jql"),
                    };
                };
                defer allocator.free(jql);
                var result = jira_issue.search(&sess.client, allocator, sess.site, sess.auth_header, jql, max) catch return render.fail(ctx, exit_codes.network, "request failed");
                return util.handleResult(ctx, allocator, &result);
            }

            const jql = buildFilterJql(allocator, extra, assignee) catch |err| {
                return switch (err) {
                    error.EmptyAssignee => render.fail(ctx, exit_codes.usage, "empty --assignee"),
                    else => render.fail(ctx, exit_codes.generic, "failed to build jql"),
                };
            };
            defer if (jql) |j| allocator.free(j);
            var result = jira_board.backlog(&sess.client, allocator, sess.site, sess.auth_header, board_id.?, jql, max) catch return render.fail(ctx, exit_codes.network, "request failed");
            switch (result) {
                .err => |e| {
                    if (e.status == 401) {
                        // Auto-fallback when --project is provided
                        if (project) |pk| {
                            result.deinit(allocator);
                            const fb = buildBacklogJql(allocator, pk, extra, assignee) catch return render.fail(ctx, exit_codes.generic, "failed to build jql");
                            defer allocator.free(fb);
                            std.log.warn("Agile 401 — falling back to JQL backlog for project {s}", .{pk});
                            var fb_result = jira_issue.search(&sess.client, allocator, sess.site, sess.auth_header, fb, max) catch return render.fail(ctx, exit_codes.network, "request failed");
                            return util.handleResult(ctx, allocator, &fb_result);
                        }
                        const msg =
                            \\Agile API unauthorized (401) — token lacks Jira Software scopes.
                            \\  Granted token only has platform scopes (read:jira-work) → issue search works.
                            \\  Board backlog needs: read:board-scope:jira-software + read:issue-details:jira
                            \\
                            \\Important: "select all" under classic **Jira API** is NOT enough.
                            \\You must also enable **Jira Software API** permissions on the OAuth app.
                            \\
                            \\Fix:
                            \\  1) developer.atlassian.com → app → Permissions → **Jira Software API**
                            \\  2) Enable read:board-scope:jira-software, read:sprint:jira-software,
                            \\     read:issue-details:jira, read:project:jira
                            \\  3) id.atlassian.com/manage-profile/apps → remove this app
                            \\  4) atlassian auth login  (then: auth status → agile_board_scope=ok)
                            \\
                            \\Works right now without Agile (platform JQL):
                            \\  atlassian --markdown jira board backlog --project IVT --assignee me
                        ;
                        if (ctx.isJson()) return util.handleResult(ctx, allocator, &result);
                        result.deinit(allocator);
                        return render.fail(ctx, exit_codes.auth, msg);
                    }
                },
                else => {},
            }
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create")) {
            return util.notImpl(ctx, "jira board create");
        }
        return render.fail(ctx, exit_codes.usage, "usage: atlassian jira board <list|get|backlog>");
    }

    if (std.mem.eql(u8, resource, "sprint")) {
        if (std.mem.eql(u8, verb, "list")) {
            const board_id = util.flagValue(rest, "--board") orelse return render.fail(ctx, exit_codes.usage, "usage: atlassian jira sprint list --board ID [--state active|future|closed]");
            if (util.flagValue(rest, "--state")) |state| {
                var result = jira_sprint.listForBoardState(&sess.client, allocator, sess.site, sess.auth_header, board_id, state) catch return render.fail(ctx, exit_codes.network, "request failed");
                return util.handleResult(ctx, allocator, &result);
            }
            var result = jira_sprint.listForBoard(&sess.client, allocator, sess.site, sess.auth_header, board_id) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira sprint get ID");
            var result = jira_sprint.get(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "issues")) {
            const sprint_id = util.flagValue(rest, "--sprint") orelse positionalOrNull(rest) orelse {
                return render.fail(ctx, exit_codes.usage, "usage: atlassian jira sprint issues ID|--sprint ID [--assignee me|USER] [--jql '…'] [--max N]");
            };
            const max: u32 = parseMax(rest, 50);
            const jql = buildFilterJql(allocator, util.flagValue(rest, "--jql"), util.flagValue(rest, "--assignee")) catch |err| {
                return switch (err) {
                    error.EmptyAssignee => render.fail(ctx, exit_codes.usage, "empty --assignee"),
                    else => render.fail(ctx, exit_codes.generic, "failed to build jql"),
                };
            };
            defer if (jql) |j| allocator.free(j);
            var result = jira_sprint.issues(&sess.client, allocator, sess.site, sess.auth_header, sprint_id, jql, max) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "current")) {
            // With --board: Agile active sprint → sprint issues.
            // Without --board: JQL `sprint in openSprints()` (works with platform scopes only).
            const max: u32 = parseMax(rest, 50);
            const extra = util.flagValue(rest, "--jql");
            const assignee = util.flagValue(rest, "--assignee");
            if (util.flagValue(rest, "--board")) |board_id| {
                const jql = buildFilterJql(allocator, extra, assignee) catch |err| {
                    return switch (err) {
                        error.EmptyAssignee => render.fail(ctx, exit_codes.usage, "empty --assignee"),
                        else => render.fail(ctx, exit_codes.generic, "failed to build jql"),
                    };
                };
                defer if (jql) |j| allocator.free(j);

                var list_result = jira_sprint.listForBoardState(&sess.client, allocator, sess.site, sess.auth_header, board_id, "active") catch return render.fail(ctx, exit_codes.network, "request failed");
                defer list_result.deinit(allocator);
                const list_body = switch (list_result) {
                    .ok => |r| r.body,
                    .err => |e| {
                        // Common OAuth gap: Agile scopes missing — fall back to openSprints JQL.
                        if (e.status == 401) {
                            const open_jql = buildOpenSprintsJql(allocator, extra, assignee) catch return render.fail(ctx, exit_codes.generic, "failed to build jql");
                            defer allocator.free(open_jql);
                            var result = jira_issue.search(&sess.client, allocator, sess.site, sess.auth_header, open_jql, max) catch return render.fail(ctx, exit_codes.network, "request failed");
                            return util.handleResult(ctx, allocator, &result);
                        }
                        return render.failApi(ctx, e);
                    },
                };
                const sprint_id = jira_sprint.firstActiveSprintId(allocator, list_body) catch {
                    return render.fail(ctx, exit_codes.generic, "failed to parse active sprints");
                };
                if (sprint_id == null) {
                    return render.fail(ctx, exit_codes.not_found, "no active sprint on this board");
                }
                defer allocator.free(sprint_id.?);

                var result = jira_sprint.issues(&sess.client, allocator, sess.site, sess.auth_header, sprint_id.?, jql, max) catch return render.fail(ctx, exit_codes.network, "request failed");
                return util.handleResult(ctx, allocator, &result);
            }

            const open_jql = buildOpenSprintsJql(allocator, extra, assignee) catch |err| {
                return switch (err) {
                    error.EmptyAssignee => render.fail(ctx, exit_codes.usage, "empty --assignee"),
                    else => render.fail(ctx, exit_codes.generic, "failed to build jql"),
                };
            };
            defer allocator.free(open_jql);
            var result = jira_issue.search(&sess.client, allocator, sess.site, sess.auth_header, open_jql, max) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "start") or std.mem.eql(u8, verb, "complete")) {
            return util.notImpl(ctx, "jira sprint create|start|complete");
        }
        return render.fail(ctx, exit_codes.usage, "usage: atlassian jira sprint <list|get|issues|current>");
    }

    return render.fail(ctx, exit_codes.usage, "unknown jira resource");
}

fn parseMax(rest: []const []const u8, default: u32) u32 {
    if (util.flagValue(rest, "--max")) |m| return std.fmt.parseInt(u32, m, 10) catch default;
    return default;
}

/// First non-flag positional arg (not starting with `-`).
fn positionalOrNull(rest: []const []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        const a = rest[i];
        if (std.mem.startsWith(u8, a, "-")) {
            // skip flag + value when the flag takes an argument
            if (std.mem.eql(u8, a, "--board") or std.mem.eql(u8, a, "--sprint") or std.mem.eql(u8, a, "--assignee") or
                std.mem.eql(u8, a, "--jql") or std.mem.eql(u8, a, "--max") or std.mem.eql(u8, a, "--state") or
                std.mem.eql(u8, a, "--body") or std.mem.eql(u8, a, "--project") or
                std.mem.startsWith(u8, a, "--board=") or std.mem.startsWith(u8, a, "--sprint=") or
                std.mem.startsWith(u8, a, "--assignee=") or std.mem.startsWith(u8, a, "--jql=") or
                std.mem.startsWith(u8, a, "--max=") or std.mem.startsWith(u8, a, "--project="))
            {
                if (std.mem.indexOfScalar(u8, a, '=') == null) i += 1;
            }
            continue;
        }
        return a;
    }
    return null;
}

fn buildFilterJql(allocator: std.mem.Allocator, base_jql: ?[]const u8, assignee: ?[]const u8) !?[]u8 {
    var assignee_clause: ?[]u8 = null;
    defer if (assignee_clause) |c| allocator.free(c);
    if (assignee) |a| {
        assignee_clause = try jira_jql.assigneeClause(allocator, a);
    }
    return try jira_jql.andClauses(allocator, assignee_clause, base_jql);
}

fn buildOpenSprintsJql(allocator: std.mem.Allocator, base_jql: ?[]const u8, assignee: ?[]const u8) ![]u8 {
    const filtered = try buildFilterJql(allocator, base_jql, assignee);
    defer if (filtered) |f| allocator.free(f);
    if (filtered) |f| {
        return try std.fmt.allocPrint(allocator, "(sprint in openSprints()) AND ({s})", .{f});
    }
    return try allocator.dupe(u8, "sprint in openSprints()");
}

/// Approximate board backlog via platform JQL (no Agile scopes).
/// Matches Scrum backlog idea: not Done, and not in an active/future sprint.
fn buildBacklogJql(allocator: std.mem.Allocator, project: []const u8, base_jql: ?[]const u8, assignee: ?[]const u8) ![]u8 {
    const core = try std.fmt.allocPrint(
        allocator,
        "project = {s} AND statusCategory != Done AND (sprint is EMPTY OR sprint not in openSprints() AND sprint not in futureSprints())",
        .{project},
    );
    defer allocator.free(core);
    const filtered = try buildFilterJql(allocator, base_jql, assignee);
    defer if (filtered) |f| allocator.free(f);
    if (filtered) |f| {
        return try std.fmt.allocPrint(allocator, "({s}) AND ({s})", .{ core, f });
    }
    return try allocator.dupe(u8, core);
}
