//! Small JQL helpers for assignee filters and query composition.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Build an assignee clause from CLI shorthand.
/// - `me` / `currentUser` → `assignee = currentUser()`
/// - `unassigned` / `none` / `empty` → `assignee is EMPTY`
/// - otherwise → `assignee = "<value>"` (accountId, email, or display name)
pub fn assigneeClause(allocator: Allocator, assignee: []const u8) ![]u8 {
    const a = std.mem.trim(u8, assignee, " \t");
    if (a.len == 0) return error.EmptyAssignee;
    if (std.ascii.eqlIgnoreCase(a, "me") or std.ascii.eqlIgnoreCase(a, "currentuser") or std.ascii.eqlIgnoreCase(a, "current_user")) {
        return try allocator.dupe(u8, "assignee = currentUser()");
    }
    if (std.ascii.eqlIgnoreCase(a, "unassigned") or std.ascii.eqlIgnoreCase(a, "none") or std.ascii.eqlIgnoreCase(a, "empty")) {
        return try allocator.dupe(u8, "assignee is EMPTY");
    }
    // Escape quotes inside user token for JQL string literal.
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "assignee = \"");
    for (a) |c| {
        if (c == '"' or c == '\\') try list.append(allocator, '\\');
        try list.append(allocator, c);
    }
    try list.append(allocator, '"');
    return try list.toOwnedSlice(allocator);
}

/// Combine optional JQL parts with AND. Either/both may be null.
/// Returns null if both empty. Caller owns result when non-null.
pub fn andClauses(allocator: Allocator, a: ?[]const u8, b: ?[]const u8) !?[]u8 {
    const aa = if (a) |x| std.mem.trim(u8, x, " \t") else "";
    const bb = if (b) |x| std.mem.trim(u8, x, " \t") else "";
    if (aa.len == 0 and bb.len == 0) return null;
    if (aa.len == 0) return try allocator.dupe(u8, bb);
    if (bb.len == 0) return try allocator.dupe(u8, aa);
    return try std.fmt.allocPrint(allocator, "({s}) AND ({s})", .{ aa, bb });
}

/// Percent-encode for use as a query parameter value (application/x-www-form-urlencoded-ish).
pub fn urlEncode(allocator: Allocator, s: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    for (s) |c| {
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~') {
            try list.append(allocator, c);
        } else if (c == ' ') {
            try list.append(allocator, '+');
        } else {
            try list.print(allocator, "%{X:0>2}", .{c});
        }
    }
    return try list.toOwnedSlice(allocator);
}

test "assigneeClause me" {
    const a = std.testing.allocator;
    const c = try assigneeClause(a, "me");
    defer a.free(c);
    try std.testing.expectEqualStrings("assignee = currentUser()", c);
}

test "assigneeClause user" {
    const a = std.testing.allocator;
    const c = try assigneeClause(a, "ada@example.com");
    defer a.free(c);
    try std.testing.expectEqualStrings("assignee = \"ada@example.com\"", c);
}

test "andClauses" {
    const a = std.testing.allocator;
    const j = try andClauses(a, "assignee = currentUser()", "project = IVT");
    defer a.free(j.?);
    try std.testing.expectEqualStrings("(assignee = currentUser()) AND (project = IVT)", j.?);
}
