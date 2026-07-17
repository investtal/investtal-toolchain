const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const config_mod = @import("../config/root.zig");
const http_client = @import("../http/client.zig");
const oauth = @import("oauth.zig");
const store = @import("store.zig");

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

    // Listen before openBrowser so a fast consent redirect cannot race the bind.
    const address = try Io.net.IpAddress.parseIp4("127.0.0.1", oauth.DEFAULT_CALLBACK_PORT);
    var server = try address.listen(io, .{ .reuse_address = true });
    defer server.deinit(io);

    std.log.info("Listening on http://127.0.0.1:{d}/callback for OAuth redirect…", .{oauth.DEFAULT_CALLBACK_PORT});
    std.log.info("Opening browser for Atlassian OAuth…", .{});
    std.log.info("If it does not open, visit:\n  {s}", .{url});
    openBrowser(allocator, io, url) catch {};

    const code = try waitForCallback(allocator, io, &server, state);
    defer allocator.free(code);

    var client: http_client.Client = .{
        .allocator = allocator,
        .io = io,
        .retries = cfg.http_retries,
    };

    var tokens = try oauth.exchangeCode(&client, allocator, client_id, client_secret, code, redirect_uri);
    errdefer tokens.deinit(allocator);

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

// JWT auth codes + Chrome headers; headroom so headers usually fit one fillMore.
const CALLBACK_READ_BUF: usize = 64 * 1024;

fn waitForCallback(allocator: Allocator, io: Io, server: *Io.net.Server, expected_state: []const u8) ![]u8 {
    // Skip non-callback sockets (favicon/noise) until code+state arrive.
    while (true) {
        var stream = try server.accept(io);
        const req = readHttpHeaders(allocator, io, &stream) catch |err| {
            stream.close(io);
            if (err == error.IncompleteRequest) continue;
            return err;
        };
        defer allocator.free(req);

        const code = findQueryParam(req, "code") orelse {
            stream.close(io);
            continue;
        };
        const st = findQueryParam(req, "state") orelse {
            stream.close(io);
            continue;
        };
        if (!std.mem.eql(u8, st, expected_state)) {
            stream.close(io);
            return error.StateMismatch;
        }

        const body =
            \\<!doctype html><html><body>
            \\<h1>Atlassian CLI</h1>
            \\<p>Login successful. You can close this window.</p>
            \\</body></html>
        ;
        const response = try std.fmt.allocPrint(
            allocator,
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
            .{ body.len, body },
        );
        defer allocator.free(response);

        var wbuf: [1024]u8 = undefined;
        var writer = stream.writer(io, &wbuf);
        try writer.interface.writeAll(response);
        try writer.interface.flush();
        stream.close(io);

        return try allocator.dupe(u8, code);
    }
}

/// Read until CRLFCRLF. Uses `fillMore` (one OS read); `readSliceShort` waits for
/// a full buffer and hung forever when Chrome sent headers then waited for a reply.
fn readHttpHeaders(allocator: Allocator, io: Io, stream: *Io.net.Stream) ![]u8 {
    var rbuf: [CALLBACK_READ_BUF]u8 = undefined;
    var reader = stream.reader(io, &rbuf);

    while (true) {
        const data = reader.interface.buffered();
        if (std.mem.indexOf(u8, data, "\r\n\r\n")) |end| {
            return try allocator.dupe(u8, data[0 .. end + 4]);
        }
        if (data.len >= rbuf.len) return error.RequestTooLarge;
        reader.interface.fillMore() catch |err| switch (err) {
            error.EndOfStream => return error.IncompleteRequest,
            else => return err,
        };
    }
}

fn findQueryParam(req: []const u8, key: []const u8) ?[]const u8 {
    const q = std.mem.indexOfScalar(u8, req, '?') orelse return null;
    var query = req[q + 1 ..];
    if (std.mem.indexOfAny(u8, query, " \r\n")) |end| query = query[0..end];

    var sp = std.mem.splitScalar(u8, query, '&');
    while (sp.next()) |pair| {
        if (pair.len == 0) continue;
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) {
            return pair[eq + 1 ..];
        }
    }
    return null;
}

test "findQueryParam extracts long Atlassian JWT code" {
    const code = "eyJraWQiOiJBVVRIX0NPREUifQ.eyJqdGkiOiIxIn0.sig";
    const req = "GET /callback?state=abc123&code=" ++ code ++ " HTTP/1.1\r\nHost: 127.0.0.1:8787\r\n\r\n";
    try std.testing.expectEqualStrings(code, findQueryParam(req, "code").?);
    try std.testing.expectEqualStrings("abc123", findQueryParam(req, "state").?);
    try std.testing.expect(findQueryParam(req, "missing") == null);
}

test "findQueryParam ignores trailing headers" {
    const req = "GET /callback?code=c1&state=s1 HTTP/1.1\r\nHost: x\r\nCookie: a=b&c=d\r\n\r\n";
    try std.testing.expectEqualStrings("c1", findQueryParam(req, "code").?);
    try std.testing.expectEqualStrings("s1", findQueryParam(req, "state").?);
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
