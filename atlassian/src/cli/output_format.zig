const std = @import("std");

/// Success-body output modes for API responses.
/// Default is TOON (token-efficient for humans + AI).
pub const OutputFormat = enum {
    toon,
    markdown,
    json,

    pub fn parse(name: []const u8) ?OutputFormat {
        if (std.mem.eql(u8, name, "toon")) return .toon;
        if (std.mem.eql(u8, name, "markdown") or std.mem.eql(u8, name, "md")) return .markdown;
        if (std.mem.eql(u8, name, "json")) return .json;
        return null;
    }

    pub fn isJson(self: OutputFormat) bool {
        return self == .json;
    }
};
