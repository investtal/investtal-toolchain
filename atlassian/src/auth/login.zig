const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config_mod = @import("../config/root.zig");
const http_client = @import("../http/client.zig");
const oauth = @import("oauth.zig");
const store = @import("store.zig");

/// Interactive OAuth login: open browser + loopback callback.
/// Returns owned TokenSet.
pub fn interactiveLogin(allocator: Allocator, io: Io, cfg: config_mod.Config, scopes: []const u8) !store.TokenSet {
    const client_id = cfg.oauth_client_id orelse return error.MissingOAuthClientId;
    const client_secret = cfg.oauth_client_secret orelse return error.MissingOAuthClientSecret;

    const redirect_uri = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/callback", .{oauth.DEFAULT_CALLBACK_PORT});
    defer allocator.free(redirect_uri);

    var state_bytes: [16]u8 = undefined;
    try io.randomSecure(&state_bytes);
    var state_hex: [32]u8 = undefined;
    const hex = "0123456789abcdef";
    for (state_bytes, 0..) |b, i| {
        state_hex[i * 2] = hex[b >> 4];
        state_hex[i * 2 + 1] = hex[b & 0xf];
    }
    const state: []const u8 = state_hex[0..];

    const url = try oauth.authorizeUrl(allocator, client_id, redirect_uri, state, scopes);
    defer allocator.free(url);

    std.log.info("Opening browser for Atlassian OAuth…", .{});
    std.log.info("If it does not open, visit:\n  {s}", .{url});
    openBrowser(allocator, io, url) catch {};

    const code = try waitForCallback(allocator, io, oauth.DEFAULT_CALLBACK_PORT, state);
    defer allocator.free(code);

    var client: http_client.Client = .{
        .allocator = allocator,
        .io = io,
        .retries = cfg.http_retries,
    };

    var tokens = try oauth.exchangeCode(&client, allocator, client_id, client_secret, code, redirect_uri);
    errdefer tokens.deinit(allocator);

    // Resolve cloud id from accessible-resources
    if (try fetchCloudId(allocator, &client, tokens.access_token, cfg.url)) |cid| {
        if (tokens.cloud_id) |old| allocator.free(old);
        tokens.cloud_id = cid;
    }

    try store.saveTokens(allocator, io, tokens);
    return tokens;
}

fn openBrowser(allocator: Allocator, io: Io, url: []const u8) !void {
    _ = allocator;
    const argv = switch (builtinOs()) {
        .macos => &[_][]const u8{ "open", url },
        .linux => &[_][]const u8{ "xdg-open", url },
        .windows => &[_][]const u8{ "cmd", "/c", "start", url },
        else => return,
    };
    var child = try std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
    _ = try child.wait(io);
}

fn builtinOs() enum { macos, linux, windows, other } {
    return switch (@import("builtin").os.tag) {
        .macos => .macos,
        .linux => .linux,
        .windows => .windows,
        else => .other,
    };
}

fn waitForCallback(allocator: Allocator, io: Io, port: u16, expected_state: []const u8) ![]u8 {
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", port);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("Listening on http://127.0.0.1:{d}/callback for OAuth redirect…", .{port});

    var stream = try server.accept(io);
    defer stream.close(io);

    var rbuf: [4096]u8 = undefined;
    var reader = stream.reader(io, &rbuf);
    var req_buf: [4096]u8 = undefined;
    // Read first line-ish of HTTP request (enough for query string).
    var n: usize = 0;
    while (n < req_buf.len) {
        const got = reader.interface.readSliceShort(req_buf[n..]) catch break;
        if (got == 0) break;
        n += got;
        if (std.mem.indexOf(u8, req_buf[0..n], "\r\n\r\n") != null) break;
    }
    const req = req_buf[0..n];

    const code = findQueryParam(req, "code") orelse return error.MissingCode;
    const st = findQueryParam(req, "state") orelse return error.MissingState;
    if (!std.mem.eql(u8, st, expected_state)) return error.StateMismatch;

    const response =
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nConnection: close\r\n\r\n" ++
        "<html><body><h1>Atlassian CLI</h1><p>Login successful. You can close this window.</p></body></html>";
    var wbuf: [64]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    try writer.interface.writeAll(response);
    try writer.interface.flush();

    return try allocator.dupe(u8, code);
}

fn findQueryParam(req: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, req, '?') orelse return null;
    var sp = std.mem.tokenizeAny(u8, req[q + 1 ..], "& ");
    while (sp.next()) |pair| {
        if (pair.len == 0 or pair[0] == '\r' or pair[0] == '\n') break;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) {
            var val = pair[eq + 1 ..];
            // trim HTTP remainder
            if (std.mem.indexOfScalar(u8, val, ' ')) |s| val = val[0..s];
            if (std.mem.indexOfScalar(u8, val, '\r')) |s| val = val[0..s];
            return val;
        }
    }
    return null;
}

const AccessibleResource = struct {
    id: []const u8,
    url: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

fn fetchCloudId(allocator: Allocator, client: *http_client.Client, access_token: []const u8, preferred_url: ?[]const u8) !?[]u8 {
    const auth = try std.fmt.allocPrint(allocator, "Bearer {s}", .{access_token});
    defer allocator.free(auth);
    var result = try client.request(.{
        .method = .GET,
        .url = "https://api.atlassian.com/oauth/token/accessible-resources",
        .auth_header = auth,
    });
    defer result.deinit(allocator);
    switch (result) {
        .err => return null,
        .ok => |r| {
            var parsed = std.json.parseFromSlice([]AccessibleResource, allocator, r.body, .{
                .allocate = .alloc_always,
                .ignore_unknown_fields = true,
            }) catch return null;
            defer parsed.deinit();
            if (parsed.value.len == 0) return null;

            if (preferred_url) |pu| {
                const pref = std.mem.trimEnd(u8, pu, "/");
                for (parsed.value) |res| {
                    if (res.url) |u| {
                        const ru = std.mem.trimEnd(u8, u, "/");
                        if (std.mem.eql(u8, ru, pref) or std.mem.startsWith(u8, ru, pref) or std.mem.startsWith(u8, pref, ru)) {
                            return try allocator.dupe(u8, res.id);
                        }
                    }
                }
            }
            return try allocator.dupe(u8, parsed.value[0].id);
        },
    }
}
