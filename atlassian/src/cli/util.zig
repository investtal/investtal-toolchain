const std = @import("std");
const Io = std.Io;

const exit_codes = @import("exit_codes.zig");
const render = @import("render.zig");
const http_client = @import("../http/client.zig");

pub fn notImpl(ctx: render.Context, what: []const u8) u8 {
    const msg = std.fmt.allocPrint(ctx.allocator, "not implemented: {s}", .{what}) catch "not implemented";
    defer if (msg.ptr != "not implemented".ptr) ctx.allocator.free(msg);
    return render.fail(ctx, exit_codes.not_implemented, msg);
}

pub fn handleResult(ctx: render.Context, allocator: std.mem.Allocator, result: *http_client.Result) u8 {
    defer result.deinit(allocator);
    return switch (result.*) {
        .ok => |r| {
            render.successBody(ctx, r.body, r.body);
            return exit_codes.ok;
        },
        .err => |e| render.failApi(ctx, e),
    };
}

pub fn readBodyArg(allocator: std.mem.Allocator, io: Io, rest: []const []const u8) !?[]u8 {
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

pub fn flagValue(rest: []const []const u8, name: []const u8) ?[]const u8 {
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

