const std = @import("std");

pub const EffectRequestContext = struct {
    request_id: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
};

pub const EffectStatus = enum {
    success,
    failed,

    pub fn asText(self: EffectStatus) []const u8 {
        return switch (self) {
            .success => "success",
            .failed => "failed",
        };
    }
};

pub const EffectResultContext = struct {
    status: EffectStatus = .success,
    duration_ms: ?u64 = null,
};

pub const EffectErrorCategory = enum {
    invalid_input,
    io,
    timeout,
    unavailable,
    external,
    internal,

    pub fn asText(self: EffectErrorCategory) []const u8 {
        return switch (self) {
            .invalid_input => "invalid_input",
            .io => "io",
            .timeout => "timeout",
            .unavailable => "unavailable",
            .external => "external",
            .internal => "internal",
        };
    }
};

pub const EffectErrorInfo = struct {
    category: EffectErrorCategory,
    code: []const u8,
    message: ?[]const u8 = null,
    retriable: bool = false,
};

test "effect types are stable" {
    const request = EffectRequestContext{
        .request_id = "req_01",
        .trace_id = "trc_01",
        .timeout_ms = 1500,
    };
    const result = EffectResultContext{
        .status = .success,
        .duration_ms = 12,
    };
    const err = EffectErrorInfo{
        .category = .timeout,
        .code = "EFFECT_TIMEOUT",
        .message = "request timed out",
        .retriable = true,
    };

    try std.testing.expectEqualStrings("req_01", request.request_id.?);
    try std.testing.expectEqualStrings("success", result.status.asText());
    try std.testing.expectEqualStrings("timeout", err.category.asText());
    try std.testing.expectEqualStrings("EFFECT_TIMEOUT", err.code);
    try std.testing.expect(err.retriable);
}


