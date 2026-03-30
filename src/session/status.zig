const std = @import("std");
const schema = @import("schema.zig");

pub const SessionStatus = enum {
    idle,
    running,
    waiting_tool,
    completed,
    failed,
    cancelled,

    pub fn asText(self: SessionStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .running => "running",
            .waiting_tool => "waiting_tool",
            .completed => "completed",
            .failed => "failed",
            .cancelled => "cancelled",
        };
    }

    pub fn fromText(text: []const u8) ?SessionStatus {
        if (std.mem.eql(u8, text, "idle")) return .idle;
        if (std.mem.eql(u8, text, "running")) return .running;
        if (std.mem.eql(u8, text, "waiting_tool")) return .waiting_tool;
        if (std.mem.eql(u8, text, "completed")) return .completed;
        if (std.mem.eql(u8, text, "failed")) return .failed;
        if (std.mem.eql(u8, text, "cancelled")) return .cancelled;
        return null;
    }
};

pub const SessionStatusInfo = struct {
    session_id: schema.SessionId,
    status: SessionStatus,
    request_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    updated_at_ms: i64,

    pub fn clone(self: SessionStatusInfo, allocator: std.mem.Allocator) !SessionStatusInfo {
        return .{
            .session_id = try allocator.dupe(u8, self.session_id),
            .status = self.status,
            .request_id = if (self.request_id) |request_id| try allocator.dupe(u8, request_id) else null,
            .task_id = if (self.task_id) |task_id| try allocator.dupe(u8, task_id) else null,
            .updated_at_ms = self.updated_at_ms,
        };
    }

    pub fn deinit(self: *SessionStatusInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        if (self.request_id) |request_id| allocator.free(request_id);
        if (self.task_id) |task_id| allocator.free(task_id);
    }
};

pub const SessionStatusUpdate = struct {
    session_id: schema.SessionId,
    status: SessionStatus,
    request_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
};

pub const SessionStatusIndex = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(SessionStatusInfo) = .empty,
    mutex: std.Thread.Mutex = .{},

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    pub fn set(self: *Self, allocator: std.mem.Allocator, update: SessionStatusUpdate) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.findMutableLocked(update.session_id)) |existing| {
            const next_session_id = try allocator.dupe(u8, update.session_id);
            errdefer allocator.free(next_session_id);
            existing.status = update.status;

            const next_request_id = if (update.request_id) |request_id| try allocator.dupe(u8, request_id) else null;
            errdefer if (next_request_id) |request_id| allocator.free(request_id);

            const next_task_id = if (update.task_id) |task_id| try allocator.dupe(u8, task_id) else null;
            errdefer if (next_task_id) |task_id| allocator.free(task_id);

            allocator.free(existing.session_id);
            existing.session_id = next_session_id;

            if (existing.request_id) |request_id| allocator.free(request_id);
            existing.request_id = next_request_id;

            if (existing.task_id) |task_id| allocator.free(task_id);
            existing.task_id = next_task_id;

            existing.updated_at_ms = std.time.milliTimestamp();
            return;
        }

        try self.items.append(allocator, .{
            .session_id = try allocator.dupe(u8, update.session_id),
            .status = update.status,
            .request_id = if (update.request_id) |request_id| try allocator.dupe(u8, request_id) else null,
            .task_id = if (update.task_id) |task_id| try allocator.dupe(u8, task_id) else null,
            .updated_at_ms = std.time.milliTimestamp(),
        });
    }

    pub fn get(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) !?SessionStatusInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const existing = self.findLocked(session_id) orelse return null;
        return try existing.clone(allocator);
    }

    pub fn list(self: *Self, allocator: std.mem.Allocator) ![]SessionStatusInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        const cloned = try allocator.alloc(SessionStatusInfo, self.items.items.len);
        errdefer allocator.free(cloned);

        for (self.items.items, 0..) |item, index| {
            cloned[index] = try item.clone(allocator);
        }
        return cloned;
    }

    fn findLocked(self: *Self, session_id: schema.SessionId) ?*const SessionStatusInfo {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.session_id, session_id)) return item;
        }
        return null;
    }

    fn findMutableLocked(self: *Self, session_id: schema.SessionId) ?*SessionStatusInfo {
        for (self.items.items) |*item| {
            if (std.mem.eql(u8, item.session_id, session_id)) return item;
        }
        return null;
    }
};

test "session status text round-trips" {
    try std.testing.expectEqualStrings("idle", SessionStatus.idle.asText());
    try std.testing.expect(SessionStatus.fromText("waiting_tool") != null);
    try std.testing.expect(SessionStatus.fromText("missing") == null);
}

test "session status index stores and lists session execution states" {
    var index = SessionStatusIndex.init(std.testing.allocator);
    defer index.deinit();

    try index.set(std.testing.allocator, .{
        .session_id = "session_01",
        .status = .running,
        .request_id = "req_01",
        .task_id = "task_01",
    });

    var loaded = (try index.get(std.testing.allocator, "session_01")).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(SessionStatus.running, loaded.status);
    try std.testing.expectEqualStrings("req_01", loaded.request_id.?);
    try std.testing.expectEqualStrings("task_01", loaded.task_id.?);

    try index.set(std.testing.allocator, .{
        .session_id = "session_01",
        .status = .completed,
        .request_id = "req_01",
    });

    const listed = try index.list(std.testing.allocator);
    defer {
        for (listed) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(listed);
    }
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqual(SessionStatus.completed, listed[0].status);
    try std.testing.expect(listed[0].task_id == null);
}
