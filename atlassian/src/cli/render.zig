//! Human and JSON output helpers for the atlassian CLI.

const std = @import("std");
const Io = std.Io;
const exit_codes = @import("exit_codes.zig");

pub const Context = struct {
    json: bool,
    out: *Io.Writer,
    err: *Io.Writer,
};

/// Write plain success text to stdout (human mode). Adds a trailing newline if missing.
pub fn successText(ctx: Context, text: []const u8) void {
    ctx.out.writeAll(text) catch {};
    if (text.len == 0 or text[text.len - 1] != '\n') {
        ctx.out.writeAll("\n") catch {};
    }
}

/// Write raw JSON success bytes to stdout. Adds a trailing newline if missing.
pub fn successJson(ctx: Context, bytes: []const u8) void {
    ctx.out.writeAll(bytes) catch {};
    if (bytes.len == 0 or bytes[bytes.len - 1] != '\n') {
        ctx.out.writeAll("\n") catch {};
    }
}

/// Print a failure. Always on stderr. JSON shape is minimal until ApiError exists.
pub fn fail(ctx: Context, code: u8, message: []const u8) void {
    if (ctx.json) {
        writeJsonFail(ctx.err, message) catch {};
    } else {
        ctx.err.print("error: {s}\n", .{message}) catch {};
    }
    _ = code;
}

fn writeJsonFail(w: *Io.Writer, message: []const u8) Io.Writer.Error!void {
    // Minimal envelope until http/error.zig (Task 3) shares ApiError.
    try w.writeAll(
        \\{"ok":false,"error":{"kind":"config","status":null,"code":null,"message":"
    );
    try writeJsonEscaped(w, message);
    try w.writeAll(
        \\","details":null,"request_id":null,"retriable":false}}
    );
    try w.writeAll("\n");
}

fn writeJsonEscaped(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    var hex: [6]u8 = undefined;
                    const slice = std.fmt.bufPrint(&hex, "\\u{x:0>4}", .{@as(u16, c)}) catch unreachable;
                    try w.writeAll(slice);
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

test "fail human writes to err" {
    var out_aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_aw.deinit();
    var err_aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_aw.deinit();

    const ctx = Context{
        .json = false,
        .out = &out_aw.writer,
        .err = &err_aw.writer,
    };
    fail(ctx, exit_codes.not_implemented, "not implemented yet");
    try std.testing.expectEqualStrings("error: not implemented yet\n", err_aw.written());
    try std.testing.expectEqual(@as(usize, 0), out_aw.written().len);
}

test "fail json writes envelope to err" {
    var out_aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer out_aw.deinit();
    var err_aw: Io.Writer.Allocating = .init(std.testing.allocator);
    defer err_aw.deinit();

    const ctx = Context{
        .json = true,
        .out = &out_aw.writer,
        .err = &err_aw.writer,
    };
    fail(ctx, exit_codes.usage, "bad args");
    const got = err_aw.written();
    try std.testing.expect(std.mem.indexOf(u8, got, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "bad args") != null);
    try std.testing.expect(std.mem.indexOf(u8, got, "\"kind\":\"config\"") != null);
}
