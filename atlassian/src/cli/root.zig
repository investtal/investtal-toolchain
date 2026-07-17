const std = @import("std");
const Io = std.Io;

const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");
const config_mod = @import("../config/root.zig");
const auth_mod = @import("../auth/root.zig");
const auth_store = @import("../auth/store.zig");
const auth_oauth = @import("../auth/oauth.zig");
const auth_login = @import("../auth/login.zig");
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");
const jira_issue = @import("../jira/issue.zig");
const jira_project = @import("../jira/project.zig");
const jira_board = @import("../jira/board.zig");
const jira_sprint = @import("../jira/sprint.zig");
const conf_page = @import("../confluence/page.zig");
const conf_space = @import("../confluence/space.zig");
const platform_goal = @import("../platform/goal.zig");
const platform_team = @import("../platform/team.zig");
const api_raw = @import("../api/raw.zig");

pub const VERSION = "0.1.0";

const help_text =
    \\atlassian — Investtal Atlassian CLI v0.1.0
    \\
    \\Usage:
    \\  atlassian [--json] [--config PATH] [-v] <product> <resource> <verb> [args]
    \\
    \\Products:
    \\  auth        login | logout | status | refresh
    \\  config      get | set | list | path
    \\  jira        issue | project | board | sprint
    \\  platform    goal | team
    \\  confluence  page | space | comment
    \\  api         request METHOD PATH
    \\  version     print version
    \\
    \\Examples:
    \\  atlassian config set atlassianUrl https://acme.atlassian.net
    \\  atlassian jira issue get PROJ-1
    \\  atlassian confluence page get 123
    \\  atlassian platform team get TEAM_ID
    \\  atlassian api request GET issue/PROJ-1 --product jira
    \\
;

pub fn run(init: std.process.Init) u8 {
    const allocator = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();

    const args = init.minimal.args.toSlice(arena) catch return exit_codes.generic;

    var global = flags.parse(allocator, args) catch {
        return usageOut(allocator, io, false, "invalid global flags");
    };
    defer global.deinit(allocator);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const ctx = render.Context{
        .json = global.json,
        .out = &stdout_fw.interface,
        .err = &stderr_fw.interface,
        .allocator = allocator,
    };

    if (global.rest.len == 0) {
        render.successText(ctx, help_text);
        return exit_codes.ok;
    }

    const product = global.rest[0];
    if (std.mem.eql(u8, product, "help") or std.mem.eql(u8, product, "-h") or std.mem.eql(u8, product, "--help")) {
        render.successText(ctx, help_text);
        return exit_codes.ok;
    }
    if (std.mem.eql(u8, product, "version") or std.mem.eql(u8, product, "--version")) {
        render.successText(ctx, VERSION);
        return exit_codes.ok;
    }

    if (std.mem.eql(u8, product, "config")) return cmdConfig(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "auth")) return cmdAuth(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "jira")) return cmdJira(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "platform")) return cmdPlatform(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "confluence")) return cmdConfluence(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "api")) return cmdApi(ctx, allocator, io, global);

    return render.fail(ctx, exit_codes.usage, "unknown product; run atlassian --help");
}

fn usageOut(allocator: std.mem.Allocator, io: Io, json: bool, msg: []const u8) u8 {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const ctx = render.Context{ .json = json, .out = &stderr_fw.interface, .err = &stderr_fw.interface, .allocator = allocator };
    return render.fail(ctx, exit_codes.usage, msg);
}

fn notImpl(ctx: render.Context, what: []const u8) u8 {
    const msg = std.fmt.allocPrint(ctx.allocator, "not implemented: {s}", .{what}) catch "not implemented";
    defer if (msg.ptr != "not implemented".ptr) ctx.allocator.free(msg);
    return render.fail(ctx, exit_codes.not_implemented, msg);
}

fn cmdConfig(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 2) return render.fail(ctx, exit_codes.usage, "usage: atlassian config <get|set|list|path> …");
    const verb = global.rest[1];

    if (std.mem.eql(u8, verb, "path")) {
        const path = config_mod.resolvedPath(allocator, global.config_path) catch return render.fail(ctx, exit_codes.generic, "cannot resolve config path");
        defer allocator.free(path);
        render.successText(ctx, path);
        return exit_codes.ok;
    }

    var cfg = config_mod.load(allocator, io, global.config_path) catch return render.fail(ctx, exit_codes.generic, "failed to load config");
    defer cfg.deinit(allocator);

    if (std.mem.eql(u8, verb, "list")) {
        const token_disp: []const u8 = blk: {
            if (cfg.api_token) |t| {
                if (t.len > 0) break :blk "***";
            }
            break :blk "";
        };
        const text = std.fmt.allocPrint(allocator, "atlassianUrl={s}\natlassianUsername={s}\natlassianApiToken={s}\natlassianCloud={s}\norgId={s}\ncloudId={s}\nauth={s}\nhttp.retries={d}\n", .{
            cfg.url orelse "",
            cfg.username orelse "",
            token_disp,
            if (cfg.cloud) "true" else "false",
            cfg.org_id orelse "",
            cfg.cloud_id orelse "",
            @tagName(cfg.auth_mode),
            cfg.http_retries,
        }) catch return exit_codes.generic;
        defer allocator.free(text);
        render.successText(ctx, text);
        return exit_codes.ok;
    }

    if (std.mem.eql(u8, verb, "get")) {
        if (global.rest.len < 3) return render.fail(ctx, exit_codes.usage, "usage: atlassian config get KEY");
        const key = global.rest[2];
        if (std.mem.eql(u8, key, "atlassianCloud") or std.mem.eql(u8, key, "cloud")) {
            render.successText(ctx, if (cfg.cloud) "true" else "false");
            return exit_codes.ok;
        }
        if (std.mem.eql(u8, key, "http.retries") or std.mem.eql(u8, key, "retries")) {
            const s = std.fmt.allocPrint(allocator, "{d}", .{cfg.http_retries}) catch return exit_codes.generic;
            defer allocator.free(s);
            render.successText(ctx, s);
            return exit_codes.ok;
        }
        const v = config_mod.getKey(cfg, key) orelse return render.fail(ctx, exit_codes.not_found, "key not set");
        render.successText(ctx, v);
        return exit_codes.ok;
    }

    if (std.mem.eql(u8, verb, "set")) {
        if (global.rest.len < 4) return render.fail(ctx, exit_codes.usage, "usage: atlassian config set KEY VALUE");
        const key = global.rest[2];
        const value = global.rest[3];
        config_mod.setKey(&cfg, allocator, key, value) catch return render.fail(ctx, exit_codes.usage, "unknown config key");
        const path = cfg.source_path orelse (config_mod.resolvedPath(allocator, global.config_path) catch return exit_codes.generic);
        config_mod.save(allocator, io, cfg, path) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "failed to save config: {s} path={s}", .{ @errorName(err), path }) catch "failed to save config";
            return render.fail(ctx, exit_codes.generic, msg);
        };
        render.successText(ctx, "ok");
        return exit_codes.ok;
    }

    return render.fail(ctx, exit_codes.usage, "usage: atlassian config <get|set|list|path>");
}

fn cmdAuth(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
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
        const text = std.fmt.allocPrint(allocator, "mode={s}\nurl={s}\ncloud_id={s}\nexpires_at_unix={d}\n", .{
            mode,
            cfg.url orelse "",
            cloud,
            exp,
        }) catch return exit_codes.generic;
        defer allocator.free(text);
        render.successText(ctx, text);
        return exit_codes.ok;
    }

    if (std.mem.eql(u8, verb, "login")) {
        var tokens = auth_login.interactiveLogin(allocator, io, cfg, auth_oauth.DEFAULT_SCOPES) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "oauth login failed: {s}", .{@errorName(err)}) catch "oauth login failed";
            defer allocator.free(msg);
            return render.fail(ctx, exit_codes.auth, msg);
        };
        defer tokens.deinit(allocator);
        cfg.auth_mode = .oauth;
        if (tokens.cloud_id) |cid| {
            config_mod.setKey(&cfg, allocator, "cloudId", cid) catch {};
        }
        config_mod.setKey(&cfg, allocator, "auth", "oauth") catch {};
        if (cfg.source_path) |p| config_mod.save(allocator, io, cfg, p) catch {};
        render.successText(ctx, "login ok");
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
            new_tokens.cloud_id = allocator.dupe(u8, cid) catch null;
        }
        auth_store.saveTokens(allocator, io, new_tokens) catch return render.fail(ctx, exit_codes.generic, "failed to save tokens");
        render.successText(ctx, "refreshed");
        return exit_codes.ok;
    }

    return render.fail(ctx, exit_codes.usage, "usage: atlassian auth <login|logout|status|refresh>");
}

const Session = struct {
    cfg: config_mod.Config,
    site: transport.Site,
    auth_header: []u8,
    client: http_client.Client,
    tokens: ?auth_store.TokenSet = null,

    fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.auth_header);
        self.cfg.deinit(allocator);
        if (self.tokens) |*t| t.deinit(allocator);
    }
};

fn openSession(allocator: std.mem.Allocator, io: Io, global: flags.Global) !Session {
    var cfg = try config_mod.load(allocator, io, global.config_path);
    errdefer cfg.deinit(allocator);
    var tokens = auth_store.loadTokens(allocator, io) catch null;

    // OAuth ensureValid: refresh when access token is near absolute expiry.
    if (cfg.auth_mode == .oauth) {
        if (tokens) |*t| {
            const now = Io.Clock.real.now(io).toSeconds();
            if (t.refresh_token) |rt| {
                if (t.expires_at_unix < now + 120) {
                    if (cfg.oauth_client_id) |cid| {
                        if (cfg.oauth_client_secret) |sec| {
                            var client: http_client.Client = .{ .allocator = allocator, .io = io, .retries = cfg.http_retries };
                            if (auth_oauth.refresh(&client, allocator, cid, sec, rt)) |new_t| {
                                var nt = new_t;
                                if (t.cloud_id) |c| {
                                    nt.cloud_id = allocator.dupe(u8, c) catch null;
                                }
                                auth_store.saveTokens(allocator, io, nt) catch {};
                                t.deinit(allocator);
                                tokens = nt;
                            } else |_| {}
                        }
                    }
                }
            }
        }
    }

    if (cfg.cloud_id == null) {
        if (tokens) |t| {
            if (t.cloud_id) |cid| {
                cfg.cloud_id = try allocator.dupe(u8, cid);
            }
        }
    }
    const auth_ctx = auth_mod.fromConfig(cfg, tokens);
    const header = auth_ctx.authorizationHeader(allocator) catch {
        if (tokens) |*t| t.deinit(allocator);
        cfg.deinit(allocator);
        return error.MissingCredentials;
    };
    const site = cfg.site() catch {
        allocator.free(header);
        if (tokens) |*t| t.deinit(allocator);
        cfg.deinit(allocator);
        return error.MissingUrl;
    };
    return .{
        .cfg = cfg,
        .site = site,
        .auth_header = header,
        .client = .{
            .allocator = allocator,
            .io = io,
            .retries = cfg.http_retries,
            .verbose = global.verbose,
        },
        .tokens = tokens,
    };
}

fn handleResult(ctx: render.Context, allocator: std.mem.Allocator, result: *http_client.Result) u8 {
    defer result.deinit(allocator);
    return switch (result.*) {
        .ok => |r| {
            render.successBody(ctx, r.body, r.body);
            return exit_codes.ok;
        },
        .err => |e| render.failApi(ctx, e),
    };
}

fn readBodyArg(allocator: std.mem.Allocator, io: Io, rest: []const []const u8) !?[]u8 {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], "--body")) {
            if (i + 1 >= rest.len) return error.MissingBody;
            const path = rest[i + 1];
            if (std.mem.eql(u8, path, "-")) {
                return error.StdinBodyNotSupported;
            }
            return try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
        }
        if (std.mem.startsWith(u8, rest[i], "--body=")) {
            const path = rest[i]["--body=".len..];
            return try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(8 * 1024 * 1024));
        }
    }
    return null;
}

fn flagValue(rest: []const []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < rest.len) : (i += 1) {
        if (std.mem.eql(u8, rest[i], name)) {
            if (i + 1 < rest.len) return rest[i + 1];
            return null;
        }
        // Match --flag=value without heap allocation.
        if (rest[i].len > name.len + 1 and std.mem.startsWith(u8, rest[i], name) and rest[i][name.len] == '=') {
            return rest[i][name.len + 1 ..];
        }
    }
    return null;
}

fn cmdJira(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 3) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira <issue|project|board|sprint> <verb> …");
    const resource = global.rest[1];
    const verb = global.rest[2];
    const rest = global.rest[3..];

    // Catalog stubs that must not require credentials.
    if (std.mem.eql(u8, resource, "project") and (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "update") or std.mem.eql(u8, verb, "delete"))) {
        return notImpl(ctx, "jira project create|update|delete");
    }
    if (std.mem.eql(u8, resource, "board") and (std.mem.eql(u8, verb, "backlog") or std.mem.eql(u8, verb, "create"))) {
        return notImpl(ctx, "jira board");
    }
    if (std.mem.eql(u8, resource, "sprint") and (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "start") or std.mem.eql(u8, verb, "complete"))) {
        return notImpl(ctx, "jira sprint");
    }

    var session = openSession(allocator, io, global) catch |err| {
        return switch (err) {
            error.MissingCredentials => render.fail(ctx, exit_codes.auth, "missing credentials; set ATLASSIAN_USERNAME/ATLASSIAN_API_TOKEN or auth login"),
            error.MissingUrl => render.fail(ctx, exit_codes.usage, "missing ATLASSIAN_URL / atlassianUrl"),
            else => render.fail(ctx, exit_codes.generic, "failed to open session"),
        };
    };
    defer session.deinit(allocator);

    if (std.mem.eql(u8, resource, "issue")) {
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue get KEY");
            var result = jira_issue.get(&session.client, allocator, session.site, session.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create")) {
            const body = readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue create --body file.json");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue create --body file.json");
            var result = jira_issue.create(&session.client, allocator, session.site, session.auth_header, b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "update")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue update KEY --body file.json");
            const body = readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = jira_issue.update(&session.client, allocator, session.site, session.auth_header, rest[0], b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "delete")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira issue delete KEY");
            var result = jira_issue.deleteIssue(&session.client, allocator, session.site, session.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "search") or std.mem.eql(u8, verb, "list")) {
            const jql = flagValue(rest, "--jql") orelse "order by updated DESC";
            const max: u32 = if (flagValue(rest, "--max")) |m| std.fmt.parseInt(u32, m, 10) catch 50 else 25;
            var result = jira_issue.search(&session.client, allocator, session.site, session.auth_header, jql, max) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        return notImpl(ctx, "jira issue");
    }

    if (std.mem.eql(u8, resource, "project")) {
        if (std.mem.eql(u8, verb, "list")) {
            var result = jira_project.list(&session.client, allocator, session.site, session.auth_header) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira project get KEY");
            var result = jira_project.get(&session.client, allocator, session.site, session.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "update") or std.mem.eql(u8, verb, "delete")) {
            return notImpl(ctx, "jira project create|update|delete");
        }
        return render.fail(ctx, exit_codes.usage, "usage: atlassian jira project <list|get|…>");
    }

    if (std.mem.eql(u8, resource, "board")) {
        if (std.mem.eql(u8, verb, "list")) {
            var result = jira_board.list(&session.client, allocator, session.site, session.auth_header) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira board get ID");
            var result = jira_board.get(&session.client, allocator, session.site, session.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "backlog") or std.mem.eql(u8, verb, "create")) {
            return notImpl(ctx, "jira board");
        }
        return notImpl(ctx, "jira board");
    }

    if (std.mem.eql(u8, resource, "sprint")) {
        if (std.mem.eql(u8, verb, "list")) {
            const board_id = flagValue(rest, "--board") orelse return render.fail(ctx, exit_codes.usage, "usage: atlassian jira sprint list --board ID");
            var result = jira_sprint.listForBoard(&session.client, allocator, session.site, session.auth_header, board_id) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian jira sprint get ID");
            var result = jira_sprint.get(&session.client, allocator, session.site, session.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "start") or std.mem.eql(u8, verb, "complete")) {
            return notImpl(ctx, "jira sprint");
        }
        return notImpl(ctx, "jira sprint");
    }

    return render.fail(ctx, exit_codes.usage, "unknown jira resource");
}

fn cmdPlatform(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 3) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform <goal|team> <verb> …");
    const resource = global.rest[1];
    const verb = global.rest[2];
    const rest = global.rest[3..];

    if (std.mem.eql(u8, resource, "goal") and (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "delete") or std.mem.eql(u8, verb, "watch") or std.mem.eql(u8, verb, "link-team"))) {
        return notImpl(ctx, "platform goal");
    }
    if (std.mem.eql(u8, resource, "team") and std.mem.eql(u8, verb, "list")) {
        return notImpl(ctx, "platform team list (no public list endpoint)");
    }

    var session = openSession(allocator, io, global) catch |err| {
        return switch (err) {
            error.MissingCredentials => render.fail(ctx, exit_codes.auth, "missing credentials"),
            error.MissingUrl => render.fail(ctx, exit_codes.usage, "missing ATLASSIAN_URL"),
            else => render.fail(ctx, exit_codes.generic, "session failed"),
        };
    };
    defer session.deinit(allocator);

    if (std.mem.eql(u8, resource, "goal")) {
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform goal get ID");
            var result = platform_goal.get(&session.client, allocator, session.site, session.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "list")) {
            const first: u32 = if (flagValue(rest, "--first")) |f| std.fmt.parseInt(u32, f, 10) catch 20 else 20;
            var result = platform_goal.list(&session.client, allocator, session.site, session.auth_header, first) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "update")) {
            const body = readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "usage: atlassian platform goal update --body vars.json");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = platform_goal.update(&session.client, allocator, session.site, session.auth_header, b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create") or std.mem.eql(u8, verb, "delete") or std.mem.eql(u8, verb, "watch") or std.mem.eql(u8, verb, "link-team")) {
            return notImpl(ctx, "platform goal");
        }
        return notImpl(ctx, "platform goal");
    }

    if (std.mem.eql(u8, resource, "team")) {
        const org = session.cfg.org_id orelse return render.fail(ctx, exit_codes.usage, "set orgId / ATLASSIAN_ORG_ID for teams");
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team get TEAM_ID");
            var result = platform_team.get(&session.client, allocator, session.site, session.auth_header, org, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create")) {
            const body = readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = platform_team.create(&session.client, allocator, session.site, session.auth_header, org, b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "update")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team update TEAM_ID --body patch.json");
            const body = readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = platform_team.update(&session.client, allocator, session.site, session.auth_header, org, rest[0], b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "delete")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team delete TEAM_ID");
            var result = platform_team.deleteTeam(&session.client, allocator, session.site, session.auth_header, org, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "members")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team members TEAM_ID");
            var result = platform_team.members(&session.client, allocator, session.site, session.auth_header, org, rest[0], "{\"first\":50}") catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "add-member")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team add-member TEAM_ID --account-id ID");
            const aid = flagValue(rest, "--account-id") orelse return render.fail(ctx, exit_codes.usage, "missing --account-id");
            const body = std.fmt.allocPrint(allocator, "{{\"accountIds\":[\"{s}\"]}}", .{aid}) catch return exit_codes.generic;
            defer allocator.free(body);
            var result = platform_team.addMembers(&session.client, allocator, session.site, session.auth_header, org, rest[0], body) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "remove-member")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian platform team remove-member TEAM_ID --account-id ID");
            const aid = flagValue(rest, "--account-id") orelse return render.fail(ctx, exit_codes.usage, "missing --account-id");
            const body = std.fmt.allocPrint(allocator, "{{\"accountIds\":[\"{s}\"]}}", .{aid}) catch return exit_codes.generic;
            defer allocator.free(body);
            var result = platform_team.removeMembers(&session.client, allocator, session.site, session.auth_header, org, rest[0], body) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "list")) {
            return notImpl(ctx, "platform team list (no public list endpoint)");
        }
        return notImpl(ctx, "platform team");
    }

    return render.fail(ctx, exit_codes.usage, "unknown platform resource");
}

fn cmdConfluence(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 3) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence <page|space|comment> <verb> …");
    const resource = global.rest[1];
    const verb = global.rest[2];
    const rest = global.rest[3..];

    if (std.mem.eql(u8, resource, "comment")) {
        return notImpl(ctx, "confluence comment");
    }
    if (std.mem.eql(u8, resource, "space") and !(std.mem.eql(u8, verb, "list") or std.mem.eql(u8, verb, "get"))) {
        return notImpl(ctx, "confluence space");
    }

    var session = openSession(allocator, io, global) catch |err| {
        return switch (err) {
            error.MissingCredentials => render.fail(ctx, exit_codes.auth, "missing credentials"),
            error.MissingUrl => render.fail(ctx, exit_codes.usage, "missing ATLASSIAN_URL"),
            else => render.fail(ctx, exit_codes.generic, "session failed"),
        };
    };
    defer session.deinit(allocator);

    if (std.mem.eql(u8, resource, "page")) {
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence page get ID");
            var result = conf_page.get(&session.client, allocator, session.site, session.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create")) {
            const body = readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = conf_page.create(&session.client, allocator, session.site, session.auth_header, b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "update")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence page update ID --body file.json");
            const body = readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = conf_page.update(&session.client, allocator, session.site, session.auth_header, rest[0], b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "delete")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence page delete ID");
            var result = conf_page.deletePage(&session.client, allocator, session.site, session.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "list")) {
            const space = flagValue(rest, "--space");
            var result = conf_page.list(&session.client, allocator, session.site, session.auth_header, space, 25) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        return notImpl(ctx, "confluence page");
    }

    if (std.mem.eql(u8, resource, "space")) {
        if (std.mem.eql(u8, verb, "list")) {
            var result = conf_space.list(&session.client, allocator, session.site, session.auth_header) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence space get ID");
            var result = conf_space.get(&session.client, allocator, session.site, session.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return handleResult(ctx, allocator, &result);
        }
        return notImpl(ctx, "confluence space");
    }

    if (std.mem.eql(u8, resource, "comment")) {
        return notImpl(ctx, "confluence comment");
    }

    return render.fail(ctx, exit_codes.usage, "unknown confluence resource");
}

fn cmdApi(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 2 or !std.mem.eql(u8, global.rest[1], "request")) {
        return render.fail(ctx, exit_codes.usage, "usage: atlassian api request METHOD PATH [--product jira|confluence|gateway|graphql] [--body file]");
    }
    if (global.rest.len < 4) return render.fail(ctx, exit_codes.usage, "usage: atlassian api request METHOD PATH …");
    const method_s = global.rest[2];
    const path = global.rest[3];
    const rest = global.rest[4..];

    const method: std.http.Method = if (std.ascii.eqlIgnoreCase(method_s, "GET"))
        .GET
    else if (std.ascii.eqlIgnoreCase(method_s, "POST"))
        .POST
    else if (std.ascii.eqlIgnoreCase(method_s, "PUT"))
        .PUT
    else if (std.ascii.eqlIgnoreCase(method_s, "PATCH"))
        .PATCH
    else if (std.ascii.eqlIgnoreCase(method_s, "DELETE"))
        .DELETE
    else
        return render.fail(ctx, exit_codes.usage, "unsupported method");

    const product_s = flagValue(rest, "--product") orelse "jira";
    const product: transport.Product = if (std.mem.eql(u8, product_s, "jira"))
        .jira
    else if (std.mem.eql(u8, product_s, "confluence"))
        .confluence
    else if (std.mem.eql(u8, product_s, "gateway"))
        .gateway
    else if (std.mem.eql(u8, product_s, "graphql"))
        .graphql
    else if (std.mem.eql(u8, product_s, "jira_software"))
        .jira_software
    else
        return render.fail(ctx, exit_codes.usage, "unknown --product");

    var session = openSession(allocator, io, global) catch |err| {
        return switch (err) {
            error.MissingCredentials => render.fail(ctx, exit_codes.auth, "missing credentials"),
            error.MissingUrl => render.fail(ctx, exit_codes.usage, "missing ATLASSIAN_URL"),
            else => render.fail(ctx, exit_codes.generic, "session failed"),
        };
    };
    defer session.deinit(allocator);

    const body = readBodyArg(allocator, io, rest) catch null;
    defer if (body) |b| allocator.free(b);

    var result = api_raw.rawRequest(&session.client, allocator, session.site, session.auth_header, method, product, path, body) catch return render.fail(ctx, exit_codes.network, "request failed");
    return handleResult(ctx, allocator, &result);
}
