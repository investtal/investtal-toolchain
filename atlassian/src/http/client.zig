const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const http = std.http;
const ApiError = @import("error.zig").ApiError;

pub const Request = struct {
    method: http.Method = .GET,
    url: []const u8,
    /// `Authorization` value (`Bearer …` / `Basic …`); `null` omits the header.
    auth_header: ?[]const u8 = null,
    body: ?[]const u8 = null,
    content_type: []const u8 = "application/json",
};

pub const Response = struct {
    status: u16,
    body: []u8,
    request_id: ?[]const u8 = null,

    pub fn deinit(self: *Response, allocator: Allocator) void {
        allocator.free(self.body);
        if (self.request_id) |r| allocator.free(r);
        self.* = undefined;
    }
};

pub const Result = union(enum) {
    ok: Response,
    err: ApiError,

    pub fn deinit(self: *Result, allocator: Allocator) void {
        switch (self.*) {
            .ok => |*r| r.deinit(allocator),
            .err => |*e| e.deinit(allocator),
        }
    }
};

pub const FakeHop = struct {
    status: u16,
    body: []const u8 = "",
    retry_after: ?[]const u8 = null,
};

pub const Client = struct {
    allocator: Allocator,
    io: Io,
    retries: u8 = 3,
    verbose: bool = false,
    fake_hops: ?[]const FakeHop = null,
    fake_index: usize = 0,

    pub fn request(self: *Client, req: Request) !Result {
        var attempt: u8 = 0;
        var last_status: u16 = 0;
        var last_body: []u8 = &.{};
        var last_body_owned = false;
        defer if (last_body_owned) self.allocator.free(last_body);

        while (attempt < self.retries) : (attempt += 1) {
            if (self.verbose) {
                std.log.info("{s} {s} (attempt {d}/{d})", .{ @tagName(req.method), req.url, attempt + 1, self.retries });
            }

            const hop = try self.oneShot(req);
            last_status = hop.status;
            if (last_body_owned) self.allocator.free(last_body);
            last_body = hop.body;
            last_body_owned = true;

            const is_network = hop.status == 0;
            const retriable = is_network or hop.status == 429 or hop.status == 502 or hop.status == 503 or hop.status == 504;
            if (!retriable) {
                if (hop.status >= 200 and hop.status < 300) {
                    last_body_owned = false;
                    return .{ .ok = .{
                        .status = hop.status,
                        .body = hop.body,
                        .request_id = hop.request_id,
                    } };
                }
                last_body_owned = false;
                const err = try ApiError.fromHttp(self.allocator, hop.status, hop.body, hop.request_id);
                self.allocator.free(hop.body);
                if (hop.request_id) |r| self.allocator.free(r);
                return .{ .err = err };
            }

            if (attempt + 1 >= self.retries) break;

            const delay_ms: u64 = blk: {
                if (hop.retry_after) |ra| {
                    if (std.fmt.parseInt(u64, ra, 10)) |sec| break :blk sec * 1000 else |_| {}
                }
                break :blk @as(u64, 200) * (@as(u64, 1) << @intCast(attempt));
            };
            if (self.fake_hops == null) {
                self.io.sleep(.fromMilliseconds(@intCast(delay_ms)), .awake) catch {};
            }
            self.allocator.free(hop.body);
            if (hop.request_id) |r| self.allocator.free(r);
            last_body_owned = false;
            last_body = &.{};
        }

        if (last_status == 0) {
            const err = try ApiError.network(self.allocator, if (last_body.len > 0) last_body else "network error");
            return .{ .err = err };
        }
        const err = try ApiError.fromHttp(self.allocator, last_status, last_body, null);
        return .{ .err = err };
    }

    const Hop = struct {
        status: u16,
        body: []u8,
        request_id: ?[]const u8 = null,
        retry_after: ?[]const u8 = null,
    };

    fn oneShot(self: *Client, req: Request) !Hop {
        if (self.fake_hops) |hops| {
            if (self.fake_index >= hops.len) return error.FakeExhausted;
            const h = hops[self.fake_index];
            self.fake_index += 1;
            return .{
                .status = h.status,
                .body = try self.allocator.dupe(u8, h.body),
                .retry_after = h.retry_after,
            };
        }

        var client: http.Client = .{ .allocator = self.allocator, .io = self.io };
        defer client.deinit();

        var body_list: std.ArrayList(u8) = .empty;
        errdefer body_list.deinit(self.allocator);
        var body_aw: Io.Writer.Allocating = .fromArrayList(self.allocator, &body_list);
        defer body_aw.deinit();

        const result = client.fetch(.{
            .location = .{ .url = req.url },
            .method = req.method,
            .payload = req.body,
            .response_writer = &body_aw.writer,
            .headers = .{
                .authorization = if (req.auth_header) |auth| .{ .override = auth } else .omit,
                .content_type = if (req.body != null) .{ .override = req.content_type } else .omit,
                .accept_encoding = .omit,
            },
            .extra_headers = &.{
                .{ .name = "Accept", .value = "application/json" },
            },
        }) catch |err| {
            return .{
                .status = 0,
                .body = try std.fmt.allocPrint(self.allocator, "network error: {s}", .{@errorName(err)}),
            };
        };

        const owned = try body_list.toOwnedSlice(self.allocator);
        return .{
            .status = @intFromEnum(result.status),
            .body = owned,
        };
    }
};

test "retry three times on 503" {
    const a = std.testing.allocator;
    const hops = [_]FakeHop{
        .{ .status = 503, .body = "a" },
        .{ .status = 503, .body = "b" },
        .{ .status = 200, .body = "ok" },
    };
    var client: Client = .{
        .allocator = a,
        .io = undefined, // unused with fake_hops
        .retries = 3,
        .fake_hops = &hops,
    };
    var result = try client.request(.{
        .url = "https://example.test/x",
        .auth_header = "Basic x",
    });
    defer result.deinit(a);
    switch (result) {
        .ok => |r| try std.testing.expectEqualStrings("ok", r.body),
        .err => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 3), client.fake_index);
}

test "retry network status 0 then success" {
    const a = std.testing.allocator;
    const hops = [_]FakeHop{
        .{ .status = 0, .body = "network error: Timeout" },
        .{ .status = 200, .body = "ok" },
    };
    var client: Client = .{
        .allocator = a,
        .io = undefined,
        .retries = 3,
        .fake_hops = &hops,
    };
    var result = try client.request(.{
        .url = "https://example.test/x",
        .auth_header = "Basic x",
    });
    defer result.deinit(a);
    switch (result) {
        .ok => |r| try std.testing.expectEqualStrings("ok", r.body),
        .err => return error.TestUnexpectedResult,
    }
}
