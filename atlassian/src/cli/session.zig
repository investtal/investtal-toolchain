const std = @import("std");
const Io = std.Io;

const flags = @import("flags.zig");
const config_mod = @import("../config/root.zig");
const auth_mod = @import("../auth/root.zig");
const auth_store = @import("../auth/store.zig");
const auth_oauth = @import("../auth/oauth.zig");
const http_client = @import("../http/client.zig");
const transport = @import("../http/transport.zig");
const render = @import("render.zig");
const exit_codes = @import("exit_codes.zig");

pub const Session = struct {
    cfg: config_mod.Config,
    site: transport.Site,
    auth_header: []u8,
    client: http_client.Client,
    tokens: ?auth_store.TokenSet = null,

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        allocator.free(self.auth_header);
        self.cfg.deinit(allocator);
        if (self.tokens) |*t| t.deinit(allocator);
    }
};

pub fn openSession(allocator: std.mem.Allocator, io: Io, global: flags.Global) !Session {
    var cfg = try config_mod.load(allocator, io, global.config_path);
    errdefer cfg.deinit(allocator);
    var tokens = auth_store.loadTokens(allocator, io) catch null;
    errdefer if (tokens) |*t| t.deinit(allocator);

    if (cfg.auth_mode == .oauth) {
        if (tokens) |*t| {
            const now = Io.Clock.real.now(io).toSeconds();
            if (t.refresh_token) |rt| {
                if (t.expires_at_unix < now + 120) {
                    if (cfg.oauth_client_id) |cid| {
                        if (cfg.oauth_client_secret) |sec| {
                            var client: http_client.Client = .{ .allocator = allocator, .io = io, .retries = cfg.http_retries };
                            if (auth_oauth.refresh(&client, allocator, cid, sec, rt)) |new_t| {
                                var nt = new_t;
                                if (t.cloud_id) |c| {
                                    nt.cloud_id = allocator.dupe(u8, c) catch null;
                                }
                                auth_store.saveTokens(allocator, io, nt) catch {};
                                t.deinit(allocator);
                                tokens = nt;
                            } else |_| {}
                        }
                    }
                }
            }
        }
    }

    if (cfg.cloud_id == null) {
        if (tokens) |t| {
            if (t.cloud_id) |cid| {
                cfg.cloud_id = try allocator.dupe(u8, cid);
            }
        }
    }
    const auth_ctx = auth_mod.fromConfig(cfg, tokens);
    const header = auth_ctx.authorizationHeader(allocator) catch return error.MissingCredentials;
    errdefer allocator.free(header);
    const site = cfg.site() catch return error.MissingUrl;

    const out: Session = .{
        .cfg = cfg,
        .site = site,
        .auth_header = header,
        .client = .{
            .allocator = allocator,
            .io = io,
            .retries = cfg.http_retries,
            .verbose = global.verbose,
        },
        .tokens = tokens,
    };
    // Transfer ownership to Session; suppress errdefer free of tokens.
    tokens = null;
    return out;
}
