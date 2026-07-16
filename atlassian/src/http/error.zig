const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Kind = enum {
    http,
    network,
    auth,
    decode,
    config,
    not_implemented,
};

pub const ApiError = struct {
    kind: Kind,
    status: ?u16 = null,
    code: ?[]const u8 = null,
    message: []const u8,
    details: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    retriable: bool = false,
    /// Whether message/code/details were allocated by us.
    owns_message: bool = false,

    /// Map to CLI exit codes (kept here as pure numbers so http does not import cli).
    pub fn exitCode(self: ApiError) u8 {
        return switch (self.kind) {
            .not_implemented => 6,
            .auth => 3,
            .config => 2,
            .network => 7,
            .http => blk: {
                if (self.status) |s| {
                    if (s == 401 or s == 403) break :blk 3;
                    if (s == 404) break :blk 4;
                    if (s == 429) break :blk 5;
                }
                break :blk 1;
            },
            .decode => 1,
        };
    }

    pub fn network(allocator: Allocator, message: []const u8) !ApiError {
        return .{
            .kind = .network,
            .message = try allocator.dupe(u8, message),
            .retriable = true,
            .owns_message = true,
        };
    }

    pub fn deinit(self: *ApiError, allocator: Allocator) void {
        if (self.owns_message) {
            allocator.free(self.message);
            if (self.code) |c| allocator.free(c);
            if (self.details) |d| allocator.free(d);
            if (self.request_id) |r| allocator.free(r);
        }
        self.* = undefined;
    }

    pub fn fromHttp(allocator: Allocator, status: u16, body: []const u8, request_id: ?[]const u8) !ApiError {
        var message: []const u8 = "HTTP error";
        var code: ?[]const u8 = null;
        var owns = false;

        if (body.len > 0) {
            if (std.mem.indexOf(u8, body, "\"errorMessages\"")) |_| {
                // Prefer first errorMessages entry if present.
                if (extractJsonStringArrayFirst(body, "errorMessages")) |msg| {
                    message = try allocator.dupe(u8, msg);
                    owns = true;
                } else {
                    message = try allocator.dupe(u8, body);
                    owns = true;
                }
            } else if (extractJsonString(body, "message")) |msg| {
                message = try allocator.dupe(u8, msg);
                owns = true;
            } else {
                message = try allocator.dupe(u8, body);
                owns = true;
            }
            if (extractJsonString(body, "errorCode")) |c| {
                code = try allocator.dupe(u8, c);
                owns = true;
            }
        }

        const rid = if (request_id) |r| try allocator.dupe(u8, r) else null;
        if (rid != null) owns = true;

        return .{
            .kind = if (status == 401 or status == 403) .auth else .http,
            .status = status,
            .code = code,
            .message = message,
            .request_id = rid,
            .retriable = status == 429 or status == 502 or status == 503 or status == 504,
            .owns_message = owns,
        };
    }

    pub fn toJson(self: ApiError, allocator: Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            \\{{"ok":false,"error":{{"kind":"{s}","status":{s},"code":{s},"message":{s},"details":{s},"request_id":{s},"retriable":{s}}}}}
        , .{
            @tagName(self.kind),
            if (self.status) |s| try std.fmt.allocPrint(allocator, "{d}", .{s}) else "null",
            try jsonOptString(allocator, self.code),
            try jsonString(allocator, self.message),
            try jsonOptString(allocator, self.details),
            try jsonOptString(allocator, self.request_id),
            if (self.retriable) "true" else "false",
        });
    }
};

fn jsonString(allocator: Allocator, s: []const u8) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    try list.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
    try list.append(allocator, '"');
    return try list.toOwnedSlice(allocator);
}

fn jsonOptString(allocator: Allocator, s: ?[]const u8) ![]const u8 {
    if (s) |v| return jsonString(allocator, v);
    return "null";
}

/// Naive extractors — good enough for Atlassian error bodies in unit tests.
fn extractJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = idx + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == ':' or body[i] == '\t')) : (i += 1) {}
    if (i >= body.len or body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {
        if (body[i] == '\\' and i + 1 < body.len) i += 1;
    }
    if (i >= body.len) return null;
    return body[start..i];
}

fn extractJsonStringArrayFirst(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    const after = body[idx + needle.len ..];
    const q = std.mem.indexOfScalar(u8, after, '"') orelse return null;
    const start = q + 1;
    const end_rel = std.mem.indexOfScalar(u8, after[start..], '"') orelse return null;
    return after[start .. start + end_rel];
}

test "exitCode maps 404 to not_found" {
    const e = ApiError{ .kind = .http, .status = 404, .message = "x" };
    try std.testing.expectEqual(@as(u8, 4), e.exitCode());
}

test "parse jira errorMessages" {
    const body = "{\"errorMessages\":[\"Issue does not exist\"],\"errors\":{}}";
    var e = try ApiError.fromHttp(std.testing.allocator, 404, body, null);
    defer e.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, e.message, "Issue does not exist") != null);
}
