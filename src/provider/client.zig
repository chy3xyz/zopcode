const std = @import("std");
const framework = @import("framework");
const model = @import("model.zig");

pub const ProviderRequest = struct {
    request_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    model: model.ModelRef,
    system_prompt: ?[]const u8 = null,
    messages: []const model.ProviderMessage,
    tools: []const model.ProviderToolDefinition = &.{},
    max_tokens: usize,
};

pub const TextDelta = struct {
    text: []const u8,
};

pub const ToolCallStarted = struct {
    call_id: []const u8,
    tool_name: []const u8,
};

pub const ToolCallDelta = struct {
    call_id: []const u8,
    partial_json: []const u8,
};

pub const ToolCallCompleted = struct {
    call_id: []const u8,
    tool_name: []const u8,
    input_json: []const u8,
};

pub const CompletionInfo = struct {
    stop_reason: ?[]const u8 = null,
};

pub const ProviderFailure = struct {
    code: []const u8,
    message: []const u8,
    retryable: bool = false,
};

pub const ProviderStreamEvent = union(enum) {
    text_delta: TextDelta,
    reasoning_delta: TextDelta,
    tool_call_started: ToolCallStarted,
    tool_call_delta: ToolCallDelta,
    tool_call_completed: ToolCallCompleted,
    completed: CompletionInfo,
    failed: ProviderFailure,
};

pub const LlmEventSink = struct {
    ptr: *anyopaque,
    on_event: *const fn (ptr: *anyopaque, event: *const ProviderStreamEvent) anyerror!void,

    pub fn onEvent(self: LlmEventSink, event: *const ProviderStreamEvent) anyerror!void {
        return self.on_event(self.ptr, event);
    }
};

pub const ProviderExecutionContext = struct {
    allocator: std.mem.Allocator,
    logger: ?*framework.Logger = null,
    event_bus: ?framework.EventBus = null,
    request_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
};

pub const ProviderClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        stream: *const fn (ptr: *anyopaque, ctx: ProviderExecutionContext, request: ProviderRequest, sink: LlmEventSink) anyerror!void,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn stream(self: ProviderClient, ctx: ProviderExecutionContext, request: ProviderRequest, sink: LlmEventSink) anyerror!void {
        return self.vtable.stream(self.ptr, ctx, request, sink);
    }

    pub fn deinit(self: ProviderClient, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

test "provider request keeps messages and tools" {
    const messages = [_]model.ProviderMessage{
        .{ .role = .user, .content = "hello" },
    };
    const tools = [_]model.ProviderToolDefinition{
        .{ .name = "read_file", .description = "Read a file", .input_schema_json = "{\"type\":\"object\"}" },
    };
    const request = ProviderRequest{
        .model = .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4-5" },
        .messages = messages[0..],
        .tools = tools[0..],
        .max_tokens = 1024,
    };

    try std.testing.expectEqual(@as(usize, 1), request.messages.len);
    try std.testing.expectEqual(@as(usize, 1), request.tools.len);
}
