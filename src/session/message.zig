const std = @import("std");
const schema = @import("schema.zig");

pub const MessageRole = enum {
    user,
    assistant,

    pub fn asText(self: MessageRole) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

pub const MessageAppendRequest = struct {
    session_id: schema.SessionId,
    role: MessageRole,
    parent_id: ?schema.MessageId = null,
    agent_id: ?[]const u8 = null,
    provider_id: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    completed: bool = false,
    error_code: ?[]const u8 = null,
};

pub const MessageInfo = struct {
    id: schema.MessageId,
    session_id: schema.SessionId,
    role: MessageRole,
    created_at_ms: i64,
    parent_id: ?schema.MessageId = null,
    agent_id: ?[]const u8 = null,
    provider_id: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    completed: bool = false,
    error_code: ?[]const u8 = null,

    pub fn clone(self: MessageInfo, allocator: std.mem.Allocator) !MessageInfo {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .session_id = try allocator.dupe(u8, self.session_id),
            .role = self.role,
            .created_at_ms = self.created_at_ms,
            .parent_id = if (self.parent_id) |parent_id| try allocator.dupe(u8, parent_id) else null,
            .agent_id = if (self.agent_id) |agent_id| try allocator.dupe(u8, agent_id) else null,
            .provider_id = if (self.provider_id) |provider_id| try allocator.dupe(u8, provider_id) else null,
            .model_id = if (self.model_id) |model_id| try allocator.dupe(u8, model_id) else null,
            .completed = self.completed,
            .error_code = if (self.error_code) |error_code| try allocator.dupe(u8, error_code) else null,
        };
    }

    pub fn deinit(self: *MessageInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        if (self.parent_id) |parent_id| allocator.free(parent_id);
        if (self.agent_id) |agent_id| allocator.free(agent_id);
        if (self.provider_id) |provider_id| allocator.free(provider_id);
        if (self.model_id) |model_id| allocator.free(model_id);
        if (self.error_code) |error_code| allocator.free(error_code);
    }
};

pub fn initFromAppendRequest(
    allocator: std.mem.Allocator,
    request: MessageAppendRequest,
) !MessageInfo {
    return .{
        .id = try schema.nextMessageId(allocator),
        .session_id = try allocator.dupe(u8, request.session_id),
        .role = request.role,
        .created_at_ms = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds(),
        .parent_id = if (request.parent_id) |parent_id| try allocator.dupe(u8, parent_id) else null,
        .agent_id = if (request.agent_id) |agent_id| try allocator.dupe(u8, agent_id) else null,
        .provider_id = if (request.provider_id) |provider_id| try allocator.dupe(u8, provider_id) else null,
        .model_id = if (request.model_id) |model_id| try allocator.dupe(u8, model_id) else null,
        .completed = request.completed,
        .error_code = if (request.error_code) |error_code| try allocator.dupe(u8, error_code) else null,
    };
}

test "message role text values are stable" {
    try std.testing.expectEqualStrings("user", MessageRole.user.asText());
    try std.testing.expectEqualStrings("assistant", MessageRole.assistant.asText());
}
