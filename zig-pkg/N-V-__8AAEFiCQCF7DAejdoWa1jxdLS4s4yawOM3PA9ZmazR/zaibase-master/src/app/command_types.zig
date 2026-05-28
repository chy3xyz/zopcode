const std = @import("std");
const core = @import("../core/root.zig");

pub const ValidationField = core.validation.ValidationField;

pub const Authority = enum(u8) {
    public,
    operator,
    admin,

    pub fn asText(self: Authority) []const u8 {
        return switch (self) {
            .public => "public",
            .operator => "operator",
            .admin => "admin",
        };
    }

    pub fn allows(granted: Authority, required: Authority) bool {
        return @intFromEnum(granted) >= @intFromEnum(required);
    }
};

pub const RequestSource = enum {
    cli,
    bridge,
    http,
    service,
    @"test",
};

pub const CommandExecutionMode = enum {
    sync,
    async_task,
};

pub const CommandRequest = struct {
    request_id: []const u8,
    method: []const u8,
    params: []const ValidationField,
    source: RequestSource,
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    authority: Authority = .public,
    timeout_ms: ?u32 = null,
};

pub const RequestContext = struct {
    request_id: []const u8,
    trace_id: ?[]const u8 = null,
    span_id: ?[]const u8 = null,
    source: RequestSource,
    authority: Authority,
    timeout_ms: ?u32 = null,
};

test "authority ordering is stable" {
    try std.testing.expect(Authority.allows(.admin, .operator));
    try std.testing.expect(Authority.allows(.operator, .public));
    try std.testing.expect(!Authority.allows(.public, .admin));
}


