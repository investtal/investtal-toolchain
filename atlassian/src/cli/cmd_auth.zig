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
