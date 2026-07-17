const std = @import("std");
const Io = std.Io;
const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");
const transport = @import("../http/transport.zig");
const api_raw = @import("../api/raw.zig");
const util = @import("util.zig");
const session_mod = @import("session.zig");

pub fn run(ctx: render.Context, allocator: std.mem.Allocator, io: Io, global: flags.Global) u8 {
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

    const product_s = util.flagValue(rest, "--product") orelse "jira";
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

    var sess = session_mod.openSession(allocator, io, global) catch |err| {
        return switch (err) {
            error.MissingCredentials => render.fail(ctx, exit_codes.auth, "missing credentials"),
            error.MissingUrl => render.fail(ctx, exit_codes.usage, "missing ATLASSIAN_URL"),
            else => render.fail(ctx, exit_codes.generic, "session failed"),
        };
    };
    defer sess.deinit(allocator);

    const body = util.readBodyArg(allocator, io, rest) catch |err| {
        return render.fail(ctx, exit_codes.usage, @errorName(err));
    };
    defer if (body) |b| allocator.free(b);

    var result = api_raw.rawRequest(&sess.client, allocator, sess.site, sess.auth_header, method, product, path, body) catch return render.fail(ctx, exit_codes.network, "request failed");
    return util.handleResult(ctx, allocator, &result);
}
