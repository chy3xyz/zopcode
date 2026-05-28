const std = @import("std");

pub const MODULE_NAME = "agentkit";
pub const provider_types = @import("provider_types.zig");
pub const provider_registry = @import("provider_registry.zig");
pub const llm_provider = @import("llm_provider.zig");
pub const runtime = @import("runtime.zig");

pub const ProviderDefinition = provider_types.ProviderDefinition;
pub const ProviderHealth = provider_types.ProviderHealth;
pub const ProviderHealthState = provider_types.ProviderHealthState;
pub const ProviderModelInfo = provider_types.ProviderModelInfo;
pub const ProviderRegistry = provider_registry.ProviderRegistry;

pub const LlmProvider = llm_provider.LlmProvider;
pub const Message = llm_provider.Message;
pub const ToolCall = llm_provider.ToolCall;
pub const TokenUsage = llm_provider.TokenUsage;
pub const CompletionRequest = llm_provider.CompletionRequest;
pub const CompletionResponse = llm_provider.CompletionResponse;
pub const StreamCallback = llm_provider.StreamCallback;
pub const ToolSchema = llm_provider.ToolSchema;

pub const AgentRuntime = runtime.AgentRuntime;
pub const RuntimeConfig = runtime.RuntimeConfig;
pub const IterationBudget = runtime.IterationBudget;
pub const ContextWindow = runtime.ContextWindow;
pub const CallbackSurface = runtime.CallbackSurface;
pub const FallbackChain = runtime.FallbackChain;
pub const ToolExecutor = runtime.ToolExecutor;
pub const TurnResult = runtime.TurnResult;

pub const ModuleStage = enum { scaffold };
pub const MODULE_STAGE: ModuleStage = .scaffold;

test {
    std.testing.refAllDecls(@This());
}

test "agentkit scaffold exports are stable" {
    try std.testing.expectEqualStrings("agentkit", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);
    try std.testing.expectEqualStrings("ready", ProviderHealthState.ready.asText());
}
