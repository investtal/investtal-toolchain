const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const transport = @import("../http/transport.zig");

pub const AuthMode = enum { basic, oauth };

pub const Config = struct {
    url: ?[]const u8 = null,
    username: ?[]const u8 = null,
    api_token: ?[]const u8 = null,
    cloud: bool = true,
    org_id: ?[]const u8 = null,
    cloud_id: ?[]const u8 = null,
    auth_mode: AuthMode = .basic,
    oauth_client_id: ?[]const u8 = null,
    oauth_client_secret: ?[]const u8 = null,
    http_retries: u8 = 3,
    source_path: ?[]const u8 = null,
    owns: bool = false,

    pub fn deinit(self: *Config, allocator: Allocator) void {
        if (!self.owns) return;
        if (self.url) |v| allocator.free(v);
        if (self.username) |v| allocator.free(v);
        if (self.api_token) |v| allocator.free(v);
        if (self.org_id) |v| allocator.free(v);
        if (self.cloud_id) |v| allocator.free(v);
        if (self.oauth_client_id) |v| allocator.free(v);
        if (self.oauth_client_secret) |v| allocator.free(v);
        if (self.source_path) |v| allocator.free(v);
        self.* = .{};
    }

    pub fn site(self: Config) !transport.Site {
        const url = self.url orelse return error.MissingUrl;
        return .{
            .kind = if (self.cloud) .cloud else .server_dc,
            .base_url = url,
            .cloud_id = self.cloud_id,
            .auth_mode = switch (self.auth_mode) {
                .basic => .basic,
                .oauth => .oauth,
            },
        };
    }
};

fn env(key: [*:0]const u8) ?[]const u8 {
    const p = std.c.getenv(key) orelse return null;
    return std.mem.span(p);
}

pub fn resolvedPath(allocator: Allocator, override_path: ?[]const u8) ![]u8 {
    if (override_path) |p| return try allocator.dupe(u8, p);
    if (env("ATLASSIAN_CONFIG")) |p| return try allocator.dupe(u8, p);

    if (env("XDG_CONFIG_HOME")) |xdg| {
        return try std.fmt.allocPrint(allocator, "{s}/atlassian/config.toml", .{xdg});
    }
    if (env("HOME")) |home| {
        return try std.fmt.allocPrint(allocator, "{s}/.config/atlassian/config.toml", .{home});
    }
    return try allocator.dupe(u8, "atlassian-config.toml");
}

fn fileExists(io: Io, path: []const u8) bool {
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

pub fn load(allocator: Allocator, io: Io, override_path: ?[]const u8) !Config {
    var cfg: Config = .{ .owns = true };
    errdefer cfg.deinit(allocator);

    const path = try resolvedPath(allocator, override_path);
    cfg.source_path = path;

    if (fileExists(io, path)) {
        const content = try Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(content);
        try parseFile(&cfg, allocator, content);
    }

    try applyEnv(&cfg, allocator);
    return cfg;
}

fn applyEnv(cfg: *Config, allocator: Allocator) !void {
    if (env("ATLASSIAN_URL")) |v| {
        if (cfg.url) |old| allocator.free(old);
        cfg.url = try allocator.dupe(u8, v);
    }
    if (env("ATLASSIAN_USERNAME")) |v| {
        if (cfg.username) |old| allocator.free(old);
        cfg.username = try allocator.dupe(u8, v);
    }
    if (env("ATLASSIAN_API_TOKEN")) |v| {
        if (cfg.api_token) |old| allocator.free(old);
        cfg.api_token = try allocator.dupe(u8, v);
    }
    if (env("ATLASSIAN_CLOUD")) |v| cfg.cloud = parseBool(v);
    if (env("ATLASSIAN_ORG_ID")) |v| {
        if (cfg.org_id) |old| allocator.free(old);
        cfg.org_id = try allocator.dupe(u8, v);
    }
    if (env("ATLASSIAN_CLOUD_ID")) |v| {
        if (cfg.cloud_id) |old| allocator.free(old);
        cfg.cloud_id = try allocator.dupe(u8, v);
    }
    if (env("ATLASSIAN_AUTH")) |v| {
        if (std.ascii.eqlIgnoreCase(v, "oauth")) cfg.auth_mode = .oauth else cfg.auth_mode = .basic;
    }
    if (env("ATLASSIAN_OAUTH_CLIENT_ID")) |v| {
        if (cfg.oauth_client_id) |old| allocator.free(old);
        cfg.oauth_client_id = try allocator.dupe(u8, v);
    }
    if (env("ATLASSIAN_OAUTH_CLIENT_SECRET")) |v| {
        if (cfg.oauth_client_secret) |old| allocator.free(old);
        cfg.oauth_client_secret = try allocator.dupe(u8, v);
    }
    if (env("ATLASSIAN_HTTP_RETRIES")) |v| {
        cfg.http_retries = std.fmt.parseInt(u8, v, 10) catch cfg.http_retries;
    }
}

fn parseBool(v: []const u8) bool {
    return !(std.ascii.eqlIgnoreCase(v, "false") or std.mem.eql(u8, v, "0") or std.ascii.eqlIgnoreCase(v, "no"));
}

fn parseFile(cfg: *Config, allocator: Allocator, content: []const u8) !void {
    var section: enum { root, oauth, http } = .root;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        if (line[0] == '[') {
            if (std.mem.eql(u8, line, "[oauth]")) section = .oauth else if (std.mem.eql(u8, line, "[http]")) section = .http else section = .root;
            continue;
        }
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        var val = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (val.len >= 2 and val[0] == '"' and val[val.len - 1] == '"') {
            val = val[1 .. val.len - 1];
        }

        switch (section) {
            .root => {
                if (std.mem.eql(u8, key, "atlassianUrl")) {
                    if (cfg.url) |old| allocator.free(old);
                    cfg.url = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "atlassianUsername")) {
                    if (cfg.username) |old| allocator.free(old);
                    cfg.username = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "atlassianApiToken")) {
                    if (cfg.api_token) |old| allocator.free(old);
                    cfg.api_token = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "atlassianCloud")) {
                    cfg.cloud = parseBool(val);
                } else if (std.mem.eql(u8, key, "orgId")) {
                    if (cfg.org_id) |old| allocator.free(old);
                    cfg.org_id = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "cloudId")) {
                    if (cfg.cloud_id) |old| allocator.free(old);
                    cfg.cloud_id = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "auth")) {
                    if (std.ascii.eqlIgnoreCase(val, "oauth")) cfg.auth_mode = .oauth else cfg.auth_mode = .basic;
                }
            },
            .oauth => {
                if (std.mem.eql(u8, key, "clientId")) {
                    if (cfg.oauth_client_id) |old| allocator.free(old);
                    cfg.oauth_client_id = try allocator.dupe(u8, val);
                } else if (std.mem.eql(u8, key, "clientSecret")) {
                    if (cfg.oauth_client_secret) |old| allocator.free(old);
                    cfg.oauth_client_secret = try allocator.dupe(u8, val);
                }
            },
            .http => {
                if (std.mem.eql(u8, key, "retries")) {
                    cfg.http_retries = std.fmt.parseInt(u8, val, 10) catch cfg.http_retries;
                }
            },
        }
    }
}

fn ensureParentDirs(io: Io, path: []const u8) !void {
    const parent = std.fs.path.dirname(path) orelse return;
    if (parent.len == 0 or std.mem.eql(u8, parent, "/") or std.mem.eql(u8, parent, ".")) return;

    // Create intermediate directories one by one (works for absolute paths).
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

pub fn save(allocator: Allocator, io: Io, cfg: Config, path: []const u8) !void {
    try ensureParentDirs(io, path);
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var aw: Io.Writer.Allocating = .fromArrayList(allocator, &list);
    defer aw.deinit();
    const w = &aw.writer;
    if (cfg.url) |v| try w.print("atlassianUrl = \"{s}\"\n", .{v});
    if (cfg.username) |v| try w.print("atlassianUsername = \"{s}\"\n", .{v});
    if (cfg.api_token) |v| try w.print("atlassianApiToken = \"{s}\"\n", .{v});
    try w.print("atlassianCloud = {s}\n", .{if (cfg.cloud) "true" else "false"});
    if (cfg.org_id) |v| try w.print("orgId = \"{s}\"\n", .{v});
    if (cfg.cloud_id) |v| try w.print("cloudId = \"{s}\"\n", .{v});
    try w.print("auth = \"{s}\"\n", .{@tagName(cfg.auth_mode)});
    try w.print("\n[oauth]\n", .{});
    if (cfg.oauth_client_id) |v| try w.print("clientId = \"{s}\"\n", .{v});
    if (cfg.oauth_client_secret) |v| try w.print("clientSecret = \"{s}\"\n", .{v});
    try w.print("\n[http]\n", .{});
    try w.print("retries = {d}\n", .{cfg.http_retries});
    try w.flush();

    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = aw.written() });
}

pub fn setKey(cfg: *Config, allocator: Allocator, key: []const u8, value: []const u8) !void {
    const assign = struct {
        fn put(field: *?[]const u8, a: Allocator, v: []const u8) !void {
            if (field.*) |old| a.free(old);
            field.* = try a.dupe(u8, v);
        }
    }.put;

    if (std.mem.eql(u8, key, "atlassianUrl") or std.mem.eql(u8, key, "url")) {
        try assign(&cfg.url, allocator, value);
    } else if (std.mem.eql(u8, key, "atlassianUsername") or std.mem.eql(u8, key, "username")) {
        try assign(&cfg.username, allocator, value);
    } else if (std.mem.eql(u8, key, "atlassianApiToken") or std.mem.eql(u8, key, "apiToken")) {
        try assign(&cfg.api_token, allocator, value);
    } else if (std.mem.eql(u8, key, "atlassianCloud") or std.mem.eql(u8, key, "cloud")) {
        cfg.cloud = parseBool(value);
    } else if (std.mem.eql(u8, key, "orgId")) {
        try assign(&cfg.org_id, allocator, value);
    } else if (std.mem.eql(u8, key, "cloudId")) {
        try assign(&cfg.cloud_id, allocator, value);
    } else if (std.mem.eql(u8, key, "auth")) {
        if (std.ascii.eqlIgnoreCase(value, "oauth")) cfg.auth_mode = .oauth else cfg.auth_mode = .basic;
    } else if (std.mem.eql(u8, key, "oauth.clientId") or std.mem.eql(u8, key, "clientId")) {
        try assign(&cfg.oauth_client_id, allocator, value);
    } else if (std.mem.eql(u8, key, "oauth.clientSecret") or std.mem.eql(u8, key, "clientSecret")) {
        try assign(&cfg.oauth_client_secret, allocator, value);
    } else if (std.mem.eql(u8, key, "http.retries") or std.mem.eql(u8, key, "retries")) {
        cfg.http_retries = try std.fmt.parseInt(u8, value, 10);
    } else {
        return error.UnknownKey;
    }
}

pub fn getKey(cfg: Config, key: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, key, "atlassianUrl") or std.mem.eql(u8, key, "url")) return cfg.url;
    if (std.mem.eql(u8, key, "atlassianUsername") or std.mem.eql(u8, key, "username")) return cfg.username;
    if (std.mem.eql(u8, key, "atlassianApiToken") or std.mem.eql(u8, key, "apiToken")) {
        if (cfg.api_token) |t| if (t.len > 0) return "***";
        return cfg.api_token;
    }
    if (std.mem.eql(u8, key, "orgId")) return cfg.org_id;
    if (std.mem.eql(u8, key, "cloudId")) return cfg.cloud_id;
    if (std.mem.eql(u8, key, "auth")) return @tagName(cfg.auth_mode);
    return null;
}

test "parse retries default 3" {
    const cfg = Config{};
    try std.testing.expectEqual(@as(u8, 3), cfg.http_retries);
}

test "parse file atlassianUrl" {
    var cfg: Config = .{ .owns = true };
    defer cfg.deinit(std.testing.allocator);
    try parseFile(&cfg, std.testing.allocator, "atlassianUrl = \"https://file.example\"\n[http]\nretries = 5\n");
    try std.testing.expectEqualStrings("https://file.example", cfg.url.?);
    try std.testing.expectEqual(@as(u8, 5), cfg.http_retries);
}
