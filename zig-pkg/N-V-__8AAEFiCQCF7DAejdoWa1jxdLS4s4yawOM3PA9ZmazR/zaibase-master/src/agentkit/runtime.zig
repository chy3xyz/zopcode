//! Agent Runtime — generic agent execution loop.
const std = @import("std");
const llm = @import("llm_provider.zig");

pub const Message = llm.Message;
pub const ToolCall = llm.ToolCall;

pub const IterationBudget = struct {
    max_iterations: u32 = 90,
    current: u32 = 0,

    pub fn exhausted(self: IterationBudget) bool {
        return self.current >= self.max_iterations;
    }

    pub fn tick(self: *IterationBudget) void {
        self.current += 1;
    }

    pub fn remaining(self: IterationBudget) u32 {
        if (self.current >= self.max_iterations) return 0;
        return self.max_iterations - self.current;
    }
};

pub const ContextWindow = struct {
    max_tokens: u32,
    used_tokens: u32 = 0,
    compression_threshold: f32 = 0.5,

    pub fn usageRatio(self: ContextWindow) f32 {
        if (self.max_tokens == 0) return 0;
        return @as(f32, @floatFromInt(self.used_tokens)) / @as(f32, @floatFromInt(self.max_tokens));
    }

    pub fn needsCompression(self: ContextWindow) bool {
        return self.usageRatio() >= self.compression_threshold;
    }
};

pub const CallbackSurface = struct {
    ctx: ?*anyopaque = null,
    on_tool_progress: ?*const fn (ctx: *anyopaque, tool_name: []const u8, started: bool) void = null,
    on_thinking: ?*const fn (ctx: *anyopaque, thinking: bool) void = null,
    on_stream_delta: ?*const fn (ctx: *anyopaque, content: []const u8, done: bool) void = null,
    on_step: ?*const fn (ctx: *anyopaque, iteration: u32) void = null,

    pub fn toolProgress(self: CallbackSurface, tool_name: []const u8, started: bool) void {
        if (self.on_tool_progress) |cb| if (self.ctx) |c| cb(c, tool_name, started);
    }
    pub fn thinking(self: CallbackSurface, is_thinking: bool) void {
        if (self.on_thinking) |cb| if (self.ctx) |c| cb(c, is_thinking);
    }
    pub fn streamDelta(self: CallbackSurface, content: []const u8, done: bool) void {
        if (self.on_stream_delta) |cb| if (self.ctx) |c| cb(c, content, done);
    }
    pub fn step(self: CallbackSurface, iteration: u32) void {
        if (self.on_step) |cb| if (self.ctx) |c| cb(c, iteration);
    }
};

pub const FallbackChain = struct {
    providers: []const llm.LlmProvider,
    current_index: usize = 0,

    pub fn current(self: FallbackChain) ?llm.LlmProvider {
        if (self.providers.len == 0) return null;
        return self.providers[self.current_index];
    }
    pub fn advance(self: *FallbackChain) bool {
        if (self.current_index + 1 < self.providers.len) {
            self.current_index += 1;
            return true;
        }
        return false;
    }
    pub fn reset(self: *FallbackChain) void {
        self.current_index = 0;
    }
};

pub const ToolExecutor = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, tool_name: []const u8, arguments: []const u8) anyerror![]const u8,
    };

    pub fn execute(self: ToolExecutor, tool_name: []const u8, arguments: []const u8) ![]const u8 {
        return self.vtable.execute(self.ptr, tool_name, arguments);
    }
};

pub const TurnResult = enum { text_response, tool_calls_pending, budget_exhausted, provider_error };

pub const RuntimeConfig = struct {
    budget: IterationBudget = .{},
    context_window: ContextWindow = .{ .max_tokens = 200_000 },
    callbacks: CallbackSurface = .{},
    stream: bool = false,
};

pub const AgentRuntime = struct {
    allocator: std.mem.Allocator,
    provider: llm.LlmProvider,
    tool_executor: ?ToolExecutor = null,
    config: RuntimeConfig,

    pub fn init(allocator: std.mem.Allocator, provider: llm.LlmProvider, config: RuntimeConfig) AgentRuntime {
        return .{ .allocator = allocator, .provider = provider, .tool_executor = null, .config = config };
    }

    pub fn setToolExecutor(self: *AgentRuntime, executor: ToolExecutor) void {
        self.tool_executor = executor;
    }
};

test "IterationBudget lifecycle" {
    var budget = IterationBudget{ .max_iterations = 3 };
    try std.testing.expect(!budget.exhausted());
    budget.tick();
    budget.tick();
    budget.tick();
    try std.testing.expect(budget.exhausted());
    try std.testing.expectEqual(@as(u32, 0), budget.remaining());
}

test "ContextWindow compression trigger" {
    const cw = ContextWindow{ .max_tokens = 1000, .used_tokens = 600 };
    try std.testing.expect(cw.needsCompression());
    const cw2 = ContextWindow{ .max_tokens = 1000, .used_tokens = 400 };
    try std.testing.expect(!cw2.needsCompression());
}

test "CallbackSurface no-op when null" {
    const cb = CallbackSurface{};
    cb.toolProgress("test", true);
    cb.thinking(true);
    cb.streamDelta("hello", false);
    cb.step(1);
}
