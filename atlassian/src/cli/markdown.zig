//! Human-readable Markdown rendering for Atlassian API JSON bodies.
//!
//! Jira issue views are **dynamic + curated**:
//! - Main fields only (preferred system fields + valued custom fields; noise dropped).
//! - Labels from `names`; values from `schema` types (`expand=names,schema`).
//! - Markdown tables are column-aligned for monospace terminals.
//! - `curateAlloc` builds the same main-field JSON used by TOON/JSON modes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = std.json.Value;
const EncodeError = Allocator.Error;

/// Soft cap for table cell text (longer content becomes a ## section).
const table_cell_max: usize = 120;
/// Soft cap for long-text sections.
const section_text_max: usize = 4000;

pub fn encodeAlloc(allocator: Allocator, json_bytes: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, json_bytes, " \t\r\n");
    if (trimmed.len == 0) return try allocator.dupe(u8, "_empty response_");

    var parsed = try std.json.parseFromSlice(Value, allocator, trimmed, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);

    if (try tryRenderJiraIssue(allocator, &list, parsed.value)) {
        return try list.toOwnedSlice(allocator);
    }
    if (try tryRenderJiraSearch(allocator, &list, parsed.value)) {
        return try list.toOwnedSlice(allocator);
    }

    try renderGeneric(allocator, &list, parsed.value, 0);
    while (list.items.len > 0 and list.items[list.items.len - 1] == '\n') {
        _ = list.pop();
    }
    return try list.toOwnedSlice(allocator);
}

/// If body is a Jira issue or search result, return owned compact JSON of **main**
/// fields (same set as Markdown). Otherwise return null (caller keeps full body).
pub fn curateAlloc(allocator: Allocator, json_bytes: []const u8) !?[]u8 {
    const trimmed = std.mem.trim(u8, json_bytes, " \t\r\n");
    if (trimmed.len == 0) return null;

    var parsed = try std.json.parseFromSlice(Value, allocator, trimmed, .{ .allocate = .alloc_always });
    defer parsed.deinit();

    if (try curateIssueJson(allocator, parsed.value)) |j| return j;
    if (try curateSearchJson(allocator, parsed.value)) |j| return j;
    return null;
}

// ─── Schema ──────────────────────────────────────────────────────────────────

/// Slice of a Jira `schema` entry (borrowed from parsed JSON).
const FieldSchema = struct {
    type: []const u8,
    items: ?[]const u8 = null,
    system: ?[]const u8 = null,
    custom: ?[]const u8 = null,

    fn fromValue(v: Value) ?FieldSchema {
        if (v != .object) return null;
        const ty = objString(v.object, "type") orelse return null;
        return .{
            .type = ty,
            .items = objString(v.object, "items"),
            .system = objString(v.object, "system"),
            .custom = objString(v.object, "custom"),
        };
    }

    fn lookup(schemas: ?std.json.ObjectMap, field_id: []const u8) ?FieldSchema {
        const map = schemas orelse return null;
        const v = map.get(field_id) orelse return null;
        return fromValue(v);
    }

    /// Last segment of custom key: `com.pyxis…:gh-sprint` → `gh-sprint`.
    fn customTail(self: FieldSchema) ?[]const u8 {
        const c = self.custom orelse return null;
        if (std.mem.lastIndexOfScalar(u8, c, ':')) |i| return c[i + 1 ..];
        return c;
    }

    fn isLong(self: FieldSchema) bool {
        if (std.mem.eql(u8, self.type, "comments-page")) return true;
        if (std.mem.eql(u8, self.type, "array")) {
            if (self.items) |it| {
                if (std.mem.eql(u8, it, "worklog") or std.mem.eql(u8, it, "attachment")) return true;
            }
        }
        if (self.system) |sys| {
            if (std.mem.eql(u8, sys, "description") or
                std.mem.eql(u8, sys, "environment") or
                std.mem.eql(u8, sys, "comment") or
                std.mem.eql(u8, sys, "worklog"))
                return true;
        }
        return false;
    }
};

// ─── Jira issue (curated main fields + schema) ───────────────────────────────

const FieldRow = struct {
    label: []u8,
    value: []u8,
    field_id: []const u8,

    fn deinit(self: *FieldRow, allocator: Allocator) void {
        allocator.free(self.label);
        allocator.free(self.value);
        self.* = undefined;
    }
};

const IssueView = struct {
    key: []const u8,
    summary: []const u8,
    rows: std.ArrayList(FieldRow),
    sections: std.ArrayList(FieldRow),

    fn deinit(self: *IssueView, allocator: Allocator) void {
        for (self.rows.items) |*r| r.deinit(allocator);
        self.rows.deinit(allocator);
        for (self.sections.items) |*r| r.deinit(allocator);
        self.sections.deinit(allocator);
        self.* = undefined;
    }
};

fn tryCollectIssueView(allocator: Allocator, value: Value) EncodeError!?IssueView {
    if (value != .object) return null;
    const obj = value.object;
    const key = objString(obj, "key") orelse return null;
    const fields_v = obj.get("fields") orelse return null;
    if (fields_v != .object) return null;
    const fields = fields_v.object;

    const names: ?std.json.ObjectMap = if (obj.get("names")) |n|
        if (n == .object) n.object else null
    else
        null;
    const schemas: ?std.json.ObjectMap = if (obj.get("schema")) |s|
        if (s == .object) s.object else null
    else
        null;

    const summary: []const u8 = blk: {
        if (fields.get("summary")) |s| {
            if (s == .string and s.string.len > 0) break :blk s.string;
        }
        break :blk "(no summary)";
    };

    var view = IssueView{
        .key = key,
        .summary = summary,
        .rows = .empty,
        .sections = .empty,
    };
    errdefer view.deinit(allocator);

    var it = fields.iterator();
    while (it.next()) |entry| {
        const field_id = entry.key_ptr.*;
        if (std.mem.eql(u8, field_id, "summary")) continue;

        const schema = FieldSchema.lookup(schemas, field_id);
        if (!isMainField(field_id, schema)) continue;

        const formatted = try formatFieldValue(allocator, entry.value_ptr.*, schema) orelse continue;
        errdefer allocator.free(formatted);

        const label = fieldLabel(names, field_id);
        const row = FieldRow{
            .label = try allocator.dupe(u8, label),
            .value = formatted,
            .field_id = field_id,
        };

        if (isLongTextField(field_id, schema, row.value)) {
            try view.sections.append(allocator, row);
        } else {
            try view.rows.append(allocator, row);
        }
    }

    try sortFieldRows(&view.rows);
    return view;
}

fn tryRenderJiraIssue(allocator: Allocator, out: *std.ArrayList(u8), value: Value) EncodeError!bool {
    var view = try tryCollectIssueView(allocator, value) orelse return false;
    defer view.deinit(allocator);

    try out.print(allocator, "# {s}: {s}\n\n", .{ view.key, view.summary });

    if (view.rows.items.len > 0) {
        try writeAlignedTwoColTable(allocator, out, "Field", "Value", view.rows.items);
    }

    for (view.sections.items) |r| {
        try out.print(allocator, "\n## {s}\n\n", .{r.label});
        try out.appendSlice(allocator, r.value);
        if (r.value.len == 0 or r.value[r.value.len - 1] != '\n') {
            try out.append(allocator, '\n');
        }
    }

    return true;
}

fn curateIssueJson(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    var view = try tryCollectIssueView(allocator, value) orelse return null;
    defer view.deinit(allocator);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"key\": ");
    try appendJsonString(allocator, &out, view.key);
    try out.appendSlice(allocator, ",\n  \"summary\": ");
    try appendJsonString(allocator, &out, view.summary);

    for (view.rows.items) |r| {
        try out.appendSlice(allocator, ",\n  ");
        try appendJsonString(allocator, &out, r.field_id);
        try out.appendSlice(allocator, ": ");
        try appendJsonString(allocator, &out, r.value);
    }
    for (view.sections.items) |r| {
        try out.appendSlice(allocator, ",\n  ");
        try appendJsonString(allocator, &out, r.field_id);
        try out.appendSlice(allocator, ": ");
        try appendJsonString(allocator, &out, r.value);
    }
    try out.appendSlice(allocator, "\n}");
    return try out.toOwnedSlice(allocator);
}

/// Column-aligned two-column markdown table (monospace-friendly).
fn writeAlignedTwoColTable(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    header_a: []const u8,
    header_b: []const u8,
    rows: []const FieldRow,
) EncodeError!void {
    var w0: usize = displayWidth(header_a);
    var w1: usize = displayWidth(header_b);
    for (rows) |r| {
        w0 = @max(w0, displayWidth(r.label));
        w1 = @max(w1, displayWidth(r.value));
    }
    // Cap value column so terminal isn't huge
    if (w1 > 80) w1 = 80;

    try writeMdTableRow(allocator, out, header_a, header_b, w0, w1, false);
    try writeMdTableSep(allocator, out, w0, w1);
    for (rows) |r| {
        try writeMdTableRow(allocator, out, r.label, r.value, w0, w1, true);
    }
}

fn writeMdTableRow(
    allocator: Allocator,
    out: *std.ArrayList(u8),
    a: []const u8,
    b: []const u8,
    w0: usize,
    w1: usize,
    escape_pipes: bool,
) EncodeError!void {
    try out.appendSlice(allocator, "| ");
    try appendPaddedCell(allocator, out, a, w0, escape_pipes);
    try out.appendSlice(allocator, " | ");
    try appendPaddedCell(allocator, out, b, w1, escape_pipes);
    try out.appendSlice(allocator, " |\n");
}

fn writeMdTableSep(allocator: Allocator, out: *std.ArrayList(u8), w0: usize, w1: usize) EncodeError!void {
    try out.appendSlice(allocator, "| ");
    try appendDashes(allocator, out, w0);
    try out.appendSlice(allocator, " | ");
    try appendDashes(allocator, out, w1);
    try out.appendSlice(allocator, " |\n");
}

fn appendDashes(allocator: Allocator, out: *std.ArrayList(u8), n: usize) EncodeError!void {
    var i: usize = 0;
    while (i < n) : (i += 1) try out.append(allocator, '-');
}

fn appendPaddedCell(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8, width: usize, escape_pipes: bool) EncodeError!void {
    // Flatten newlines/pipes for table cells; then pad to width.
    var flat: std.ArrayList(u8) = .empty;
    defer flat.deinit(allocator);
    for (s) |c| {
        if (c == '\n' or c == '\r') {
            try flat.append(allocator, ' ');
        } else if (escape_pipes and c == '|') {
            try flat.append(allocator, ' ');
        } else {
            try flat.append(allocator, c);
        }
    }
    // Truncate display if over width (byte-safe cut at width codepoints approx via bytes)
    var shown = flat.items;
    if (displayWidth(shown) > width) {
        // keep prefix that fits
        var acc: usize = 0;
        var i: usize = 0;
        while (i < shown.len) {
            const clen = std.unicode.utf8ByteSequenceLength(shown[i]) catch 1;
            if (i + clen > shown.len) break;
            if (acc + 1 > width) break;
            acc += 1;
            i += clen;
        }
        shown = shown[0..i];
    }
    try out.appendSlice(allocator, shown);
    const pad = if (displayWidth(shown) < width) width - displayWidth(shown) else 0;
    var p: usize = 0;
    while (p < pad) : (p += 1) try out.append(allocator, ' ');
}

fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn appendJsonString(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) EncodeError!void {
    try out.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
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

/// Main-field gate: preferred system fields + valued custom fields; drop Jira noise.
fn isMainField(field_id: []const u8, schema: ?FieldSchema) bool {
    // Custom fields always eligible (sprint, story points, flags, …)
    if (std.mem.startsWith(u8, field_id, "customfield_")) {
        // Internal rank is not human-main
        if (schema) |s| {
            if (s.customTail()) |tail| {
                if (std.mem.eql(u8, tail, "gh-lexo-rank")) return false;
            }
        }
        return true;
    }

    // Explicit main system fields
    for (preferred_order) |id| {
        if (std.mem.eql(u8, field_id, id)) return true;
    }
    if (std.mem.eql(u8, field_id, "description") or
        std.mem.eql(u8, field_id, "environment") or
        std.mem.eql(u8, field_id, "duedate") or
        std.mem.eql(u8, field_id, "created") or
        std.mem.eql(u8, field_id, "updated") or
        std.mem.eql(u8, field_id, "resolution") or
        std.mem.eql(u8, field_id, "resolutiondate") or
        std.mem.eql(u8, field_id, "parent") or
        std.mem.eql(u8, field_id, "labels") or
        std.mem.eql(u8, field_id, "components") or
        std.mem.eql(u8, field_id, "fixVersions") or
        std.mem.eql(u8, field_id, "versions") or
        std.mem.eql(u8, field_id, "comment") or
        std.mem.eql(u8, field_id, "attachment") or
        std.mem.eql(u8, field_id, "subtasks") or
        std.mem.eql(u8, field_id, "issuelinks"))
        return true;

    // Everything else (votes, watches, lastViewed, progress, statusCategory, …) dropped
    return false;
}

fn fieldLabel(names: ?std.json.ObjectMap, field_id: []const u8) []const u8 {
    if (names) |n| {
        if (n.get(field_id)) |v| {
            if (v == .string and v.string.len > 0) return v.string;
        }
    }
    return field_id;
}

fn isLongTextField(field_id: []const u8, schema: ?FieldSchema, formatted: []const u8) bool {
    if (schema) |s| {
        if (s.isLong()) return true;
    } else {
        if (std.mem.eql(u8, field_id, "description") or
            std.mem.eql(u8, field_id, "environment") or
            std.mem.eql(u8, field_id, "comment") or
            std.mem.eql(u8, field_id, "worklog"))
            return true;
    }
    if (formatted.len > table_cell_max) return true;
    if (std.mem.indexOfScalar(u8, formatted, '\n') != null) return true;
    return false;
}

const preferred_order = [_][]const u8{
    "issuetype",
    "status",
    "priority",
    "assignee",
    "reporter",
    "creator",
    "project",
    "parent",
    "labels",
    "components",
    "fixVersions",
    "versions",
    "duedate",
    "created",
    "updated",
    "resolution",
    "resolutiondate",
};

fn sortFieldRows(rows: *std.ArrayList(FieldRow)) EncodeError!void {
    var i: usize = 0;
    for (preferred_order) |pref| {
        var j = i;
        while (j < rows.items.len) : (j += 1) {
            if (std.mem.eql(u8, rows.items[j].field_id, pref)) {
                if (j != i) {
                    const tmp = rows.items[i];
                    rows.items[i] = rows.items[j];
                    rows.items[j] = tmp;
                }
                i += 1;
                break;
            }
        }
    }
}

// ─── Schema-aware value formatting ───────────────────────────────────────────

const SchemaFormat = struct {
    /// true when this schema type was recognized (null text = intentionally skip).
    handled: bool,
    text: ?[]u8 = null,
};

/// Returns owned display string, or null to skip (null / empty / noise).
fn formatFieldValue(allocator: Allocator, value: Value, schema: ?FieldSchema) EncodeError!?[]u8 {
    if (value == .null) return null;

    if (schema) |s| {
        const r = try formatBySchema(allocator, value, s);
        if (r.handled) return r.text;
        // Unknown schema type → shape heuristics.
    }
    return try formatByShape(allocator, value);
}

fn formatBySchema(allocator: Allocator, value: Value, schema: FieldSchema) EncodeError!SchemaFormat {
    // Custom plugins first (more specific than base type).
    if (schema.customTail()) |tail| {
        const custom = try formatByCustom(allocator, value, tail, schema);
        if (custom.handled) return custom;
    }

    if (std.mem.eql(u8, schema.type, "user")) {
        return .{ .handled = true, .text = try formatUser(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "option")) {
        return .{ .handled = true, .text = try formatOption(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "status") or
        std.mem.eql(u8, schema.type, "issuetype") or
        std.mem.eql(u8, schema.type, "priority") or
        std.mem.eql(u8, schema.type, "resolution") or
        std.mem.eql(u8, schema.type, "securitylevel") or
        std.mem.eql(u8, schema.type, "component") or
        std.mem.eql(u8, schema.type, "version") or
        std.mem.eql(u8, schema.type, "team"))
    {
        return .{ .handled = true, .text = try formatNamed(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "statusCategory")) {
        return .{ .handled = true, .text = try formatStatusCategory(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "project")) {
        return .{ .handled = true, .text = try formatProject(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "string")) {
        return .{ .handled = true, .text = try formatStringish(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "number")) {
        return .{ .handled = true, .text = try formatNumber(allocator, value, schema) };
    }
    if (std.mem.eql(u8, schema.type, "date") or std.mem.eql(u8, schema.type, "datetime")) {
        return .{ .handled = true, .text = try formatStringish(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "array")) {
        return .{ .handled = true, .text = try formatSchemaArray(allocator, value, schema.items) };
    }
    if (std.mem.eql(u8, schema.type, "votes")) {
        return .{ .handled = true, .text = try formatVotes(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "watches")) {
        return .{ .handled = true, .text = try formatWatches(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "progress")) {
        return .{ .handled = true, .text = try formatProgress(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "timetracking")) {
        return .{ .handled = true, .text = try formatTimetracking(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "comments-page")) {
        return .{ .handled = true, .text = try formatCommentsPage(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "issuerestriction")) {
        return .{ .handled = true, .text = try formatIssueRestriction(allocator, value) };
    }
    if (std.mem.eql(u8, schema.type, "any")) {
        return .{ .handled = true, .text = try formatByShape(allocator, value) };
    }

    return .{ .handled = false };
}

fn formatByCustom(allocator: Allocator, value: Value, tail: []const u8, schema: FieldSchema) EncodeError!SchemaFormat {
    // Sprint (GreenHopper): array of { id, name, state, boardId }
    if (std.mem.eql(u8, tail, "gh-sprint")) {
        if (value == .array) {
            return .{ .handled = true, .text = try formatSchemaArray(allocator, value, "json") };
        }
        return .{ .handled = true, .text = try formatNamed(allocator, value) };
    }
    if (std.mem.eql(u8, tail, "multiuserpicker")) {
        return .{ .handled = true, .text = try formatSchemaArray(allocator, value, "user") };
    }
    if (std.mem.eql(u8, tail, "multicheckboxes")) {
        return .{ .handled = true, .text = try formatSchemaArray(allocator, value, "option") };
    }
    if (std.mem.eql(u8, tail, "datepicker")) {
        return .{ .handled = true, .text = try formatStringish(allocator, value) };
    }
    if (std.mem.eql(u8, tail, "jsw-story-points")) {
        return .{ .handled = true, .text = try formatNumber(allocator, value, schema) };
    }
    if (std.mem.eql(u8, tail, "gh-lexo-rank")) {
        return .{ .handled = true, .text = try formatStringish(allocator, value) };
    }
    if (std.mem.eql(u8, tail, "atlassian-team")) {
        return .{ .handled = true, .text = try formatNamed(allocator, value) };
    }
    return .{ .handled = false };
}

fn formatSchemaArray(allocator: Allocator, value: Value, items: ?[]const u8) EncodeError!?[]u8 {
    // Worklog/comment APIs sometimes wrap arrays in page objects despite schema type=array.
    if (value == .object) {
        if (value.object.get("worklogs")) |w| {
            if (w == .array) return try formatSchemaArray(allocator, w, items orelse "worklog");
        }
        if (value.object.get("comments")) |c| {
            if (c == .array) return try formatSchemaArray(allocator, c, items orelse "comment");
        }
        // empty page
        if (value.object.get("total")) |t| {
            if (t == .integer and t.integer == 0) return null;
        }
    }

    if (value != .array) return null;
    const list = value.array.items;
    if (list.len == 0) return null;

    const item_schema: ?FieldSchema = if (items) |it| .{ .type = it } else null;

    var parts: std.ArrayList([]u8) = .empty;
    defer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit(allocator);
    }

    for (list) |item| {
        const piece = blk: {
            if (items) |it| {
                if (std.mem.eql(u8, it, "string")) break :blk try formatStringish(allocator, item);
                if (std.mem.eql(u8, it, "user")) break :blk try formatUser(allocator, item);
                if (std.mem.eql(u8, it, "option")) break :blk try formatOption(allocator, item);
                if (std.mem.eql(u8, it, "version") or std.mem.eql(u8, it, "component")) break :blk try formatNamed(allocator, item);
                if (std.mem.eql(u8, it, "attachment")) break :blk try formatAttachment(allocator, item);
                if (std.mem.eql(u8, it, "issuelinks")) break :blk try formatIssueLink(allocator, item);
                if (std.mem.eql(u8, it, "worklog")) break :blk try formatWorklogEntry(allocator, item);
                if (std.mem.eql(u8, it, "json")) {
                    break :blk (try formatNamed(allocator, item)) orelse (try formatByShape(allocator, item));
                }
                if (std.mem.eql(u8, it, "comment")) break :blk try formatCommentEntry(allocator, item);
            }
            break :blk try formatFieldValue(allocator, item, item_schema);
        };
        if (piece) |p| try parts.append(allocator, p);
    }
    if (parts.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (parts.items, 0..) |p, i| {
        if (i > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, p);
    }
    return try out.toOwnedSlice(allocator);
}

fn formatUser(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return try formatByShape(allocator, value);
    if (objString(value.object, "displayName")) |dn| {
        if (dn.len > 0) return try allocator.dupe(u8, dn);
    }
    if (objString(value.object, "emailAddress")) |em| {
        if (em.len > 0) return try allocator.dupe(u8, em);
    }
    if (objString(value.object, "accountId")) |id| return try allocator.dupe(u8, id);
    return null;
}

fn formatOption(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value == .string) {
        if (value.string.len == 0) return null;
        return try allocator.dupe(u8, value.string);
    }
    if (value != .object) return null;
    if (objString(value.object, "value")) |v| {
        if (v.len > 0) return try allocator.dupe(u8, v);
    }
    return try formatNamed(allocator, value);
}

fn formatNamed(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) {
        if (value == .string and value.string.len > 0) return try allocator.dupe(u8, value.string);
        return null;
    }
    if (objString(value.object, "name")) |name| {
        if (name.len > 0) return try allocator.dupe(u8, name);
    }
    return null;
}

fn formatStatusCategory(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return try formatNamed(allocator, value);
    const name = objString(value.object, "name");
    const key = objString(value.object, "key");
    if (name != null and key != null) {
        return try std.fmt.allocPrint(allocator, "{s} ({s})", .{ name.?, key.? });
    }
    if (name) |n| return try allocator.dupe(u8, n);
    if (key) |k| return try allocator.dupe(u8, k);
    return null;
}

fn formatProject(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    const name = objString(value.object, "name");
    const key = objString(value.object, "key");
    if (key != null and name != null) {
        return try std.fmt.allocPrint(allocator, "{s} — {s}", .{ key.?, name.? });
    }
    if (key) |k| return try allocator.dupe(u8, k);
    if (name) |n| return try allocator.dupe(u8, n);
    return null;
}

fn formatStringish(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    switch (value) {
        .string => |s| {
            if (std.mem.trim(u8, s, " \t\r\n").len == 0) return null;
            return try allocator.dupe(u8, s);
        },
        .object => {
            // Cloud description is often ADF even when schema type is "string".
            return try formatAdfOrNull(allocator, value.object);
        },
        .integer => |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| return try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .number_string => |s| return try allocator.dupe(u8, s),
        .bool => |b| return try allocator.dupe(u8, if (b) "true" else "false"),
        else => return null,
    }
}

fn formatNumber(allocator: Allocator, value: Value, schema: FieldSchema) EncodeError!?[]u8 {
    // workratio uses -1 as “unset”
    if (schema.system) |sys| {
        if (std.mem.eql(u8, sys, "workratio")) {
            if (value == .integer and value.integer < 0) return null;
        }
    }
    switch (value) {
        .integer => |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| return try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .number_string => |s| {
            if (s.len == 0) return null;
            return try allocator.dupe(u8, s);
        },
        .string => |s| {
            if (s.len == 0) return null;
            return try allocator.dupe(u8, s);
        },
        else => return null,
    }
}

fn formatVotes(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    if (value.object.get("votes")) |v| {
        if (v == .integer) return try std.fmt.allocPrint(allocator, "{d}", .{v.integer});
    }
    return null;
}

fn formatWatches(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    if (value.object.get("watchCount")) |v| {
        if (v == .integer) return try std.fmt.allocPrint(allocator, "{d}", .{v.integer});
    }
    return null;
}

fn formatProgress(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    const p = value.object.get("progress") orelse return null;
    const t = value.object.get("total") orelse return null;
    if (p != .integer or t != .integer) return null;
    if (p.integer == 0 and t.integer == 0) return null;
    return try std.fmt.allocPrint(allocator, "{d}/{d}", .{ p.integer, t.integer });
}

fn formatTimetracking(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    if (value.object.count() == 0) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var n: usize = 0;
    const keys = [_][]const u8{ "originalEstimate", "remainingEstimate", "timeSpent" };
    const labels = [_][]const u8{ "original", "remaining", "spent" };
    for (keys, labels) |k, lab| {
        if (objString(value.object, k)) |s| {
            if (s.len == 0) continue;
            if (n > 0) try out.appendSlice(allocator, "; ");
            try out.print(allocator, "{s}={s}", .{ lab, s });
            n += 1;
        }
    }
    if (n == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

fn formatCommentsPage(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    const comments = value.object.get("comments") orelse return null;
    if (comments != .array or comments.array.items.len == 0) return null;
    return try formatSchemaArray(allocator, comments, "comment");
}

fn formatCommentEntry(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    const author = blk: {
        if (value.object.get("author")) |a| {
            break :blk try formatUser(allocator, a);
        }
        break :blk null;
    };
    defer if (author) |a| allocator.free(a);

    const body = blk: {
        if (value.object.get("body")) |b| {
            break :blk try formatFieldValue(allocator, b, .{ .type = "string" });
        }
        break :blk null;
    };
    defer if (body) |b| allocator.free(b);

    if (author == null and body == null) return null;
    if (author != null and body != null) {
        return try std.fmt.allocPrint(allocator, "{s}: {s}", .{ author.?, body.? });
    }
    if (body) |b| return try allocator.dupe(u8, b);
    return try allocator.dupe(u8, author.?);
}

fn formatWorklogEntry(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    const author = blk: {
        if (value.object.get("author")) |a| break :blk try formatUser(allocator, a);
        break :blk null;
    };
    defer if (author) |a| allocator.free(a);
    const spent = objString(value.object, "timeSpent");
    const started = objString(value.object, "started");
    if (author == null and spent == null) return null;
    if (author != null and spent != null and started != null) {
        return try std.fmt.allocPrint(allocator, "{s} {s} @ {s}", .{ author.?, spent.?, started.? });
    }
    if (author != null and spent != null) {
        return try std.fmt.allocPrint(allocator, "{s} {s}", .{ author.?, spent.? });
    }
    if (spent) |s| return try allocator.dupe(u8, s);
    return try allocator.dupe(u8, author.?);
}

fn formatAttachment(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    if (objString(value.object, "filename")) |fnm| {
        if (fnm.len > 0) return try allocator.dupe(u8, fnm);
    }
    return try formatNamed(allocator, value);
}

fn formatIssueLink(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    const type_obj: ?std.json.ObjectMap = if (value.object.get("type")) |t|
        if (t == .object) t.object else null
    else
        null;
    const type_name = if (type_obj) |t| objString(t, "name") else null;

    var other_key: ?[]const u8 = null;
    var dir: []const u8 = "link";
    if (value.object.get("outwardIssue")) |o| {
        if (o == .object) other_key = objString(o.object, "key");
        if (type_obj) |t| {
            if (objString(t, "outward")) |d| dir = d;
        }
    } else if (value.object.get("inwardIssue")) |i| {
        if (i == .object) other_key = objString(i.object, "key");
        if (type_obj) |t| {
            if (objString(t, "inward")) |d| dir = d;
        }
    }
    if (other_key == null) return null;
    if (type_name) |tn| {
        return try std.fmt.allocPrint(allocator, "{s} ({s}) {s}", .{ tn, dir, other_key.? });
    }
    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ dir, other_key.? });
}

fn formatIssueRestriction(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    // Usually { issuerestrictions: {}, shouldDisplay: bool } — skip empty noise.
    if (value != .object) return null;
    if (value.object.get("issuerestrictions")) |r| {
        if (r == .object and r.object.count() > 0) {
            return try compactObject(allocator, r.object);
        }
    }
    return null;
}

fn formatAdfOrNull(allocator: Allocator, obj: std.json.ObjectMap) EncodeError!?[]u8 {
    if (objString(obj, "type")) |ty| {
        if (std.mem.eql(u8, ty, "doc")) {
            var buf: std.ArrayList(u8) = .empty;
            errdefer buf.deinit(allocator);
            try extractText(allocator, &buf, .{ .object = obj });
            const trimmed = std.mem.trim(u8, buf.items, " \t\r\n");
            if (trimmed.len == 0) {
                buf.deinit(allocator);
                return null;
            }
            if (trimmed.len > section_text_max) {
                const cut = try std.fmt.allocPrint(allocator, "{s}…", .{trimmed[0..section_text_max]});
                buf.deinit(allocator);
                return cut;
            }
            const owned = try allocator.dupe(u8, trimmed);
            buf.deinit(allocator);
            return owned;
        }
    }
    return null;
}

// ─── Shape fallback (no schema) ──────────────────────────────────────────────

fn formatByShape(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    switch (value) {
        .null => return null,
        .bool => |b| return try allocator.dupe(u8, if (b) "true" else "false"),
        .integer => |n| return try std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| return try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .number_string => |s| {
            if (s.len == 0) return null;
            return try allocator.dupe(u8, s);
        },
        .string => |s| {
            if (std.mem.trim(u8, s, " \t\r\n").len == 0) return null;
            return try allocator.dupe(u8, s);
        },
        .array => |arr| {
            if (arr.items.len == 0) return null;
            return try formatSchemaArray(allocator, value, null);
        },
        .object => |obj| return try formatObjectShape(allocator, obj),
    }
}

fn formatObjectShape(allocator: Allocator, obj: std.json.ObjectMap) EncodeError!?[]u8 {
    if (obj.count() == 0) return null;
    if (try formatAdfOrNull(allocator, obj)) |adf| return adf;
    if (try formatUser(allocator, .{ .object = obj })) |u| return u;
    if (objString(obj, "name")) |name| {
        if (name.len > 0) {
            if (objString(obj, "key")) |k| {
                return try std.fmt.allocPrint(allocator, "{s} — {s}", .{ k, name });
            }
            return try allocator.dupe(u8, name);
        }
    }
    if (objString(obj, "key")) |k| {
        if (k.len > 0) return try allocator.dupe(u8, k);
    }
    if (obj.get("value")) |v| return try formatByShape(allocator, v);
    if (obj.get("comments")) |c| {
        if (c == .array) return try formatSchemaArray(allocator, c, "comment");
    }
    if (obj.get("worklogs")) |w| {
        if (w == .array) return try formatSchemaArray(allocator, w, "worklog");
    }
    if (try formatVotes(allocator, .{ .object = obj })) |v| return v;
    if (try formatWatches(allocator, .{ .object = obj })) |v| return v;
    if (try formatProgress(allocator, .{ .object = obj })) |v| return v;
    if (obj.get("body")) |body| return try formatByShape(allocator, body);
    if (isMetadataOnlyObject(obj)) return null;
    return try compactObject(allocator, obj);
}

fn isMetadataOnlyObject(obj: std.json.ObjectMap) bool {
    var it = obj.iterator();
    var any = false;
    while (it.next()) |e| {
        any = true;
        const k = e.key_ptr.*;
        if (std.mem.eql(u8, k, "self") or
            std.mem.eql(u8, k, "id") or
            std.mem.eql(u8, k, "iconUrl") or
            std.mem.eql(u8, k, "avatarUrls") or
            std.mem.eql(u8, k, "accountId") or
            std.mem.eql(u8, k, "accountType") or
            std.mem.eql(u8, k, "active") or
            std.mem.eql(u8, k, "timeZone") or
            std.mem.eql(u8, k, "emailAddress") or
            std.mem.eql(u8, k, "entityId") or
            std.mem.eql(u8, k, "hierarchyLevel") or
            std.mem.eql(u8, k, "subtask") or
            std.mem.eql(u8, k, "avatarId") or
            (std.mem.eql(u8, k, "description") and e.value_ptr.* == .string))
        {
            continue;
        }
        return false;
    }
    return any;
}

fn compactObject(allocator: Allocator, obj: std.json.ObjectMap) EncodeError!?[]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var n: usize = 0;
    var it = obj.iterator();
    while (it.next()) |e| {
        const k = e.key_ptr.*;
        if (std.mem.eql(u8, k, "self") or std.mem.eql(u8, k, "avatarUrls") or std.mem.eql(u8, k, "iconUrl")) continue;
        const piece = try formatByShape(allocator, e.value_ptr.*) orelse continue;
        defer allocator.free(piece);
        if (n > 0) try out.appendSlice(allocator, "; ");
        try out.print(allocator, "{s}={s}", .{ k, piece });
        n += 1;
        if (n >= 6) break;
        if (out.items.len > table_cell_max) break;
    }
    if (n == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

// ─── Jira search ─────────────────────────────────────────────────────────────

const search_cols = [_][]const u8{ "key", "summary", "status", "assignee", "priority", "issuetype", "updated", "duedate" };

fn tryRenderJiraSearch(allocator: Allocator, out: *std.ArrayList(u8), value: Value) EncodeError!bool {
    if (value != .object) return false;
    const obj = value.object;
    const issues_v = obj.get("issues") orelse return false;
    if (issues_v != .array) return false;
    const issues = issues_v.array.items;

    const total = if (obj.get("total")) |t| switch (t) {
        .integer => |n| n,
        else => @as(i64, @intCast(issues.len)),
    } else @as(i64, @intCast(issues.len));

    try out.print(allocator, "# Issues ({d}", .{issues.len});
    if (total != @as(i64, @intCast(issues.len))) {
        try out.print(allocator, " of {d}", .{total});
    }
    try out.appendSlice(allocator, ")\n\n");

    // Fixed main columns that appear on at least one issue (aligned).
    var col_ids: std.ArrayList([]const u8) = .empty;
    defer col_ids.deinit(allocator);
    try col_ids.append(allocator, "key");
    for (search_cols[1..]) |cid| {
        if (anyIssueHasField(issues, cid)) try col_ids.append(allocator, cid);
    }

    // Materialize cell strings for width calculation
    var cell_grid: std.ArrayList([]u8) = .empty;
    defer {
        for (cell_grid.items) |c| allocator.free(c);
        cell_grid.deinit(allocator);
    }
    const ncols = col_ids.items.len;
    for (issues) |issue| {
        if (issue != .object) continue;
        const io = issue.object;
        const fields = if (io.get("fields")) |f| if (f == .object) f.object else null else null;
        for (col_ids.items) |cid| {
            const cell = try searchCell(allocator, io, fields, cid);
            try cell_grid.append(allocator, cell);
        }
    }
    const nrows = if (ncols == 0) 0 else cell_grid.items.len / ncols;

    var widths = try allocator.alloc(usize, ncols);
    defer allocator.free(widths);
    for (col_ids.items, 0..) |cid, c| {
        widths[c] = displayWidth(prettyColHeader(cid));
    }
    var r: usize = 0;
    while (r < nrows) : (r += 1) {
        var c: usize = 0;
        while (c < ncols) : (c += 1) {
            const w = displayWidth(cell_grid.items[r * ncols + c]);
            if (w > widths[c]) widths[c] = @min(w, @as(usize, 48));
        }
    }

    // Header
    try out.appendSlice(allocator, "|");
    for (col_ids.items, 0..) |cid, c| {
        try out.append(allocator, ' ');
        try appendPaddedCell(allocator, out, prettyColHeader(cid), widths[c], false);
        try out.appendSlice(allocator, " |");
    }
    try out.append(allocator, '\n');
    // Separator
    try out.appendSlice(allocator, "|");
    for (widths) |w| {
        try out.append(allocator, ' ');
        try appendDashes(allocator, out, w);
        try out.appendSlice(allocator, " |");
    }
    try out.append(allocator, '\n');
    // Body
    r = 0;
    while (r < nrows) : (r += 1) {
        try out.appendSlice(allocator, "|");
        var c: usize = 0;
        while (c < ncols) : (c += 1) {
            try out.append(allocator, ' ');
            try appendPaddedCell(allocator, out, cell_grid.items[r * ncols + c], widths[c], true);
            try out.appendSlice(allocator, " |");
        }
        try out.append(allocator, '\n');
    }
    return true;
}

fn searchCell(allocator: Allocator, issue: std.json.ObjectMap, fields: ?std.json.ObjectMap, cid: []const u8) EncodeError![]u8 {
    if (std.mem.eql(u8, cid, "key")) {
        return try allocator.dupe(u8, objString(issue, "key") orelse "-");
    }
    if (fields) |f| {
        if (f.get(cid)) |v| {
            if (try formatFieldValue(allocator, v, null)) |cell| return cell;
        }
    }
    return try allocator.dupe(u8, "-");
}

fn curateSearchJson(allocator: Allocator, value: Value) EncodeError!?[]u8 {
    if (value != .object) return null;
    const obj = value.object;
    const issues_v = obj.get("issues") orelse return null;
    if (issues_v != .array) return null;
    const issues = issues_v.array.items;

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "{\n  \"total\": ");
    if (obj.get("total")) |t| {
        if (t == .integer) {
            try out.print(allocator, "{d}", .{t.integer});
        } else {
            try out.print(allocator, "{d}", .{issues.len});
        }
    } else {
        try out.print(allocator, "{d}", .{issues.len});
    }
    try out.appendSlice(allocator, ",\n  \"issues\": [");

    var first = true;
    for (issues) |issue| {
        if (issue != .object) continue;
        const io = issue.object;
        const fields = if (io.get("fields")) |f| if (f == .object) f.object else null else null;
        if (!first) try out.appendSlice(allocator, ",");
        first = false;
        try out.appendSlice(allocator, "\n    {\n      \"key\": ");
        try appendJsonString(allocator, &out, objString(io, "key") orelse "-");
        for (search_cols[1..]) |cid| {
            if (fields) |f| {
                if (f.get(cid)) |v| {
                    if (try formatFieldValue(allocator, v, null)) |cell| {
                        defer allocator.free(cell);
                        try out.appendSlice(allocator, ",\n      ");
                        try appendJsonString(allocator, &out, cid);
                        try out.appendSlice(allocator, ": ");
                        try appendJsonString(allocator, &out, cell);
                    }
                }
            }
        }
        try out.appendSlice(allocator, "\n    }");
    }
    try out.appendSlice(allocator, "\n  ]\n}");
    return try out.toOwnedSlice(allocator);
}

fn anyIssueHasField(issues: []const Value, field_id: []const u8) bool {
    for (issues) |issue| {
        if (issue != .object) continue;
        const fields = if (issue.object.get("fields")) |f| if (f == .object) f.object else null else null;
        if (fields) |f| {
            if (f.get(field_id)) |v| {
                if (v != .null) return true;
            }
        }
    }
    return false;
}

fn prettyColHeader(field_id: []const u8) []const u8 {
    if (std.mem.eql(u8, field_id, "key")) return "Key";
    if (std.mem.eql(u8, field_id, "summary")) return "Summary";
    if (std.mem.eql(u8, field_id, "status")) return "Status";
    if (std.mem.eql(u8, field_id, "assignee")) return "Assignee";
    if (std.mem.eql(u8, field_id, "priority")) return "Priority";
    if (std.mem.eql(u8, field_id, "issuetype")) return "Type";
    if (std.mem.eql(u8, field_id, "updated")) return "Updated";
    if (std.mem.eql(u8, field_id, "duedate")) return "Due";
    return field_id;
}

// ─── Generic fallback ────────────────────────────────────────────────────────

fn renderGeneric(allocator: Allocator, out: *std.ArrayList(u8), value: Value, depth: usize) EncodeError!void {
    switch (value) {
        .object => |obj| {
            if (obj.count() == 0) {
                try out.appendSlice(allocator, "_{}_");
                return;
            }
            var it = obj.iterator();
            while (it.next()) |entry| {
                try writeMdIndent(allocator, out, depth);
                try out.appendSlice(allocator, "- **");
                try appendEscapedInline(allocator, out, entry.key_ptr.*);
                try out.appendSlice(allocator, "**:");
                switch (entry.value_ptr.*) {
                    .object, .array => {
                        try out.append(allocator, '\n');
                        try renderGeneric(allocator, out, entry.value_ptr.*, depth + 1);
                    },
                    else => {
                        try out.append(allocator, ' ');
                        try writeMdPrimitive(allocator, out, entry.value_ptr.*);
                        try out.append(allocator, '\n');
                    },
                }
            }
        },
        .array => |arr| {
            if (arr.items.len == 0) {
                try writeMdIndent(allocator, out, depth);
                try out.appendSlice(allocator, "- _(empty)_\n");
                return;
            }
            for (arr.items, 0..) |item, i| {
                try writeMdIndent(allocator, out, depth);
                try out.print(allocator, "- **[{d}]**:", .{i});
                switch (item) {
                    .object, .array => {
                        try out.append(allocator, '\n');
                        try renderGeneric(allocator, out, item, depth + 1);
                    },
                    else => {
                        try out.append(allocator, ' ');
                        try writeMdPrimitive(allocator, out, item);
                        try out.append(allocator, '\n');
                    },
                }
            }
        },
        else => {
            try writeMdPrimitive(allocator, out, value);
            try out.append(allocator, '\n');
        },
    }
}

fn writeMdIndent(allocator: Allocator, out: *std.ArrayList(u8), depth: usize) EncodeError!void {
    var i: usize = 0;
    while (i < depth * 2) : (i += 1) try out.append(allocator, ' ');
}

fn writeMdPrimitive(allocator: Allocator, out: *std.ArrayList(u8), value: Value) EncodeError!void {
    switch (value) {
        .null => try out.appendSlice(allocator, "`null`"),
        .bool => |b| try out.appendSlice(allocator, if (b) "`true`" else "`false`"),
        .integer => |n| try out.print(allocator, "`{d}`", .{n}),
        .float => |f| try out.print(allocator, "`{d}`", .{f}),
        .number_string => |s| try out.print(allocator, "`{s}`", .{s}),
        .string => |s| {
            if (s.len > 200) {
                try appendEscapedInline(allocator, out, s[0..200]);
                try out.appendSlice(allocator, "…");
            } else {
                try appendEscapedInline(allocator, out, s);
            }
        },
        else => try out.appendSlice(allocator, "…"),
    }
}

fn appendEscapedCell(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) EncodeError!void {
    for (s) |c| {
        if (c == '|' or c == '\n' or c == '\r') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, c);
        }
    }
}

fn appendEscapedInline(allocator: Allocator, out: *std.ArrayList(u8), s: []const u8) EncodeError!void {
    for (s) |c| {
        if (c == '\n' or c == '\r') {
            try out.append(allocator, ' ');
        } else {
            try out.append(allocator, c);
        }
    }
}

fn objString(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn extractText(allocator: Allocator, out: *std.ArrayList(u8), value: Value) EncodeError!void {
    switch (value) {
        .null => {},
        .string => |s| try out.appendSlice(allocator, s),
        .object => |obj| {
            if (obj.get("text")) |t| {
                if (t == .string) try out.appendSlice(allocator, t.string);
            }
            if (obj.get("content")) |c| {
                try extractText(allocator, out, c);
            }
            if (objString(obj, "type")) |ty| {
                if (std.mem.eql(u8, ty, "paragraph") or std.mem.eql(u8, ty, "heading") or
                    std.mem.eql(u8, ty, "bulletList") or std.mem.eql(u8, ty, "orderedList") or
                    std.mem.eql(u8, ty, "listItem") or std.mem.eql(u8, ty, "blockquote") or
                    std.mem.eql(u8, ty, "codeBlock") or std.mem.eql(u8, ty, "rule"))
                {
                    if (out.items.len == 0 or out.items[out.items.len - 1] != '\n') {
                        try out.append(allocator, '\n');
                    }
                }
            }
        },
        .array => |arr| {
            for (arr.items) |item| {
                try extractText(allocator, out, item);
            }
        },
        else => {},
    }
}

// ─── Tests ───────────────────────────────────────────────────────────────────

test "markdown uses schema types for formatting" {
    const a = std.testing.allocator;
    const body =
        \\{
        \\  "key":"IVT-154",
        \\  "names":{
        \\    "status":"Status",
        \\    "assignee":"Assignee",
        \\    "issuetype":"Issue Type",
        \\    "priority":"Priority",
        \\    "customfield_10020":"Sprint",
        \\    "customfield_10021":"Flags",
        \\    "description":"Description",
        \\    "summary":"Summary",
        \\    "duedate":"Due date",
        \\    "labels":"Labels",
        \\    "workratio":"Work Ratio",
        \\    "votes":"Votes"
        \\  },
        \\  "schema":{
        \\    "summary":{"type":"string","system":"summary"},
        \\    "status":{"type":"status","system":"status"},
        \\    "assignee":{"type":"user","system":"assignee"},
        \\    "issuetype":{"type":"issuetype","system":"issuetype"},
        \\    "priority":{"type":"priority","system":"priority"},
        \\    "duedate":{"type":"date","system":"duedate"},
        \\    "labels":{"type":"array","items":"string","system":"labels"},
        \\    "description":{"type":"string","system":"description"},
        \\    "customfield_10020":{"type":"array","items":"json","custom":"com.pyxis.greenhopper.jira:gh-sprint","customId":10020},
        \\    "customfield_10021":{"type":"array","items":"option","custom":"com.atlassian.jira.plugin.system.customfieldtypes:multicheckboxes","customId":10021},
        \\    "workratio":{"type":"number","system":"workratio"},
        \\    "votes":{"type":"votes","system":"votes"}
        \\  },
        \\  "fields":{
        \\    "summary":"Ship output formats",
        \\    "status":{"name":"In Progress","id":"3"},
        \\    "assignee":{"displayName":"Ada","accountId":"abc"},
        \\    "issuetype":{"name":"Task"},
        \\    "priority":{"name":"High"},
        \\    "duedate":"2026-07-17",
        \\    "labels":["web","layout"],
        \\    "customfield_10020":[{"id":1,"name":"SCRUM Sprint 1","state":"future"}],
        \\    "customfield_10021":[{"id":"10000","value":"Impediment"}],
        \\    "workratio":-1,
        \\    "votes":{"votes":0,"hasVoted":false},
        \\    "description":{"type":"doc","content":[{"type":"paragraph","content":[{"type":"text","text":"Hello world"}]}]}
        \\  }
        \\}
    ;
    const out = try encodeAlloc(a, body);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "# IVT-154: Ship output formats") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Status") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "In Progress") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Assignee") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Ada") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Sprint") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SCRUM Sprint 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "web, layout") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Flags") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Impediment") != null);
    // noise dropped from main view
    try std.testing.expect(std.mem.indexOf(u8, out, "Votes") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Work Ratio") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "## Description") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hello world") != null);
    // aligned header separator present
    try std.testing.expect(std.mem.indexOf(u8, out, "| Field") != null);
}

test "curateAlloc returns main fields only for jira issue" {
    const a = std.testing.allocator;
    const body =
        \\{"key":"X-1","fields":{"summary":"S","status":{"name":"Done"},"votes":{"votes":3},"lastViewed":"2026-01-01","customfield_10020":[{"name":"Sprint A"}]},"names":{"status":"Status","votes":"Votes","lastViewed":"Last Viewed","customfield_10020":"Sprint"},"schema":{"status":{"type":"status","system":"status"},"votes":{"type":"votes","system":"votes"},"lastViewed":{"type":"datetime","system":"lastViewed"},"customfield_10020":{"type":"array","items":"json","custom":"com.pyxis.greenhopper.jira:gh-sprint"}}}
    ;
    const curated = try curateAlloc(a, body);
    try std.testing.expect(curated != null);
    defer a.free(curated.?);
    try std.testing.expect(std.mem.indexOf(u8, curated.?, "\"key\": \"X-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, curated.?, "\"status\": \"Done\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, curated.?, "customfield_10020") != null);
    try std.testing.expect(std.mem.indexOf(u8, curated.?, "votes") == null);
    try std.testing.expect(std.mem.indexOf(u8, curated.?, "lastViewed") == null);
}

test "markdown skips null and empty without hardcoding field set" {
    const a = std.testing.allocator;
    const body =
        \\{"key":"X-1","fields":{"summary":"S","resolution":null,"components":[],"environment":null,"customfield_999":"hello","votes":{"votes":1}},"names":{"customfield_999":"New Custom","votes":"Votes"},"schema":{"customfield_999":{"type":"string","custom":"com.atlassian.jira.plugin.system.customfieldtypes:textfield","customId":999},"votes":{"type":"votes","system":"votes"}}}
    ;
    const out = try encodeAlloc(a, body);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "New Custom") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "resolution") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "components") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Votes") == null);
}

test "markdown renders search table" {
    const a = std.testing.allocator;
    const body =
        \\{"total":1,"issues":[{"key":"IVT-1","fields":{"summary":"One","status":{"name":"Done"},"assignee":null}}]}
    ;
    const out = try encodeAlloc(a, body);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "IVT-1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "One") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Done") != null);
}
