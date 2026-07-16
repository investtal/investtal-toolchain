const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const TokenSet = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_at_unix: i64 = 0,
    scope: ?[]const u8 = null,
    cloud_id: ?[]const u8 = null,
    owns: bool = false,

    pub fn deinit(self: *TokenSet, allocator: Allocator) void {
        if (!self.owns) return;
        allocator.free(self.access_token);
        if (self.refresh_token) |r| allocator.free(r);
        if (self.scope) |s| allocator.free(s);
        if (self.cloud_id) |c| allocator.free(c);
        self.* = undefined;
    }
};

fn env(key: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(key) orelse return null;
    return std.mem.span(p);
}

pub fn credentialsPath(allocator: Allocator) ![]u8 {
    if (env("XDG_CONFIG_HOME")) |xdg| {
        return try std.fmt.allocPrint(allocator, "{s}/atlassian/credentials.json", .{xdg});
    }
    if (env("HOME")) |home| {
        return try std.fmt.allocPrint(allocator, "{s}/.config/atlassian/credentials.json", .{home});
    }
    return try allocator.dupe(u8, "credentials.json");
}

pub fn saveTokens(allocator: Allocator, io: Io, tokens: TokenSet) !void {
    const path = try credentialsPath(allocator);
    defer allocator.free(path);
    // Ensure parent directories for absolute/relative credential paths.
    if (std.fs.path.dirname(path)) |parent| {
        var i: usize = if (std.fs.path.isAbsolute(parent)) 1 else 0;
        while (i <= parent.len) : (i += 1) {
            if (i != parent.len and parent[i] != '/') continue;
            if (i == 0) continue;
            const segment = parent[0..i];
            Io.Dir.cwd().createDir(io, segment, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }

    const refresh_s = if (tokens.refresh_token) |r|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{r})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(refresh_s);
    const scope_s = if (tokens.scope) |s|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{s})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(scope_s);
    const cloud_s = if (tokens.cloud_id) |c|
        try std.fmt.allocPrint(allocator, "\"{s}\"", .{c})
    else
        try allocator.dupe(u8, "null");
    defer allocator.free(cloud_s);

    const json = try std.fmt.allocPrint(allocator,
        \\{{"access_token":"{s}","refresh_token":{s},"expires_at_unix":{d},"scope":{s},"cloud_id":{s}}}
        \\
    , .{ tokens.access_token, refresh_s, tokens.expires_at_unix, scope_s, cloud_s });
    defer allocator.free(json);

    // Spec: credentials file mode 0600 (owner read/write only).
    try Io.Dir.cwd().writeFile(io, .{
        .sub_path = path,
        .data = json,
        .flags = .{ .permissions = @enumFromInt(0o600) },
    });
}

pub fn loadTokens(allocator: Allocator, io: Io) !?TokenSet {
    const path = try credentialsPath(allocator);
    defer allocator.free(path);
    const content = Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024)) catch return null;
    defer allocator.free(content);

    const access = extract(content, "access_token") orelse return null;
    return TokenSet{
        .access_token = try allocator.dupe(u8, access),
        .refresh_token = if (extract(content, "refresh_token")) |r| try allocator.dupe(u8, r) else null,
        .expires_at_unix = if (extractNum(content, "expires_at_unix")) |n| n else 0,
        .scope = if (extract(content, "scope")) |s| try allocator.dupe(u8, s) else null,
        .cloud_id = if (extract(content, "cloud_id")) |c| try allocator.dupe(u8, c) else null,
        .owns = true,
    };
}

pub fn clearTokens(allocator: Allocator, io: Io) !void {
    const path = try credentialsPath(allocator);
    defer allocator.free(path);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

fn extract(body: []const u8, key: []const u8) ?[]const u8 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = idx + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t' or body[i] == ':')) : (i += 1) {}
    if (i >= body.len) return null;
    if (body[i] == 'n') return null;
    if (body[i] != '"') return null;
    i += 1;
    const start = i;
    while (i < body.len and body[i] != '"') : (i += 1) {
        if (body[i] == '\\' and i + 1 < body.len) i += 1;
    }
    return body[start..i];
}

fn extractNum(body: []const u8, key: []const u8) ?i64 {
    var needle_buf: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "\"{s}\"", .{key}) catch return null;
    const idx = std.mem.indexOf(u8, body, needle) orelse return null;
    var i = idx + needle.len;
    while (i < body.len and (body[i] == ' ' or body[i] == ':' or body[i] == '\t')) : (i += 1) {}
    const start = i;
    while (i < body.len and (body[i] == '-' or (body[i] >= '0' and body[i] <= '9'))) : (i += 1) {}
    if (start == i) return null;
    return std.fmt.parseInt(i64, body[start..i], 10) catch null;
}
