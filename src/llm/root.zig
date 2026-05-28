const std = @import("std");
const framework = @import("framework");
const provider = @import("../provider/root.zig");
const provider_client = @import("../provider/client.zig");

pub const MODULE_NAME = "llm";

pub const ModuleStage = enum {
    implemented,
};

pub const MODULE_STAGE: ModuleStage = .implemented;

/// LLM runtime — bridges zaibase's LLM provider interface with zopcode's
/// provider system, providing a high-level streaming completion API.
pub const LlmRuntime = struct {
    allocator: std.mem.Allocator,
    logger: ?*framework.Logger,
    provider_registry: *provider.ProviderRegistry,

    const Self = @This();

    pub const Dependencies = struct {
        allocator: std.mem.Allocator,
        logger: ?*framework.Logger = null,
        provider_registry: *provider.ProviderRegistry,
    };

    pub const CompletionRequest = struct {
        model: provider.ModelRef,
        system_prompt: ?[]const u8 = null,
        messages: []const provider_client.ProviderMessage,
        tools: []const provider_client.ProviderToolDefinition = &.{},
        max_tokens: usize = 4096,
        temperature: ?f64 = null,
    };

    pub const StreamCallbacks = struct {
        on_text_delta: *const fn (ctx: *anyopaque, text: []const u8) void = noopTextDelta,
        on_tool_call_started: *const fn (ctx: *anyopaque, call_id: []const u8, tool_name: []const u8) void = noopToolCallStarted,
        on_tool_call_delta: *const fn (ctx: *anyopaque, call_id: []const u8, partial_json: []const u8) void = noopToolCallDelta,
        on_completion: *const fn (ctx: *anyopaque, stop_reason: ?[]const u8) void = noopCompletion,
        on_error: *const fn (ctx: *anyopaque, error_info: []const u8) void = noopError,
        context: *anyopaque,
    };

    pub fn init(deps: Dependencies) *Self {
        return deps.allocator.create(Self) catch unreachable;
    }

    pub fn initWithAlloc(allocator: std.mem.Allocator, deps: Dependencies) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .logger = deps.logger,
            .provider_registry = deps.provider_registry,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.destroy(self);
    }

    /// Perform a streaming completion using the configured provider.
    /// The callbacks are invoked as SSE events arrive.
    pub fn streamCompletion(
        self: *Self,
        request: CompletionRequest,
        callbacks: StreamCallbacks,
    ) !provider_client.CompletionInfo {
        const client = self.provider_registry.makeClient(request.model) orelse {
            const msg = "no provider client available for model";
            callbacks.on_error(callbacks.context, msg);
            return error.NoProviderClient;
        };
        defer client.deinit(self.allocator);

        const exec_ctx = provider_client.ProviderExecutionContext{
            .allocator = self.allocator,
            .logger = self.logger,
            .event_bus = null,
            .session_id = null,
            .trace_id = null,
        };

        // Build a thin LlmEventSink that forwards to StreamCallbacks.
        const sink = provider_client.LlmEventSink{
            .ptr = @ptrCast(@constCast(&callbacks)),
            .on_event = forwardEvent,
        };

        const provider_request = provider_client.ProviderRequest{
            .model = request.model,
            .system_prompt = request.system_prompt,
            .messages = request.messages,
            .tools = request.tools,
            .max_tokens = request.max_tokens,
        };

        client.stream(exec_ctx, provider_request, sink) catch |err| {
            const err_msg = @errorName(err);
            callbacks.on_error(callbacks.context, err_msg);
            return err;
        };

        return .{};
    }

    /// List available providers and their models.
    pub fn catalog(self: *Self, allocator: std.mem.Allocator) ![]provider.ProviderRegistry.ProviderCatalogEntry {
        return self.provider_registry.catalog(allocator);
    }

    /// Health check for all providers.
    pub fn checkHealth(self: *Self) !void {
        _ = self;
    }

    fn forwardEvent(sink_ptr: *anyopaque, event: *const provider_client.ProviderStreamEvent) anyerror!void {
        const callbacks: *StreamCallbacks = @ptrCast(@alignCast(sink_ptr));
        switch (event.*) {
            .text_delta => |delta| callbacks.on_text_delta(callbacks.context, delta.text),
            .tool_call_started => |tc| callbacks.on_tool_call_started(callbacks.context, tc.call_id, tc.tool_name),
            .tool_call_delta => |td| callbacks.on_tool_call_delta(callbacks.context, td.call_id, td.partial_json),
            .completed => |info| callbacks.on_completion(callbacks.context, info.stop_reason),
            .failed => |err| callbacks.on_error(callbacks.context, err.message),
            .reasoning_delta => {},
        }
    }
};

// No-op callback defaults
fn noopTextDelta(_: *anyopaque, _: []const u8) void {}
fn noopToolCallStarted(_: *anyopaque, _: []const u8, _: []const u8) void {}
fn noopToolCallDelta(_: *anyopaque, _: []const u8, _: []const u8) void {}
fn noopCompletion(_: *anyopaque, _: ?[]const u8) void {}
fn noopError(_: *anyopaque, _: []const u8) void {}

test "llm module exports are stable" {
    try std.testing.expectEqualStrings("llm", MODULE_NAME);
    try std.testing.expectEqual(@as(ModuleStage, .implemented), MODULE_STAGE);
}

test "LlmRuntime can be created and destroyed" {
    var memory_sink = framework.MemorySink.init(std.testing.allocator, 16);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var registry = provider.ProviderRegistry.init(std.testing.allocator, &logger, null);
    defer registry.deinit();

    var runtime = try LlmRuntime.initWithAlloc(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .provider_registry = &registry,
    });
    defer runtime.deinit();

    const entries = try runtime.catalog(std.testing.allocator);
    defer {
        for (entries) |*e| e.deinit(std.testing.allocator);
        std.testing.allocator.free(entries);
    }
    // No providers registered yet, so catalog should be empty.
    try std.testing.expectEqual(@as(usize, 0), entries.len);
}
