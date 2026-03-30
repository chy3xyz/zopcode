const std = @import("std");
const provider = @import("../provider/root.zig");

pub const LoopStrategy = enum {
    continue_same_session,
    reset_new_session,

    pub fn asText(self: LoopStrategy) []const u8 {
        return switch (self) {
            .continue_same_session => "continue_same_session",
            .reset_new_session => "reset_new_session",
        };
    }

    pub fn fromText(value: []const u8) ?LoopStrategy {
        if (std.mem.eql(u8, value, "continue_same_session")) return .continue_same_session;
        if (std.mem.eql(u8, value, "reset_new_session")) return .reset_new_session;
        return null;
    }
};

pub const LoopPhase = enum {
    running,
    verification_pending,
    completed,
    cancelled,
    failed,

    pub fn asText(self: LoopPhase) []const u8 {
        return switch (self) {
            .running => "running",
            .verification_pending => "verification_pending",
            .completed => "completed",
            .cancelled => "cancelled",
            .failed => "failed",
        };
    }

    pub fn fromText(value: []const u8) ?LoopPhase {
        if (std.mem.eql(u8, value, "running")) return .running;
        if (std.mem.eql(u8, value, "verification_pending")) return .verification_pending;
        if (std.mem.eql(u8, value, "completed")) return .completed;
        if (std.mem.eql(u8, value, "cancelled")) return .cancelled;
        if (std.mem.eql(u8, value, "failed")) return .failed;
        return null;
    }
};

pub const LoopStartRequest = struct {
    session_id: []const u8,
    agent_id: ?[]const u8 = null,
    category: ?[]const u8 = null,
    model: ?provider.ModelRef = null,
    continuation_prompt: ?[]const u8 = null,
    completion_signal: ?[]const u8 = null,
    strategy: LoopStrategy = .continue_same_session,
    max_iterations: ?u32 = null,
    ultrawork: bool = false,
    verification_signal: ?[]const u8 = null,
    oracle_profile_id: ?[]const u8 = null,
    kickoff: bool = true,
};

pub const LoopState = struct {
    loop_id: []const u8,
    root_session_id: []const u8,
    current_session_id: []const u8,
    agent_id: ?[]const u8 = null,
    category: ?[]const u8 = null,
    model: ?provider.ModelRef = null,
    continuation_prompt: []const u8,
    completion_signal: []const u8,
    strategy: LoopStrategy,
    iteration: u32,
    max_iterations: ?u32 = null,
    active: bool,
    phase: LoopPhase,
    ultrawork: bool,
    verification_pending: bool,
    verification_signal: []const u8,
    oracle_profile_id: []const u8,
    verification_session_id: ?[]const u8 = null,
    verification_attempt_id: ?[]const u8 = null,
    started_at_ms: i64,
    updated_at_ms: i64,

    pub fn clone(self: LoopState, allocator: std.mem.Allocator) !LoopState {
        return .{
            .loop_id = try allocator.dupe(u8, self.loop_id),
            .root_session_id = try allocator.dupe(u8, self.root_session_id),
            .current_session_id = try allocator.dupe(u8, self.current_session_id),
            .agent_id = if (self.agent_id) |value| try allocator.dupe(u8, value) else null,
            .category = if (self.category) |value| try allocator.dupe(u8, value) else null,
            .model = if (self.model) |value| try value.clone(allocator) else null,
            .continuation_prompt = try allocator.dupe(u8, self.continuation_prompt),
            .completion_signal = try allocator.dupe(u8, self.completion_signal),
            .strategy = self.strategy,
            .iteration = self.iteration,
            .max_iterations = self.max_iterations,
            .active = self.active,
            .phase = self.phase,
            .ultrawork = self.ultrawork,
            .verification_pending = self.verification_pending,
            .verification_signal = try allocator.dupe(u8, self.verification_signal),
            .oracle_profile_id = try allocator.dupe(u8, self.oracle_profile_id),
            .verification_session_id = if (self.verification_session_id) |value| try allocator.dupe(u8, value) else null,
            .verification_attempt_id = if (self.verification_attempt_id) |value| try allocator.dupe(u8, value) else null,
            .started_at_ms = self.started_at_ms,
            .updated_at_ms = self.updated_at_ms,
        };
    }

    pub fn deinit(self: *LoopState, allocator: std.mem.Allocator) void {
        allocator.free(self.loop_id);
        allocator.free(self.root_session_id);
        allocator.free(self.current_session_id);
        if (self.agent_id) |value| allocator.free(value);
        if (self.category) |value| allocator.free(value);
        if (self.model) |*value| value.deinit(allocator);
        allocator.free(self.continuation_prompt);
        allocator.free(self.completion_signal);
        allocator.free(self.verification_signal);
        allocator.free(self.oracle_profile_id);
        if (self.verification_session_id) |value| allocator.free(value);
        if (self.verification_attempt_id) |value| allocator.free(value);
    }

    pub fn touch(self: *LoopState) void {
        self.updated_at_ms = std.time.milliTimestamp();
    }
};

test "loop strategy and phase text round-trip" {
    try std.testing.expectEqualStrings("continue_same_session", LoopStrategy.continue_same_session.asText());
    try std.testing.expect(LoopStrategy.fromText("reset_new_session") != null);
    try std.testing.expect(LoopPhase.fromText("verification_pending") != null);
    try std.testing.expect(LoopPhase.fromText("missing") == null);
}
