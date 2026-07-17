const std = @import("std");
const Io = std.Io;
const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");
const conf_page = @import("../confluence/page.zig");
const conf_space = @import("../confluence/space.zig");
const util = @import("util.zig");
const session_mod = @import("session.zig");

pub fn run(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
    if (global.rest.len < 3) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence <page|space|comment> <verb> …");
    const resource = global.rest[1];
    const verb = global.rest[2];
    const rest = global.rest[3..];

    if (std.mem.eql(u8, resource, "comment")) {
        return util.notImpl(ctx, "confluence comment");
    }
    if (std.mem.eql(u8, resource, "space") and !(std.mem.eql(u8, verb, "list") or std.mem.eql(u8, verb, "get"))) {
        return util.notImpl(ctx, "confluence space");
    }

    var sess = session_mod.openSession(allocator, io, global) catch |err| {
        return switch (err) {
            error.MissingCredentials => render.fail(ctx, exit_codes.auth, "missing credentials"),
            error.MissingUrl => render.fail(ctx, exit_codes.usage, "missing ATLASSIAN_URL"),
            else => render.fail(ctx, exit_codes.generic, "session failed"),
        };
    };
    defer sess.deinit(allocator);

    if (std.mem.eql(u8, resource, "page")) {
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence page get ID");
            var result = conf_page.get(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "create")) {
            const body = util.readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = conf_page.create(&sess.client, allocator, sess.site, sess.auth_header, b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "update")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence page update ID --body file.json");
            const body = util.readBodyArg(allocator, io, rest) catch return render.fail(ctx, exit_codes.usage, "missing --body");
            defer if (body) |b| allocator.free(b);
            const b = body orelse return render.fail(ctx, exit_codes.usage, "missing --body");
            var result = conf_page.update(&sess.client, allocator, sess.site, sess.auth_header, rest[0], b) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "delete")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence page delete ID");
            var result = conf_page.deletePage(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "list")) {
            const space = util.flagValue(rest, "--space");
            var result = conf_page.list(&sess.client, allocator, sess.site, sess.auth_header, space, 25) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        return util.notImpl(ctx, "confluence page");
    }

    if (std.mem.eql(u8, resource, "space")) {
        if (std.mem.eql(u8, verb, "list")) {
            var result = conf_space.list(&sess.client, allocator, sess.site, sess.auth_header) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        if (std.mem.eql(u8, verb, "get")) {
            if (rest.len < 1) return render.fail(ctx, exit_codes.usage, "usage: atlassian confluence space get ID");
            var result = conf_space.get(&sess.client, allocator, sess.site, sess.auth_header, rest[0]) catch return render.fail(ctx, exit_codes.network, "request failed");
            return util.handleResult(ctx, allocator, &result);
        }
        return util.notImpl(ctx, "confluence space");
    }

    if (std.mem.eql(u8, resource, "comment")) {
        return util.notImpl(ctx, "confluence comment");
    }

    return render.fail(ctx, exit_codes.usage, "unknown confluence resource");
}
