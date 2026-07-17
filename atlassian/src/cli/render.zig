const std = @import("std");
const Io = std.Io;
const ApiError = @import("../http/error.zig").ApiError;
const OutputFormat = @import("output_format.zig").OutputFormat;
const toon = @import("toon.zig");
const markdown = @import("markdown.zig");

pub const Context = struct {
    format: OutputFormat = .toon,
    out: *Io.Writer,
    err: *Io.Writer,
    allocator: std.mem.Allocator,

    pub fn isJson(self: Context) bool {
        return self.format.isJson();
    }
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

/// Render a successful API body according to `ctx.format`.
///
/// For Jira **issue** / **search** payloads, all three modes use the same **main-field**
/// curation (preferred system + valued custom fields; noise dropped):
/// - **toon** (default): curated JSON → TOON
/// - **markdown**: curated fields as aligned Markdown tables/sections
/// - **json**: curated compact JSON
///
/// Other resources still pass through the full body (TOON-encoded when not json).
/// Use `atlassian api request …` for full raw issue JSON when needed.
pub fn successBody(ctx: Context, body: []const u8) void {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (trimmed.len == 0) {
        if (ctx.format == .json) {
            ctx.out.writeAll("\n") catch {};
            ctx.out.flush() catch {};
            return;
        }
        successText(ctx, "ok");
        return;
    }

    // Curate Jira issue/search-shaped payloads into main fields for all formats.
    const curated = markdown.curateAlloc(ctx.allocator, body) catch null;
    defer if (curated) |c| ctx.allocator.free(c);
    const payload = curated orelse body;

    switch (ctx.format) {
        .json => successJson(ctx, payload),
        .toon => {
            const encoded = toon.encodeAlloc(ctx.allocator, payload) catch {
                successText(ctx, payload);
                return;
            };
            defer ctx.allocator.free(encoded);
            successText(ctx, encoded);
        },
        .markdown => {
            // Markdown always goes through its own renderer (aligned tables + labels).
            const encoded = markdown.encodeAlloc(ctx.allocator, body) catch {
                successText(ctx, body);
                return;
            };
            defer ctx.allocator.free(encoded);
            successText(ctx, encoded);
        },
    }
}

pub fn fail(ctx: Context, code: u8, message: []const u8) u8 {
    if (ctx.isJson()) {
        const payload = std.json.Stringify.valueAlloc(ctx.allocator, .{
            .ok = false,
            .@"error" = .{
                .kind = "config",
                .status = null,
                .code = null,
                .message = message,
                .details = null,
                .request_id = null,
                .retriable = false,
            },
        }, .{}) catch {
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
    if (ctx.isJson()) {
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

test "fail json escapes control chars in message" {
    const a = std.testing.allocator;
    const s = try std.json.Stringify.valueAlloc(a, .{ .message = "a\nb\"c" }, .{});
    defer a.free(s);
    try std.testing.expect(std.mem.indexOf(u8, s, "\\n") != null);
}
