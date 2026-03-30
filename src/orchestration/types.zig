const std = @import("std");
const provider = @import("../provider/root.zig");

pub const ChildRequest = struct {
    prompt: []const u8,
    agent_id: ?[]const u8 = null,
    category: ?[]const u8 = null,
    title: ?[]const u8 = null,
    model: ?provider.ModelRef = null,

    pub fn clone(self: ChildRequest, allocator: std.mem.Allocator) !ChildRequest {
        return .{
            .prompt = try allocator.dupe(u8, self.prompt),
            .agent_id = if (self.agent_id) |value| try allocator.dupe(u8, value) else null,
            .category = if (self.category) |value| try allocator.dupe(u8, value) else null,
            .title = if (self.title) |value| try allocator.dupe(u8, value) else null,
            .model = if (self.model) |model| .{
                .provider_id = try allocator.dupe(u8, model.provider_id),
                .model_id = try allocator.dupe(u8, model.model_id),
            } else null,
        };
    }

    pub fn deinit(self: *ChildRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.prompt);
        if (self.agent_id) |value| allocator.free(value);
        if (self.category) |value| allocator.free(value);
        if (self.title) |value| allocator.free(value);
        if (self.model) |model| {
            allocator.free(model.provider_id);
            allocator.free(model.model_id);
        }
    }
};

pub const ChildHandle = struct {
    child_session_id: []const u8,
    agent_id: []const u8,
    request_id: []const u8,
    task_id: []const u8,

    pub fn deinit(self: *ChildHandle, allocator: std.mem.Allocator) void {
        allocator.free(self.child_session_id);
        allocator.free(self.agent_id);
        allocator.free(self.request_id);
        allocator.free(self.task_id);
    }
};

pub const ChildResult = struct {
    child_session_id: []const u8,
    agent_id: []const u8,
    status: []const u8,
    request_id: []const u8,
    task_id: []const u8,
    summary: []const u8,

    pub fn clone(self: ChildResult, allocator: std.mem.Allocator) !ChildResult {
        return .{
            .child_session_id = try allocator.dupe(u8, self.child_session_id),
            .agent_id = try allocator.dupe(u8, self.agent_id),
            .status = try allocator.dupe(u8, self.status),
            .request_id = try allocator.dupe(u8, self.request_id),
            .task_id = try allocator.dupe(u8, self.task_id),
            .summary = try allocator.dupe(u8, self.summary),
        };
    }

    pub fn deinit(self: *ChildResult, allocator: std.mem.Allocator) void {
        allocator.free(self.child_session_id);
        allocator.free(self.agent_id);
        allocator.free(self.status);
        allocator.free(self.request_id);
        allocator.free(self.task_id);
        allocator.free(self.summary);
    }
};

pub const BatchRequest = struct {
    batch_id: ?[]const u8 = null,
    parent_session_id: []const u8,
    children: []ChildRequest,

    pub fn deinit(self: *BatchRequest, allocator: std.mem.Allocator) void {
        if (self.batch_id) |batch_id| allocator.free(batch_id);
        allocator.free(self.parent_session_id);
        for (self.children) |*child| child.deinit(allocator);
        allocator.free(self.children);
    }
};

pub const AggregatedResult = struct {
    batch_id: []const u8,
    parent_session_id: []const u8,
    summary: []const u8,
    success_count: u32,
    failure_count: u32,
    items: []ChildResult,

    pub fn deinit(self: *AggregatedResult, allocator: std.mem.Allocator) void {
        allocator.free(self.batch_id);
        allocator.free(self.parent_session_id);
        allocator.free(self.summary);
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

test "child request clone preserves optional overlays" {
    var cloned = try (ChildRequest{
        .prompt = "do it",
        .agent_id = "build",
        .category = "deep",
        .model = .{ .provider_id = "mock", .model_id = "m1" },
    }).clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("do it", cloned.prompt);
    try std.testing.expectEqualStrings("build", cloned.agent_id.?);
    try std.testing.expectEqualStrings("deep", cloned.category.?);
    try std.testing.expectEqualStrings("mock", cloned.model.?.provider_id);
}
