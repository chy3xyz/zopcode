//! LLM Provider vtable interface.
//! Based on hermes-zig/src/llm/interface.zig — kept compatible.
const std = @import("std");

pub const Message = struct {
    role: Role,
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    tool_call_id: ?[]const u8 = null,

    pub const Role = enum { system, user, assistant, tool };
};

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

pub const TokenUsage = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    pub fn total(self: TokenUsage) u32 {
        return self.prompt_tokens + self.completion_tokens;
    }
};

pub const ToolSchema = struct {
    name: []const u8,
    description: []const u8,
    parameters_schema: []const u8,
};

pub const CompletionRequest = struct {
    model: []const u8,
    messages: []const Message,
    tools: ?[]const ToolSchema = null,
    temperature: f32 = 0.7,
    max_tokens: ?u32 = null,
    stream: bool = false,
};

pub const CompletionResponse = struct {
    content: ?[]const u8 = null,
    tool_calls: ?[]const ToolCall = null,
    usage: TokenUsage = .{},
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *CompletionResponse) void {
        self.arena.deinit();
    }
};

pub const StreamCallback = struct {
    ctx: *anyopaque,
    on_delta: *const fn (ctx: *anyopaque, content: []const u8, done: bool) void,
};

/// LLM Provider vtable — implement this for each provider (Anthropic, OpenAI, etc.)
pub const LlmProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        complete: *const fn (ptr: *anyopaque, request: CompletionRequest) anyerror!CompletionResponse,
        completeStream: *const fn (ptr: *anyopaque, request: CompletionRequest, callback: StreamCallback) anyerror!CompletionResponse,
        name: *const fn (ptr: *anyopaque) []const u8,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn complete(self: LlmProvider, request: CompletionRequest) !CompletionResponse {
        return self.vtable.complete(self.ptr, request);
    }

    pub fn completeStream(self: LlmProvider, request: CompletionRequest, callback: StreamCallback) !CompletionResponse {
        return self.vtable.completeStream(self.ptr, request, callback);
    }

    pub fn getName(self: LlmProvider) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn deinit(self: LlmProvider) void {
        self.vtable.deinit(self.ptr);
    }
};

test "TokenUsage total" {
    const u = TokenUsage{ .prompt_tokens = 100, .completion_tokens = 50 };
    try std.testing.expectEqual(@as(u32, 150), u.total());
}

test "Message role enum" {
    const msg = Message{ .role = .assistant, .content = "hello" };
    try std.testing.expect(msg.role == .assistant);
}
