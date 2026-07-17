const std = @import("std");
const Io = std.Io;

const exit_codes = @import("exit_codes.zig");
const flags = @import("flags.zig");
const render = @import("render.zig");
const cmd_config = @import("cmd_config.zig");
const cmd_auth = @import("cmd_auth.zig");
const cmd_jira = @import("cmd_jira.zig");
const cmd_platform = @import("cmd_platform.zig");
const cmd_confluence = @import("cmd_confluence.zig");
const cmd_api = @import("cmd_api.zig");

pub const VERSION = "0.2.1";

const help_text =
    "atlassian — Investtal Atlassian CLI v" ++ VERSION ++ "\n\n" ++
    \\Usage:
    \\  atlassian [global flags] <product> <resource> <verb> [args]
    \\
    \\Global flags:
    \\  --toon                 Success body as TOON (default; human + AI friendly)
    \\  --markdown, --md       Success body as Markdown (human-readable cards/tables)
    \\  --json                 Success body as raw JSON (scripts)
    \\  --format toon|markdown|json   Same as above (last flag wins)
    \\  --config PATH          Config file override
    \\  -v, --verbose          Log HTTP attempts
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
    \\  atlassian --markdown jira issue get PROJ-1
    \\  atlassian --json jira issue get PROJ-1
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

    var global = flags.parse(allocator, args) catch |err| {
        const msg = switch (err) {
            error.MissingFormat, error.InvalidFormat => "invalid --format; use toon|markdown|json",
            error.MissingConfigPath => "missing --config path",
            else => "invalid global flags",
        };
        return usageOut(allocator, io, .toon, msg);
    };
    defer global.deinit(allocator);

    var stdout_buf: [4096]u8 = undefined;
    var stderr_buf: [4096]u8 = undefined;
    var stdout_fw: Io.File.Writer = .init(.stdout(), io, &stdout_buf);
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const ctx = render.Context{
        .format = global.format,
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

    if (std.mem.eql(u8, product, "config")) return cmd_config.run(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "auth")) return cmd_auth.run(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "jira")) return cmd_jira.run(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "platform")) return cmd_platform.run(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "confluence")) return cmd_confluence.run(ctx, allocator, io, global);
    if (std.mem.eql(u8, product, "api")) return cmd_api.run(ctx, allocator, io, global);

    return render.fail(ctx, exit_codes.usage, "unknown product; run atlassian --help");
}

fn usageOut(allocator: std.mem.Allocator, io: Io, format: @import("output_format.zig").OutputFormat, msg: []const u8) u8 {
    var stderr_buf: [1024]u8 = undefined;
    var stderr_fw: Io.File.Writer = .init(.stderr(), io, &stderr_buf);
    const ctx = render.Context{ .format = format, .out = &stderr_fw.interface, .err = &stderr_fw.interface, .allocator = allocator };
    return render.fail(ctx, exit_codes.usage, msg);
}
