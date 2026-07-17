const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http_client = @import("../http/client.zig");
const store = @import("store.zig");

pub const DEFAULT_CALLBACK_PORT: u16 = 8787;
// Classic Jira platform (issue search/get) + granular Jira Software (Agile boards).
// Jira Software does NOT accept classic scopes for /rest/agile — board APIs need
// read:board-scope:jira-software (see developer.atlassian.com/cloud/jira/software/...).
//
// After changing this list you MUST:
//   1) developer console → app → Permissions → enable **Jira Software API** (not only Jira API)
//      and tick the granular scopes below
//   2) Revoke the app at https://id.atlassian.com/manage-profile/apps (optional but reliable)
//   3) `atlassian auth login` again (refresh does NOT add scopes)
pub const DEFAULT_SCOPES: []const u8 =
    "read:jira-work write:jira-work read:jira-user offline_access " ++
    "read:board-scope:jira-software read:sprint:jira-software " ++
    "read:issue-details:jira read:project:jira read:jql:jira " ++
    "read:confluence-content.all write:confluence-content manage:confluence-content read:me";

pub const REQUIRED_AGILE_SCOPES = [_][]const u8{
    "read:board-scope:jira-software",
    "read:issue-details:jira",
};

pub fn scopeContains(scope_list: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, scope_list, needle) != null;
}

pub fn missingAgileScopes(scope_list: []const u8, buf: [][]const u8) []const []const u8 {
    var n: usize = 0;
    for (REQUIRED_AGILE_SCOPES) |s| {
        if (!scopeContains(scope_list, s)) {
            if (n < buf.len) {
                buf[n] = s;
                n += 1;
            }
        }
    }
    return buf[0..n];
}

fn urlEncodeQuery(allocator: Allocator, s: []const u8) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        const unreserved = (c >= 'A' and c <= 'Z') or
            (c >= 'a' and c <= 'z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_' or c == '.' or c == '~';
        if (unreserved) {
            try list.append(allocator, c);
        } else {
            try list.append(allocator, '%');
            try list.append(allocator, hex[c >> 4]);
            try list.append(allocator, hex[c & 0xf]);
        }
    }
    return try list.toOwnedSlice(allocator);
}

pub fn authorizeUrl(allocator: Allocator, client_id: []const u8, redirect_uri: []const u8, state: []const u8, scopes: []const u8) ![]u8 {
    const scope_enc = try urlEncodeQuery(allocator, scopes);
    defer allocator.free(scope_enc);
    const redir_enc = try urlEncodeQuery(allocator, redirect_uri);
    defer allocator.free(redir_enc);
    const client_enc = try urlEncodeQuery(allocator, client_id);
    defer allocator.free(client_enc);
    const state_enc = try urlEncodeQuery(allocator, state);
    defer allocator.free(state_enc);
    return try std.fmt.allocPrint(allocator, "https://auth.atlassian.com/authorize?audience=api.atlassian.com&client_id={s}&scope={s}&redirect_uri={s}&state={s}&response_type=code&prompt=consent", .{ client_enc, scope_enc, redir_enc, state_enc });
}

const TokenResponse = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_in: i64 = 3600,
    scope: ?[]const u8 = null,
};

pub fn parseTokenJson(allocator: Allocator, body: []const u8, now_unix: i64) !store.TokenSet {
    var parsed = try std.json.parseFromSlice(TokenResponse, allocator, body, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    const v = parsed.value;
    var tokens = store.TokenSet{
        .access_token = try allocator.dupe(u8, v.access_token),
        .refresh_token = null,
        .expires_at_unix = now_unix + v.expires_in,
        .scope = null,
        .owns = true,
    };
    errdefer tokens.deinit(allocator);
    if (v.refresh_token) |r| tokens.refresh_token = try allocator.dupe(u8, r);
    if (v.scope) |s| tokens.scope = try allocator.dupe(u8, s);
    return tokens;
}

fn nowUnix(io: Io) i64 {
    return Io.Clock.real.now(io).toSeconds();
}

pub fn exchangeCode(
    client: *http_client.Client,
    allocator: Allocator,
    client_id: []const u8,
    client_secret: []const u8,
    code: []const u8,
    redirect_uri: []const u8,
) !store.TokenSet {
    const body_obj = .{
        .grant_type = "authorization_code",
        .client_id = client_id,
        .client_secret = client_secret,
        .code = code,
        .redirect_uri = redirect_uri,
    };
    const body = try std.json.Stringify.valueAlloc(allocator, body_obj, .{});
    defer allocator.free(body);

    var result = try client.request(.{
        .method = .POST,
        .url = "https://auth.atlassian.com/oauth/token",
        .auth_header = null,
        .body = body,
    });
    defer result.deinit(allocator);
    return switch (result) {
        .ok => |r| {
            if (r.body.len == 0) return error.TokenExchangeEmptyBody;
            return parseTokenJson(allocator, r.body, nowUnix(client.io)) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.TokenExchangeParseFailed,
            };
        },
        .err => |e| {
            std.log.err("token exchange HTTP {d}: {s}", .{ e.status orelse 0, e.message });
            return error.TokenExchangeFailed;
        },
    };
}

pub fn refresh(
    client: *http_client.Client,
    allocator: Allocator,
    client_id: []const u8,
    client_secret: []const u8,
    refresh_token: []const u8,
) !store.TokenSet {
    const body_obj = .{
        .grant_type = "refresh_token",
        .client_id = client_id,
        .client_secret = client_secret,
        .refresh_token = refresh_token,
    };
    const body = try std.json.Stringify.valueAlloc(allocator, body_obj, .{});
    defer allocator.free(body);
    var result = try client.request(.{
        .method = .POST,
        .url = "https://auth.atlassian.com/oauth/token",
        .auth_header = null,
        .body = body,
    });
    defer result.deinit(allocator);
    return switch (result) {
        .ok => |r| {
            if (r.body.len == 0) return error.TokenRefreshEmptyBody;
            return parseTokenJson(allocator, r.body, nowUnix(client.io)) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.TokenRefreshParseFailed,
            };
        },
        .err => |e| {
            if (client.verbose) {
                std.log.err("token refresh HTTP {d}: {s}", .{ e.status orelse 0, e.message });
            }
            return error.TokenRefreshFailed;
        },
    };
}

test "parseTokenJson" {
    const body = "{\"access_token\":\"abc\",\"refresh_token\":\"def\",\"expires_in\":3600,\"scope\":\"x\"}";
    var t = try parseTokenJson(std.testing.allocator, body, 1_000_000);
    defer t.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("abc", t.access_token);
    try std.testing.expectEqualStrings("def", t.refresh_token.?);
    try std.testing.expectEqual(@as(i64, 1_000_000 + 3600), t.expires_at_unix);
}

test "authorizeUrl uses encoded redirect_uri" {
    const u = try authorizeUrl(std.testing.allocator, "CID", "http://127.0.0.1:8787/callback", "STATE", "read:me offline_access");
    defer std.testing.allocator.free(u);
    try std.testing.expect(std.mem.indexOf(u8, u, "client_id=CID") != null);
    try std.testing.expect(std.mem.indexOf(u8, u, "state=STATE") != null);
    try std.testing.expect(std.mem.indexOf(u8, u, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8787%2Fcallback") != null);
}
