const std = @import("std");
const Allocator = std.mem.Allocator;
const config_mod = @import("../config/root.zig");
const store = @import("store.zig");

pub const AuthContext = struct {
    kind: config_mod.AuthMode,
    username: ?[]const u8 = null,
    api_token: ?[]const u8 = null,
    access_token: ?[]const u8 = null,

    pub fn authorizationHeader(self: AuthContext, allocator: Allocator) ![]u8 {
        return switch (self.kind) {
            .basic => blk: {
                const user = self.username orelse return error.MissingCredentials;
                const token = self.api_token orelse return error.MissingCredentials;
                var plain_buf: [512]u8 = undefined;
                const plain = try std.fmt.bufPrint(&plain_buf, "{s}:{s}", .{ user, token });
                var enc_buf: [1024]u8 = undefined;
                const enc_len = std.base64.standard.Encoder.calcSize(plain.len);
                if (enc_len > enc_buf.len) return error.CredentialsTooLong;
                const enc = enc_buf[0..enc_len];
                _ = std.base64.standard.Encoder.encode(enc, plain);
                break :blk try std.fmt.allocPrint(allocator, "Basic {s}", .{enc});
            },
            .oauth => blk: {
                const tok = self.access_token orelse return error.MissingCredentials;
                break :blk try std.fmt.allocPrint(allocator, "Bearer {s}", .{tok});
            },
        };
    }
};

pub fn fromConfig(cfg: config_mod.Config, tokens: ?store.TokenSet) AuthContext {
    if (cfg.auth_mode == .oauth) {
        if (tokens) |t| {
            return .{
                .kind = .oauth,
                .access_token = t.access_token,
                .username = cfg.username,
                .api_token = cfg.api_token,
            };
        }
    }
    return .{
        .kind = .basic,
        .username = cfg.username,
        .api_token = cfg.api_token,
    };
}

test "basic header encoding" {
    const h = try (AuthContext{ .kind = .basic, .username = "a@b.c", .api_token = "tok" }).authorizationHeader(std.testing.allocator);
    defer std.testing.allocator.free(h);
    try std.testing.expect(std.mem.startsWith(u8, h, "Basic "));
}
