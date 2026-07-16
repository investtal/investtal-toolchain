const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http_client = @import("../http/client.zig");
const store = @import("store.zig");

pub const DEFAULT_CALLBACK_PORT: u16 = 8787;
pub const DEFAULT_SCOPES =
    \\read:jira-work write:jira-work read:jira-user offline_access read:confluence-content.all write:confluence-content manage:confluence-content read:me
;

pub fn authorizeUrl(allocator: Allocator, client_id: []const u8, redirect_uri: []const u8, state: []const u8, scopes: []const u8) ![]u8 {
    // Minimal query encoding for spaces.
    const scope_enc = try std.mem.replaceOwned(u8, allocator, scopes, " ", "%20");
    defer allocator.free(scope_enc);
    const redir_enc = try std.mem.replaceOwned(u8, allocator, redirect_uri, ":", "%3A");
    defer allocator.free(redir_enc);
    // simplistic — enough for localhost callback
    return try std.fmt.allocPrint(allocator, "https://auth.atlassian.com/authorize?audience=api.atlassian.com&client_id={s}&scope={s}&redirect_uri={s}&state={s}&response_type=code&prompt=consent", .{ client_id, scope_enc, redirect_uri, state });
}

pub fn parseTokenJson(allocator: Allocator, body: []const u8) !store.TokenSet {
    const access = extractString(body, "access_token") orelse return error.InvalidTokenResponse;
    const refresh_tok = extractString(body, "refresh_token");
    const expires_in = extractInt(body, "expires_in") orelse 3600;
    return .{
        .access_token = try allocator.dupe(u8, access),
        .refresh_token = if (refresh_tok) |r| try allocator.dupe(u8, r) else null,
        // Callers may overwrite with wall-clock absolute expiry; default is relative-ish.
        .expires_at_unix = expires_in,
        .scope = if (extractString(body, "scope")) |s| try allocator.dupe(u8, s) else null,
        .owns = true,
    };
}

fn extractString(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = idx + needle.len;
    // skip whitespace and colon; handle null
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == ':')) : (i += 1) {}
    if (i >= body.len) return null;
    if (body[i] == 'n') return null; // null
    if (body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {
        if (body[i] == '\\' and i + 1 < body.len) i += 1;
    }
    return body[start..i];
}

fn extractInt(body: []const u8, key: []const u8) ?i64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = idx + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == ':' or body[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < body.len and body[i] >= '0' and body[i] <= '9') : (i += 1) {}
    if (start == i) return null;
    return std.fmt.parseInt(i64, body[start..i], 10) catch null;
}

pub fn exchangeCode(
    client: *http_client.Client,
    allocator: Allocator,
    client_id: []const u8,
    client_secret: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
) !store.TokenSet {
    const body = try std.fmt.allocPrint(allocator, "{{\"grant_type\":\"authorization_code\",\"client_id\":\"{s}\",\"client_secret\":\"{s}\",\"code\":\"{s}\",\"redirect_uri\":\"{s}\"}}", .{ client_id, client_secret, code, redirect_uri });
    defer allocator.free(body);

    var result = try client.request(.{
        .method = .POST,
        .url = "https://auth.atlassian.com/oauth/token",
        .auth_header = "Basic ignored",
        .body = body,
    });
    defer result.deinit(allocator);
    return switch (result) {
        .ok => |r| try parseTokenJson(allocator, r.body),
        .err => error.TokenExchangeFailed,
    };
}

pub fn refresh(
    client: *http_client.Client,
    allocator: Allocator,
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
) !store.TokenSet {
    const body = try std.fmt.allocPrint(allocator, "{{\"grant_type\":\"refresh_token\",\"client_id\":\"{s}\",\"client_secret\":\"{s}\",\"refresh_token\":\"{s}\"}}", .{ client_id, client_secret, refresh_token });
    defer allocator.free(body);
    var result = try client.request(.{
        .method = .POST,
        .url = "https://auth.atlassian.com/oauth/token",
        .auth_header = "Basic ignored",
        .body = body,
    });
    defer result.deinit(allocator);
    return switch (result) {
        .ok => |r| try parseTokenJson(allocator, r.body),
        .err => error.TokenRefreshFailed,
    };
}

test "parseTokenJson" {
    const body = "{\"access_token\":\"abc\",\"refresh_token\":\"def\",\"expires_in\":3600,\"scope\":\"x\"}";
    var t = try parseTokenJson(std.testing.allocator, body);
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", t.access_token);
    try std.testing.expectEqualStrings("def", t.refresh_token.?);
}

test "authorizeUrl contains client_id" {
    const u = try authorizeUrl(std.testing.allocator, "CID", "http://127.0.0.1:8787/callback", "STATE", "read:me offline_access");
    defer std.testing.allocator.free(u);
    try std.testing.expect(std.mem.indexOf(u8, u, "client_id=CID") != null);
    try std.testing.expect(std.mem.indexOf(u8, u, "state=STATE") != null);
}

// silence unused Io import if not used in tests
comptime {
    _ = Io;
}
