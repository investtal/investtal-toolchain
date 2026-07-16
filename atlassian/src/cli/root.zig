//! CLI entry: global flags + product router (stubs for Task 1).

const std = @import("std");
const Io = std.Io;

const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");

pub const exit = exit_codes;
pub const Flags = flags;
pub const Render = render;

const help_text =
    \\atlassian — Atlassian Cloud CLI
    \\
    \\Usage:
    \\  atlassian [global-flags] <product> <resource> <verb> [args]
    \\
    \\Global flags:
    \\  --json              Machine-readable output (errors on stderr)
    \\  --config PATH       Config file override
    \\  -v, --verbose       Log request method/URL (never secrets)
    \\  -h, --help          Show this help
    \\
    \\Products:
    \\  auth
    \\    login [--scopes ...]
    \\    logout
    \\    status
    \\    refresh
    \\  config
    \\    get [KEY]
    \\    set KEY VALUE
    \\    list
    \\    path
    \\  jira
    \\    issue   get|create|update|delete|search|list
    \\    project get|create|update|delete|list
    \\    board   get|list|backlog
    \\    sprint  get|list|create|start|complete
    \\  platform
    \\    goal    get|list|create|update|delete|watch|link-team
    \\    team    get|list|create|update|delete|members|add-member|remove-member
    \\  confluence
    \\    page    get|create|update|delete|list
    \\    space   get|create|update|delete|list
    \\    comment get|create|update|delete|list
    \\  api
    \\    request METHOD PATH [--body FILE|-] [--product jira|confluence|gateway|graphql]
    \\
    \\Exit codes: 0 ok · 1 generic · 2 usage · 3 auth · 4 not_found · 5 rate_limit · 6 not_implemented · 7 network
    \\
;

/// Process entry for the CLI. Returns a process exit code.
pub fn run(init: std.process.Init) u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const args = init.minimal.args.toSlice(arena) catch return exit_codes.generic;

    const global = flags.parse(arena, args) catch |err| {
        var err_buf: [1024]u8 = undefined;
        var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);
        const err_w = &err_fw.interface;
        const msg: []const u8 = switch (err) {
            error.MissingConfigPath => "missing path for --config",
            error.OutOfMemory => "out of memory",
        };
        // json unknown at this point if parse failed before flags; use human.
        err_w.print("error: {s}\n", .{msg}) catch {};
        err_w.flush() catch {};
        return exit_codes.usage;
    };
    // arena-backed; no deinit required for process lifetime

    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_fw: Io.File.Writer = .init(.stdout(), io, &out_buf);
    var err_fw: Io.File.Writer = .init(.stderr(), io, &err_buf);

    const ctx = render.Context{
        .json = global.json,
        .out = &out_fw.interface,
        .err = &err_fw.interface,
    };

    const code = dispatch(ctx, global.rest);

    ctx.out.flush() catch {};
    ctx.err.flush() catch {};
    return code;
}

fn dispatch(ctx: render.Context, rest: []const []const u8) u8 {
    if (rest.len == 0) {
        return showHelp(ctx);
    }

    const head = rest[0];

    if (std.mem.eql(u8, head, "help") or
        std.mem.eql(u8, head, "-h") or
        std.mem.eql(u8, head, "--help"))
    {
        return showHelp(ctx);
    }

    if (isKnownProduct(head)) {
        return notImplemented(ctx, head, rest);
    }

    var msg_buf: [256]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, "unknown command: {s}\n\nRun `atlassian --help` for usage.", .{head}) catch "unknown command";
    render.fail(ctx, exit_codes.usage, msg);
    return exit_codes.usage;
}

fn isKnownProduct(name: []const u8) bool {
    const products = [_][]const u8{ "config", "auth", "jira", "platform", "confluence", "api" };
    for (products) |p| {
        if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
}

fn showHelp(ctx: render.Context) u8 {
    if (ctx.json) {
        render.successJson(ctx,
            \\{"ok":true,"help":true}
        );
    } else {
        render.successText(ctx, help_text);
    }
    return exit_codes.ok;
}

fn notImplemented(ctx: render.Context, product: []const u8, rest: []const []const u8) u8 {
    var path_buf: [512]u8 = undefined;
    var len: usize = 0;
    for (rest, 0..) |part, idx| {
        if (idx > 0) {
            if (len < path_buf.len) {
                path_buf[len] = ' ';
                len += 1;
            }
        }
        const copy_len = @min(part.len, path_buf.len -| len);
        @memcpy(path_buf[len..][0..copy_len], part[0..copy_len]);
        len += copy_len;
    }
    const path = path_buf[0..len];

    var msg_buf: [640]u8 = undefined;
    const msg = std.fmt.bufPrint(
        &msg_buf,
        "not implemented: {s} (product `{s}` is catalogued but not wired yet)",
        .{ path, product },
    ) catch "not implemented";

    render.fail(ctx, exit_codes.not_implemented, msg);
    return exit_codes.not_implemented;
}

test "isKnownProduct recognizes catalog" {
    try std.testing.expect(isKnownProduct("jira"));
    try std.testing.expect(isKnownProduct("config"));
    try std.testing.expect(!isKnownProduct("unknown"));
}
