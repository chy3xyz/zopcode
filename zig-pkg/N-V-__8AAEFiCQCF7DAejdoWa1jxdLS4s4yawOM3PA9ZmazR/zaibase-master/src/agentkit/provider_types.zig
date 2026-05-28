const std = @import("std");

pub const ProviderDefinition = struct {
    id: []const u8,
    label: []const u8,
    default_model: []const u8,
    supports_streaming: bool = false,
    supports_tools: bool = false,
};

pub const ProviderHealthState = enum {
    ready,
    needs_auth,
    degraded,
    unavailable,

    pub fn asText(self: ProviderHealthState) []const u8 {
        return switch (self) {
            .ready => "ready",
            .needs_auth => "needs_auth",
            .degraded => "degraded",
            .unavailable => "unavailable",
        };
    }
};

pub const ProviderHealth = struct {
    provider_id: []const u8,
    state: ProviderHealthState,
    message: ?[]const u8 = null,
};

pub const ProviderModelInfo = struct {
    id: []const u8,
    label: []const u8,
    supports_streaming: bool = false,
    supports_tools: bool = false,
};

test "provider substrate types are stable" {
    const definition = ProviderDefinition{
        .id = "demo",
        .label = "Demo Provider",
        .default_model = "demo-model",
        .supports_streaming = true,
    };
    const health = ProviderHealth{
        .provider_id = "demo",
        .state = .ready,
    };
    const model = ProviderModelInfo{
        .id = "demo-model",
        .label = "Demo Model",
        .supports_streaming = true,
    };

    try std.testing.expectEqualStrings("demo", definition.id);
    try std.testing.expectEqualStrings("ready", health.state.asText());
    try std.testing.expectEqualStrings("demo-model", model.id);
}


