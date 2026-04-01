const std = @import("std");

pub const MODULE_NAME = "provider";

pub const model = @import("model.zig");
pub const provider = @import("provider.zig");
pub const client = @import("client.zig");
pub const registry = @import("registry.zig");
pub const auth = @import("auth.zig");
pub const transform = @import("transform.zig");
pub const builtin = struct {
    pub const anthropic = @import("builtin/anthropic.zig");
    pub const openai = @import("builtin/openai.zig");
};

pub const ModelRef = model.ModelRef;
pub const ModelInfo = model.ModelInfo;
pub const ProviderMessageRole = model.ProviderMessageRole;
pub const ProviderMessage = model.ProviderMessage;
pub const ProviderToolDefinition = model.ProviderToolDefinition;
pub const AuthKind = provider.AuthKind;
pub const ProviderInfo = provider.ProviderInfo;
pub const loadAnthropicApiKey = auth.loadAnthropicApiKey;
pub const loadOpenAIApiKey = auth.loadOpenAIApiKey;
pub const ProviderAuthRuntime = auth.ProviderAuthRuntime;
pub const ProviderAuthStatus = auth.ProviderAuthStatus;
pub const ProviderRequest = client.ProviderRequest;
pub const ProviderFailure = client.ProviderFailure;
pub const ProviderStreamEvent = client.ProviderStreamEvent;
pub const LlmEventSink = client.LlmEventSink;
pub const ProviderExecutionContext = client.ProviderExecutionContext;
pub const ProviderClient = client.ProviderClient;
pub const ProviderRegistry = registry.ProviderRegistry;

test {
    std.testing.refAllDecls(@This());
}

test "provider module scaffold exports are available" {
    try std.testing.expectEqualStrings("provider", MODULE_NAME);
}
