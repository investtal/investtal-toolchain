//! JSON → TOON encoder (encode-only).
//! Subset of TOON SPEC v3.3 used for CLI success bodies:
//! objects, nested objects, primitive arrays, tabular arrays, expanded lists.
//! Defaults: indentSize=2, delimiter=comma, keyFolding=off.
//! Spec: https://github.com/toon-format/spec

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;

const indent_size: usize = 2;
const delim: u8 = ',';
const EncodeError = Allocator.Error;

pub fn encodeAlloc(allocator: Allocator, json_bytes: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, json_bytes, " \t\r\n");
    if (trimmed.len == 0) return try allocator.dupe(u8, "");

    var parsed = try std.json.parseFromSlice(Value, allocator, trimmed, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try encodeRoot(allocator, &list, parsed.value);
    // Spec §12: no trailing newline at end of document.
    while (list.items.len > 0 and list.items[list.items.len - 1] == '\n') {
        _ = list.pop();
    }
    return try list.toOwnedSlice(allocator);
}

fn encodeRoot(allocator: Allocator, out: *std.ArrayList(u8), value: Value) EncodeError!void {
    switch (value) {
        .object => |obj| try encodeObject(allocator, out, obj, 0),
        .array => |arr| try encodeArray(allocator, out, arr.items, 0, null),
        else => try writePrimitive(allocator, out, value, delim),
    }
}

fn encodeObject(allocator: Allocator, out: *std.ArrayList(u8), obj: std.json.ObjectMap, depth: usize) EncodeError!void {
    var it = obj.iterator();
    while (it.next()) |entry| {
        try encodeField(allocator, out, entry.key_ptr.*, entry.value_ptr.*, depth);
    }
}

fn encodeField(allocator: Allocator, out: *std.ArrayList(u8), key: []const u8, value: Value, depth: usize) EncodeError!void {
    switch (value) {
        .object => |nested| {
            try writeIndent(allocator, out, depth);
            try writeKey(allocator, out, key);
            try out.appendSlice(allocator, ":\n");
            try encodeObject(allocator, out, nested, depth + 1);
        },
        .array => |arr| {
            try encodeArray(allocator, out, arr.items, depth, key);
        },
        else => {
            try writeIndent(allocator, out, depth);
            try writeKey(allocator, out, key);
            try out.appendSlice(allocator, ": ");
            try writePrimitive(allocator, out, value, delim);
            try out.append(allocator, '\n');
        },
    }
}

fn encodeArray(allocator: Allocator, out: *std.ArrayList(u8), items: []const Value, depth: usize, key: ?[]const u8) EncodeError!void {
    if (items.len == 0) {
        try writeIndent(allocator, out, depth);
        if (key) |k| {
            try writeKey(allocator, out, k);
            try out.appendSlice(allocator, ": []\n");
        } else {
            try out.appendSlice(allocator, "[]");
        }
        return;
    }

    if (allPrimitives(items)) {
        try writeIndent(allocator, out, depth);
        if (key) |k| try writeKey(allocator, out, k);
        try out.print(allocator, "[{d}]: ", .{items.len});
        for (items, 0..) |item, i| {
            if (i > 0) try out.append(allocator, delim);
            try writePrimitive(allocator, out, item, delim);
        }
        try out.append(allocator, '\n');
        return;
    }

    if (try tabularFields(allocator, items)) |fields| {
        defer allocator.free(fields);
        try writeIndent(allocator, out, depth);
        if (key) |k| try writeKey(allocator, out, k);
        try out.print(allocator, "[{d}]{{", .{items.len});
        for (fields, 0..) |f, i| {
            if (i > 0) try out.append(allocator, delim);
            try writeKey(allocator, out, f);
        }
        try out.appendSlice(allocator, "}:\n");
        for (items) |item| {
            try writeIndent(allocator, out, depth + 1);
            const obj = item.object;
            for (fields, 0..) |f, i| {
                if (i > 0) try out.append(allocator, delim);
                try writePrimitive(allocator, out, obj.get(f) orelse Value.null, delim);
            }
            try out.append(allocator, '\n');
        }
        return;
    }

    try writeIndent(allocator, out, depth);
    if (key) |k| try writeKey(allocator, out, k);
    try out.print(allocator, "[{d}]:\n", .{items.len});
    for (items) |item| {
        try encodeListItem(allocator, out, item, depth + 1);
    }
}

fn encodeListItem(allocator: Allocator, out: *std.ArrayList(u8), item: Value, depth: usize) EncodeError!void {
    switch (item) {
        .object => |obj| {
            if (obj.count() == 0) {
                try writeIndent(allocator, out, depth);
                try out.appendSlice(allocator, "-\n");
                return;
            }

            var it = obj.iterator();
            const first = it.next().?;
            const fk = first.key_ptr.*;
            const fv = first.value_ptr.*;

            // Tabular array as first field (§10)
            if (fv == .array) {
                if (try tabularFields(allocator, fv.array.items)) |fields| {
                    defer allocator.free(fields);
                    try writeIndent(allocator, out, depth);
                    try out.appendSlice(allocator, "- ");
                    try writeKey(allocator, out, fk);
                    try out.print(allocator, "[{d}]{{", .{fv.array.items.len});
                    for (fields, 0..) |f, i| {
                        if (i > 0) try out.append(allocator, delim);
                        try writeKey(allocator, out, f);
                    }
                    try out.appendSlice(allocator, "}:\n");
                    for (fv.array.items) |row| {
                        try writeIndent(allocator, out, depth + 2);
                        for (fields, 0..) |f, i| {
                            if (i > 0) try out.append(allocator, delim);
                            try writePrimitive(allocator, out, row.object.get(f) orelse Value.null, delim);
                        }
                        try out.append(allocator, '\n');
                    }
                    while (it.next()) |entry| {
                        try encodeField(allocator, out, entry.key_ptr.*, entry.value_ptr.*, depth + 1);
                    }
                    return;
                }
            }

            try writeIndent(allocator, out, depth);
            try out.appendSlice(allocator, "- ");
            switch (fv) {
                .object => |nested| {
                    try writeKey(allocator, out, fk);
                    try out.appendSlice(allocator, ":\n");
                    try encodeObject(allocator, out, nested, depth + 2);
                },
                .array => |arr| {
                    if (arr.items.len == 0) {
                        try writeKey(allocator, out, fk);
                        try out.appendSlice(allocator, ": []\n");
                    } else if (allPrimitives(arr.items)) {
                        try writeKey(allocator, out, fk);
                        try out.print(allocator, "[{d}]: ", .{arr.items.len});
                        for (arr.items, 0..) |el, i| {
                            if (i > 0) try out.append(allocator, delim);
                            try writePrimitive(allocator, out, el, delim);
                        }
                        try out.append(allocator, '\n');
                    } else {
                        try writeKey(allocator, out, fk);
                        try out.print(allocator, "[{d}]:\n", .{arr.items.len});
                        for (arr.items) |el| {
                            try encodeListItem(allocator, out, el, depth + 2);
                        }
                    }
                },
                else => {
                    try writeKey(allocator, out, fk);
                    try out.appendSlice(allocator, ": ");
                    try writePrimitive(allocator, out, fv, delim);
                    try out.append(allocator, '\n');
                },
            }
            while (it.next()) |entry| {
                try encodeField(allocator, out, entry.key_ptr.*, entry.value_ptr.*, depth + 1);
            }
        },
        .array => |arr| {
            try writeIndent(allocator, out, depth);
            if (allPrimitives(arr.items) or arr.items.len == 0) {
                try out.print(allocator, "- [{d}]: ", .{arr.items.len});
                for (arr.items, 0..) |el, i| {
                    if (i > 0) try out.append(allocator, delim);
                    try writePrimitive(allocator, out, el, delim);
                }
                try out.append(allocator, '\n');
            } else {
                try out.print(allocator, "- [{d}]:\n", .{arr.items.len});
                for (arr.items) |el| {
                    try encodeListItem(allocator, out, el, depth + 1);
                }
            }
        },
        else => {
            try writeIndent(allocator, out, depth);
            try out.appendSlice(allocator, "- ");
            try writePrimitive(allocator, out, item, delim);
            try out.append(allocator, '\n');
        },
    }
}

fn allPrimitives(items: []const Value) bool {
    for (items) |item| {
        if (!isPrimitive(item)) return false;
    }
    return true;
}

fn isPrimitive(v: Value) bool {
    return switch (v) {
        .null, .bool, .integer, .float, .number_string, .string => true,
        else => false,
    };
}

/// Owned slice of field names when tabular-eligible; null otherwise.
fn tabularFields(allocator: Allocator, items: []const Value) EncodeError!?[]const []const u8 {
    if (items.len == 0) return null;
    for (items) |item| {
        if (item != .object) return null;
        if (item.object.count() == 0) return null;
    }

    const first = items[0].object;
    var fields: std.ArrayList([]const u8) = .empty;
    errdefer fields.deinit(allocator);

    var it = first.iterator();
    while (it.next()) |entry| {
        try fields.append(allocator, entry.key_ptr.*);
    }

    for (items) |item| {
        const obj = item.object;
        if (obj.count() != fields.items.len) {
            fields.deinit(allocator);
            return null;
        }
        for (fields.items) |f| {
            const v = obj.get(f) orelse {
                fields.deinit(allocator);
                return null;
            };
            if (!isPrimitive(v)) {
                fields.deinit(allocator);
                return null;
            }
        }
        var oit = obj.iterator();
        while (oit.next()) |e| {
            var found = false;
            for (fields.items) |f| {
                if (std.mem.eql(u8, f, e.key_ptr.*)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                fields.deinit(allocator);
                return null;
            }
        }
    }
    return try fields.toOwnedSlice(allocator);
}

fn writeIndent(allocator: Allocator, out: *std.ArrayList(u8), depth: usize) EncodeError!void {
    const n = depth * indent_size;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        try out.append(allocator, ' ');
    }
}

fn writeKey(allocator: Allocator, out: *std.ArrayList(u8), key: []const u8) EncodeError!void {
    if (isUnquotedKey(key)) {
        try out.appendSlice(allocator, key);
    } else {
        try writeQuotedString(allocator, out, key);
    }
}

fn isUnquotedKey(key: []const u8) bool {
    if (key.len == 0) return false;
    const c0 = key[0];
    if (!((c0 >= 'A' and c0 <= 'Z') or (c0 >= 'a' and c0 <= 'z') or c0 == '_')) return false;
    for (key[1..]) |c| {
        const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

fn writePrimitive(allocator: Allocator, out: *std.ArrayList(u8), value: Value, active_delim: u8) EncodeError!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "null"),
        .bool => |b| try out.appendSlice(allocator, if (b) "true" else "false"),
        .integer => |n| try out.print(allocator, "{d}", .{n}),
        .float => |f| try writeFloat(allocator, out, f),
        .number_string => |s| try out.appendSlice(allocator, s),
        .string => |s| {
            if (needsQuote(s, active_delim)) {
                try writeQuotedString(allocator, out, s);
            } else {
                try out.appendSlice(allocator, s);
            }
        },
        else => try out.appendSlice(allocator, "null"),
    }
}

fn writeFloat(allocator: Allocator, out: *std.ArrayList(u8), f: f64) EncodeError!void {
    if (!std.math.isFinite(f)) {
        try out.appendSlice(allocator, "null");
        return;
    }
    if (f == 0) {
        try out.append(allocator, '0');
        return;
    }
    // Prefer integer form when exact
    if (f == @trunc(f) and f >= @as(f64, @floatFromInt(std.math.minInt(i64))) and f <= @as(f64, @floatFromInt(std.math.maxInt(i64)))) {
        try out.print(allocator, "{d}", .{@as(i64, @intFromFloat(f))});
        return;
    }
    try out.print(allocator, "{d}", .{f});
}

fn needsQuote(s: []const u8, active_delim: u8) bool {
    if (s.len == 0) return true;
    if (s[0] == ' ' or s[s.len - 1] == ' ' or s[0] == '\t' or s[s.len - 1] == '\t') return true;
    if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false") or std.mem.eql(u8, s, "null")) return true;
    if (s[0] == '-') return true;
    if (isNumericLike(s)) return true;
    for (s) |c| {
        if (c == ':' or c == '"' or c == '\\') return true;
        if (c == '[' or c == ']' or c == '{' or c == '}') return true;
        if (c == active_delim) return true;
        if (c < 0x20) return true;
    }
    return false;
}

fn isNumericLike(s: []const u8) bool {
    // /^-?\d+(?:\.\d+)?(?:e[+-]?\d+)?$/i
    if (s.len == 0) return false;
    var i: usize = 0;
    if (s[0] == '-') {
        if (s.len == 1) return false;
        i = 1;
    }
    if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return false;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }
    return i == s.len;
}

fn writeQuotedString(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) EncodeError!void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '"' => try out.appendSlice(allocator, "\\\""),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.print(allocator, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(allocator, c);
                }
            },
        }
    }
    try out.append(allocator, '"');
}

test "toon encodes simple object" {
    const a = std.testing.allocator;
    const out = try encodeAlloc(a, "{\"id\":1,\"name\":\"Ada\",\"active\":true}");
    defer a.free(out);
    try std.testing.expectEqualStrings("id: 1\nname: Ada\nactive: true", out);
}

test "toon encodes tabular array" {
    const a = std.testing.allocator;
    const out = try encodeAlloc(a,
        \\{"users":[{"id":1,"name":"Alice","role":"admin"},{"id":2,"name":"Bob","role":"user"}]}
    );
    defer a.free(out);
    try std.testing.expectEqualStrings(
        \\users[2]{id,name,role}:
        \\  1,Alice,admin
        \\  2,Bob,user
    , out);
}

test "toon encodes primitive array" {
    const a = std.testing.allocator;
    const out = try encodeAlloc(a, "{\"tags\":[\"admin\",\"ops\",\"dev\"]}");
    defer a.free(out);
    try std.testing.expectEqualStrings("tags[3]: admin,ops,dev", out);
}

test "toon quotes special strings" {
    const a = std.testing.allocator;
    const out = try encodeAlloc(a, "{\"status\":\"true\",\"url\":\"http://a:b\"}");
    defer a.free(out);
    try std.testing.expectEqualStrings("status: \"true\"\nurl: \"http://a:b\"", out);
}

test "toon empty array field" {
    const a = std.testing.allocator;
    const out = try encodeAlloc(a, "{\"tags\":[]}");
    defer a.free(out);
    try std.testing.expectEqualStrings("tags: []", out);
}
