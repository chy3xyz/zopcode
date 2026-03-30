const std = @import("std");

pub const StatusKind = enum {
    connected,
    disabled,
    failed,

    pub fn asText(self: StatusKind) []const u8 {
        return switch (self) {
            .connected => "connected",
            .disabled => "disabled",
            .failed => "failed",
        };
    }
};

pub const Status = struct {
    id: []const u8,
    transport: []const u8,
    status: StatusKind,
    error_message: ?[]const u8 = null,
    tool_count: u32 = 0,
    resource_count: u32 = 0,

    pub fn clone(self: Status, allocator: std.mem.Allocator) !Status {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .transport = try allocator.dupe(u8, self.transport),
            .status = self.status,
            .error_message = if (self.error_message) |value| try allocator.dupe(u8, value) else null,
            .tool_count = self.tool_count,
            .resource_count = self.resource_count,
        };
    }

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.transport);
        if (self.error_message) |value| allocator.free(value);
    }
};

pub const ToolInfo = struct {
    server_id: []const u8,
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,

    pub fn clone(self: ToolInfo, allocator: std.mem.Allocator) !ToolInfo {
        return .{
            .server_id = try allocator.dupe(u8, self.server_id),
            .name = try allocator.dupe(u8, self.name),
            .description = try allocator.dupe(u8, self.description),
            .input_schema_json = try allocator.dupe(u8, self.input_schema_json),
        };
    }

    pub fn deinit(self: *ToolInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.server_id);
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.input_schema_json);
    }
};

pub const ResourceInfo = struct {
    server_id: []const u8,
    uri: []const u8,
    name: []const u8,
    description: ?[]const u8 = null,
    mime_type: ?[]const u8 = null,

    pub fn clone(self: ResourceInfo, allocator: std.mem.Allocator) !ResourceInfo {
        return .{
            .server_id = try allocator.dupe(u8, self.server_id),
            .uri = try allocator.dupe(u8, self.uri),
            .name = try allocator.dupe(u8, self.name),
            .description = if (self.description) |value| try allocator.dupe(u8, value) else null,
            .mime_type = if (self.mime_type) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *ResourceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.server_id);
        allocator.free(self.uri);
        allocator.free(self.name);
        if (self.description) |value| allocator.free(value);
        if (self.mime_type) |value| allocator.free(value);
    }
};

pub const ResourceContent = struct {
    server_id: []const u8,
    uri: []const u8,
    text: []const u8,
    mime_type: ?[]const u8 = null,

    pub fn clone(self: ResourceContent, allocator: std.mem.Allocator) !ResourceContent {
        return .{
            .server_id = try allocator.dupe(u8, self.server_id),
            .uri = try allocator.dupe(u8, self.uri),
            .text = try allocator.dupe(u8, self.text),
            .mime_type = if (self.mime_type) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *ResourceContent, allocator: std.mem.Allocator) void {
        allocator.free(self.server_id);
        allocator.free(self.uri);
        allocator.free(self.text);
        if (self.mime_type) |value| allocator.free(value);
    }
};

pub const ToolCallResult = struct {
    output_text: []const u8,
    metadata_json: []const u8,

    pub fn clone(self: ToolCallResult, allocator: std.mem.Allocator) !ToolCallResult {
        return .{
            .output_text = try allocator.dupe(u8, self.output_text),
            .metadata_json = try allocator.dupe(u8, self.metadata_json),
        };
    }

    pub fn deinit(self: *ToolCallResult, allocator: std.mem.Allocator) void {
        allocator.free(self.output_text);
        allocator.free(self.metadata_json);
    }
};

pub fn freeStatuses(allocator: std.mem.Allocator, items: []Status) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn freeTools(allocator: std.mem.Allocator, items: []ToolInfo) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn freeResources(allocator: std.mem.Allocator, items: []ResourceInfo) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}
