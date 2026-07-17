const std = @import("std");
const Io = std.Io;
const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");
const config_mod = @import("../config/root.zig");
const util = @import("util.zig");

pub fn run(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
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
