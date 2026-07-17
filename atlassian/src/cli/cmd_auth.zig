const std = @import("std");
const Io = std.Io;
const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");
const config_mod = @import("../config/root.zig");
const auth_store = @import("../auth/store.zig");
const auth_oauth = @import("../auth/oauth.zig");
const auth_login = @import("../auth/login.zig");
const http_client = @import("../http/client.zig");
const util = @import("util.zig");

pub fn run(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 2) return render.fail(ctx, exit_codes.usage, "usage: atlassian auth <login|logout|status|refresh>");
    const verb = global.rest[1];

    var cfg = config_mod.load(allocator, io, global.config_path) catch return render.fail(ctx, exit_codes.generic, "failed to load config");
    defer cfg.deinit(allocator);

    if (std.mem.eql(u8, verb, "logout")) {
        auth_store.clearTokens(allocator, io) catch {};
        render.successText(ctx, "logged out");
        return exit_codes.ok;
    }

    if (std.mem.eql(u8, verb, "status")) {
        var tokens = auth_store.loadTokens(allocator, io) catch null;
        defer if (tokens) |*t| t.deinit(allocator);
        const mode: []const u8 = if (cfg.auth_mode == .oauth and tokens != null) "oauth" else "basic";
        if (tokens == null and (cfg.username == null or cfg.api_token == null)) {
            return render.fail(ctx, exit_codes.auth, "no credentials; set API token or run auth login");
        }
        const cloud = if (tokens) |t| (t.cloud_id orelse cfg.cloud_id orelse "") else (cfg.cloud_id orelse "");
        const exp: i64 = if (tokens) |t| t.expires_at_unix else 0;
        const scope = if (tokens) |t| (t.scope orelse "") else "";
        const has_board = auth_oauth.scopeContains(scope, "read:board-scope:jira-software");
        const has_issue_details = auth_oauth.scopeContains(scope, "read:issue-details:jira") or auth_oauth.scopeContains(scope, "read:jira-work");
        const agile_ok = has_board and has_issue_details;
        const conf_ok = auth_oauth.scopeContains(scope, "read:space:confluence") and
            auth_oauth.scopeContains(scope, "read:page:confluence");
        const conf_write_ok = auth_oauth.scopeContains(scope, "write:page:confluence");
        const text = std.fmt.allocPrint(allocator,
            \\mode={s}
            \\url={s}
            \\cloud_id={s}
            \\expires_at_unix={d}
            \\scope={s}
            \\agile_board_scope={s}
            \\confluence_scope={s}
            \\hint={s}
            \\
        , .{
            mode,
            cfg.url orelse "",
            cloud,
            exp,
            if (scope.len > 0) scope else "(none stored — re-login)",
            if (agile_ok) "ok" else "MISSING (need read:board-scope:jira-software + read:issue-details:jira|read:jira-work)",
            if (conf_ok and conf_write_ok)
                "ok"
            else if (conf_ok)
                "read-ok write-MISSING (need write:page:confluence for page create/update)"
            else
                "MISSING (need read:space:confluence + read:page:confluence for v2 space/page)",
            if (!conf_ok)
                "Add Confluence granular scopes on the OAuth app, revoke app access, then: atlassian auth login"
            else if (!agile_ok)
                "Add Jira Software scopes on the OAuth app, then: atlassian auth login"
            else
                "Agile + Confluence v2 scopes look good",
        }) catch return exit_codes.generic;
        defer allocator.free(text);
        render.successText(ctx, text);
        return exit_codes.ok;
    }

    if (std.mem.eql(u8, verb, "login")) {
        std.log.info("Requesting OAuth scopes:\n  {s}", .{auth_oauth.DEFAULT_SCOPES});
        var tokens = auth_login.interactiveLogin(allocator, io, cfg, auth_oauth.DEFAULT_SCOPES) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "oauth login failed: {s}", .{@errorName(err)}) catch "oauth login failed";
            defer if (msg.ptr != "oauth login failed".ptr) allocator.free(msg);
            return render.fail(ctx, exit_codes.auth, msg);
        };
        defer tokens.deinit(allocator);
        cfg.auth_mode = .oauth;
        if (tokens.cloud_id) |cid| {
            config_mod.setKey(&cfg, allocator, "cloudId", cid) catch {};
        }
        config_mod.setKey(&cfg, allocator, "auth", "oauth") catch {};
        if (cfg.source_path) |p| config_mod.save(allocator, io, cfg, p) catch {};

        const granted = tokens.scope orelse "";
        var miss_agile_buf: [8][]const u8 = undefined;
        var miss_conf_buf: [8][]const u8 = undefined;
        const missing_agile = auth_oauth.missingAgileScopes(granted, &miss_agile_buf);
        const missing_conf = auth_oauth.missingConfluenceScopes(granted, &miss_conf_buf);

        if (missing_agile.len > 0 or missing_conf.len > 0) {
            var msg: std.ArrayList(u8) = .empty;
            defer msg.deinit(allocator);
            msg.appendSlice(allocator, "login ok (partial scopes)\n") catch {};

            if (missing_agile.len > 0) {
                msg.appendSlice(allocator, "WARNING: token is MISSING Jira Software scopes (board/backlog/sprint):\n") catch {};
                for (missing_agile) |s| {
                    msg.print(allocator, "  - {s}\n", .{s}) catch {};
                }
            }
            if (missing_conf.len > 0) {
                msg.appendSlice(allocator, "WARNING: token is MISSING Confluence v2 scopes (space/page):\n") catch {};
                for (missing_conf) |s| {
                    msg.print(allocator, "  - {s}\n", .{s}) catch {};
                }
            }
            msg.appendSlice(allocator,
                \\
                \\Atlassian only grants scopes that are BOTH:
                \\  (a) requested by the CLI (already done on this login), AND
                \\  (b) enabled on the OAuth app under Permissions
                \\
                \\Fix:
                \\  1) https://developer.atlassian.com/console/myapps/ → your app → Permissions
                \\  2) **Jira Software API** (not only classic Jira API): board/sprint/issue-details
                \\  3) **Confluence API** granular scopes (classic content-only is NOT enough for v2):
                \\       read:space:confluence
                \\       read:page:confluence
                \\       write:page:confluence
                \\       delete:page:confluence
                \\     plus classic if available: read:confluence-space.summary, read/write:confluence-content*
                \\  4) https://id.atlassian.com/manage-profile/apps → **Remove** this app
                \\     (refresh never adds new scopes; old grant must be revoked)
                \\  5) atlassian auth login again  (use the rebuilt CLI)
                \\  6) atlassian auth status  → agile_board_scope=ok AND confluence_scope=ok
                \\
                \\You do NOT need to reinstall the CLI package — only rebuild/update the binary
                \\so DEFAULT_SCOPES includes the new Confluence granular scopes, then re-login.
                \\
            ) catch {};
            render.successText(ctx, msg.items);
            return exit_codes.ok;
        }
        render.successText(ctx, "login ok (Jira platform + Agile + Confluence v2 scopes)");
        return exit_codes.ok;
    }

    if (std.mem.eql(u8, verb, "refresh")) {
        var tokens = auth_store.loadTokens(allocator, io) catch null;
        if (tokens == null) return render.fail(ctx, exit_codes.auth, "no tokens to refresh");
        defer tokens.?.deinit(allocator);
        const rt = tokens.?.refresh_token orelse return render.fail(ctx, exit_codes.auth, "no refresh_token");
        const client_id = cfg.oauth_client_id orelse return render.fail(ctx, exit_codes.auth, "missing oauth client id");
        const client_secret = cfg.oauth_client_secret orelse return render.fail(ctx, exit_codes.auth, "missing oauth client secret");
        var client: http_client.Client = .{ .allocator = allocator, .io = io, .retries = cfg.http_retries, .verbose = global.verbose };
        var new_tokens = auth_oauth.refresh(&client, allocator, client_id, client_secret, rt) catch return render.fail(ctx, exit_codes.auth, "refresh failed");
        defer new_tokens.deinit(allocator);
        if (tokens.?.cloud_id) |cid| {
            new_tokens.cloud_id = allocator.dupe(u8, cid) catch {
                return render.fail(ctx, exit_codes.generic, "failed to copy cloud_id on refresh");
            };
        }
        auth_store.saveTokens(allocator, io, new_tokens) catch return render.fail(ctx, exit_codes.generic, "failed to save tokens");
        render.successText(ctx, "refreshed");
        return exit_codes.ok;
    }

    return render.fail(ctx, exit_codes.usage, "usage: atlassian auth <login|logout|status|refresh>");
}
