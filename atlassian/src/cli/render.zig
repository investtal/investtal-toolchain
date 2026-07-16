const std = @import("std");
const Io = std.Io;
const ApiError = @import("../http/error.zig").ApiError;

pub const Context = struct {
    json: bool,
    out: *Io.Writer,
    err: *Io.Writer,
    allocator: std.mem.Allocator,
};

pub fn successText(ctx: Context, text: []const u8) void {
    ctx.out.print("{s}\n", .{text}) catch {};
    ctx.out.flush() catch {};
}

pub fn successJson(ctx: Context, bytes: []const u8) void {
    ctx.out.writeAll(bytes) catch {};
    ctx.out.writeAll("\n") catch {};
    ctx.out.flush() catch {};
}

pub fn successBody(ctx: Context, body: []const u8, human_fallback: []const u8) void {
    if (ctx.json) {
        successJson(ctx, body);
    } else if (human_fallback.len > 0) {
        successText(ctx, human_fallback);
    } else {
        successText(ctx, body);
    }
}

pub fn fail(ctx: Context, code: u8, message: []const u8) u8 {
    if (ctx.json) {
        const payload = std.fmt.allocPrint(ctx.allocator, "{{\"ok\":false,\"error\":{{\"kind\":\"config\",\"status\":null,\"code\":null,\"message\":{s},\"details\":null,\"request_id\":null,\"retriable\":false}}}}", .{jsonQuote(ctx.allocator, message) catch "\"error\""}) catch {
            ctx.err.print("Error: {s}\n", .{message}) catch {};
            return code;
        };
        defer ctx.allocator.free(payload);
        ctx.err.writeAll(payload) catch {};
        ctx.err.writeAll("\n") catch {};
    } else {
        ctx.err.print("Error: {s}\n", .{message}) catch {};
    }
    ctx.err.flush() catch {};
    return code;
}

pub fn failApi(ctx: Context, err: ApiError) u8 {
    if (ctx.json) {
        const payload = err.toJson(ctx.allocator) catch {
            return fail(ctx, err.exitCode(), err.message);
        };
        defer ctx.allocator.free(payload);
        ctx.err.writeAll(payload) catch {};
        ctx.err.writeAll("\n") catch {};
        ctx.err.flush() catch {};
        return err.exitCode();
    }
    ctx.err.print("Error: {s}", .{err.message}) catch {};
    if (err.status) |s| ctx.err.print(" ({d})", .{s}) catch {};
    ctx.err.writeAll("\n") catch {};
    if (err.code) |c| ctx.err.print("  code: {s}\n", .{c}) catch {};
    if (err.request_id) |r| ctx.err.print("  request_id: {s}\n", .{r}) catch {};
    ctx.err.flush() catch {};
    return err.exitCode();
}

fn jsonQuote(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
    return try list.toOwnedSlice(allocator);
}
