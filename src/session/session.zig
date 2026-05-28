const std = @import("std");
const schema = @import("schema.zig");

pub const SessionCreateRequest = struct {
    title: []const u8,
    agent_id: []const u8,
    parent_id: ?schema.SessionId = null,
};

pub const SessionForkRequest = struct {
    source_session_id: schema.SessionId,
    up_to_message_id: ?schema.MessageId = null,
    title: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

pub const SessionInfo = struct {
    id: schema.SessionId,
    title: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    parent_id: ?schema.SessionId = null,
    agent_id: []const u8,
    archived: bool = false,

    pub fn clone(self: SessionInfo, allocator: std.mem.Allocator) !SessionInfo {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .title = try allocator.dupe(u8, self.title),
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .parent_id = if (self.parent_id) |parent_id| try allocator.dupe(u8, parent_id) else null,
            .agent_id = try allocator.dupe(u8, self.agent_id),
            .archived = self.archived,
        };
    }

    pub fn deinit(self: *SessionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        if (self.parent_id) |parent_id| allocator.free(parent_id);
        allocator.free(self.agent_id);
    }
};

pub fn initFromCreateRequest(
    allocator: std.mem.Allocator,
    request: SessionCreateRequest,
) !SessionInfo {
    const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds();
    return .{
        .id = try schema.nextSessionId(allocator),
        .title = try allocator.dupe(u8, request.title),
        .created_at_ms = now,
        .updated_at_ms = now,
        .parent_id = if (request.parent_id) |parent_id| try allocator.dupe(u8, parent_id) else null,
        .agent_id = try allocator.dupe(u8, request.agent_id),
        .archived = false,
    };
}

test "session info can be constructed from create request" {
    var info = try initFromCreateRequest(std.testing.allocator, .{
        .title = "Test Session",
        .agent_id = "build",
    });
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("Test Session", info.title);
    try std.testing.expectEqualStrings("build", info.agent_id);
    try std.testing.expect(info.updated_at_ms >= info.created_at_ms);
}
