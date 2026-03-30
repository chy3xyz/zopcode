const std = @import("std");
const model = @import("model.zig");

pub const AuthKind = enum {
    none,
    api_key,

    pub fn asText(self: AuthKind) []const u8 {
        return switch (self) {
            .none => "none",
            .api_key => "api_key",
        };
    }
};

pub const ProviderInfo = struct {
    id: []const u8,
    display_name: []const u8,
    default_model: model.ModelRef,
    models: []const model.ModelInfo = &.{},
    auth_kind: AuthKind = .none,
};

test "provider info keeps stable ids" {
    const info = ProviderInfo{
        .id = "anthropic",
        .display_name = "Anthropic",
        .default_model = .{
            .provider_id = "anthropic",
            .model_id = "claude-sonnet-4-5",
        },
        .auth_kind = .api_key,
    };

    try std.testing.expectEqualStrings("anthropic", info.id);
    try std.testing.expectEqualStrings("Anthropic", info.display_name);
}
