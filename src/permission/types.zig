const std = @import("std");

pub const PermissionAction = enum {
    allow,
    deny,
    ask,

    pub fn asText(self: PermissionAction) []const u8 {
        return switch (self) {
            .allow => "allow",
            .deny => "deny",
            .ask => "ask",
        };
    }

    pub fn fromText(value: []const u8) ?PermissionAction {
        if (std.mem.eql(u8, value, "allow")) return .allow;
        if (std.mem.eql(u8, value, "deny")) return .deny;
        if (std.mem.eql(u8, value, "ask")) return .ask;
        return null;
    }
};

pub const PermissionReply = enum {
    once,
    reject,

    pub fn asText(self: PermissionReply) []const u8 {
        return switch (self) {
            .once => "once",
            .reject => "reject",
        };
    }

    pub fn fromText(value: []const u8) ?PermissionReply {
        if (std.mem.eql(u8, value, "once")) return .once;
        if (std.mem.eql(u8, value, "reject")) return .reject;
        return null;
    }
};

pub const PermissionRule = struct {
    permission: []const u8,
    pattern: []const u8,
    action: PermissionAction,

    pub fn clone(self: PermissionRule, allocator: std.mem.Allocator) !PermissionRule {
        return .{
            .permission = try allocator.dupe(u8, self.permission),
            .pattern = try allocator.dupe(u8, self.pattern),
            .action = self.action,
        };
    }

    pub fn deinit(self: *PermissionRule, allocator: std.mem.Allocator) void {
        allocator.free(self.permission);
        allocator.free(self.pattern);
    }
};

pub const PermissionRequest = struct {
    id: []const u8,
    session_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    permission: []const u8,
    patterns: [][]const u8,
    metadata_json: []const u8 = "{}",

    pub fn clone(self: PermissionRequest, allocator: std.mem.Allocator) !PermissionRequest {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .session_id = if (self.session_id) |value| try allocator.dupe(u8, value) else null,
            .request_id = if (self.request_id) |value| try allocator.dupe(u8, value) else null,
            .message_id = if (self.message_id) |value| try allocator.dupe(u8, value) else null,
            .call_id = if (self.call_id) |value| try allocator.dupe(u8, value) else null,
            .tool_name = if (self.tool_name) |value| try allocator.dupe(u8, value) else null,
            .permission = try allocator.dupe(u8, self.permission),
            .patterns = try cloneStringSlice(allocator, self.patterns),
            .metadata_json = try allocator.dupe(u8, self.metadata_json),
        };
    }

    pub fn deinit(self: *PermissionRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        if (self.session_id) |value| allocator.free(value);
        if (self.request_id) |value| allocator.free(value);
        if (self.message_id) |value| allocator.free(value);
        if (self.call_id) |value| allocator.free(value);
        if (self.tool_name) |value| allocator.free(value);
        allocator.free(self.permission);
        freeStringSlice(allocator, self.patterns);
        allocator.free(self.metadata_json);
    }
};

pub const PermissionAskInput = struct {
    session_id: ?[]const u8 = null,
    request_id: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    permission: []const u8,
    patterns: [][]const u8,
    metadata_json: []const u8 = "{}",
};

pub fn cloneStringSlice(allocator: std.mem.Allocator, items: [][]const u8) ![][]const u8 {
    const cloned = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(cloned);
    for (items, 0..) |item, index| {
        cloned[index] = try allocator.dupe(u8, item);
    }
    return cloned;
}

pub fn freeStringSlice(allocator: std.mem.Allocator, items: [][]const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

test "permission action and reply text round-trip" {
    try std.testing.expectEqualStrings("ask", PermissionAction.ask.asText());
    try std.testing.expect(PermissionAction.fromText("deny") != null);
    try std.testing.expect(PermissionReply.fromText("once") != null);
}
