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

const StoredTokens = struct {
    access_token: []const u8,
    refresh_token: ?[]const u8 = null,
    expires_at_unix: i64 = 0,
    scope: ?[]const u8 = null,
    cloud_id: ?[]const u8 = null,
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

fn ensureParentDirs(io: Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        var i: usize = if (std.fs.path.isAbsolute(parent)) 1 else 0;
        while (i <= parent.len) : (i += 1) {
            if (i != parent.len and !std.fs.path.isSep(parent[i])) continue;
            if (i == 0) continue;
            const segment = parent[0..i];
            Io.Dir.cwd().createDir(io, segment, .default_dir) catch |err| switch (err) {
                error.PathAlreadyExists => {},
                else => return err,
            };
        }
    }
}

pub fn saveTokens(allocator: Allocator, io: Io, tokens: TokenSet) !void {
    const path = try credentialsPath(allocator);
    defer allocator.free(path);
    try ensureParentDirs(io, path);

    const payload = StoredTokens{
        .access_token = tokens.access_token,
        .refresh_token = tokens.refresh_token,
        .expires_at_unix = tokens.expires_at_unix,
        .scope = tokens.scope,
        .cloud_id = tokens.cloud_id,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(json);

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

    var parsed = std.json.parseFromSlice(StoredTokens, allocator, content, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
    }) catch return null;
    defer parsed.deinit();

    const v = parsed.value;
    var tokens = TokenSet{
        .access_token = try allocator.dupe(u8, v.access_token),
        .refresh_token = null,
        .expires_at_unix = v.expires_at_unix,
        .scope = null,
        .cloud_id = null,
        .owns = true,
    };
    errdefer tokens.deinit(allocator);
    if (v.refresh_token) |r| tokens.refresh_token = try allocator.dupe(u8, r);
    if (v.scope) |s| tokens.scope = try allocator.dupe(u8, s);
    if (v.cloud_id) |c| tokens.cloud_id = try allocator.dupe(u8, c);
    return tokens;
}

pub fn clearTokens(allocator: Allocator, io: Io) !void {
    const path = try credentialsPath(allocator);
    defer allocator.free(path);
    Io.Dir.cwd().deleteFile(io, path) catch {};
}

test "saveTokens json escapes special chars in token" {
    const payload = StoredTokens{
        .access_token = "a\"b\\c",
        .refresh_token = null,
        .expires_at_unix = 42,
        .scope = null,
        .cloud_id = null,
    };
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, payload, .{});
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"") != null or std.mem.indexOf(u8, json, "\\\\") != null);
    var parsed = try std.json.parseFromSlice(StoredTokens, std.testing.allocator, json, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    try std.testing.expectEqualStrings("a\"b\\c", parsed.value.access_token);
}
