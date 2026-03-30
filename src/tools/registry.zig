const std = @import("std");
const tool_model = @import("tool.zig");

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    tools: std.ArrayListUnmanaged(tool_model.ToolDefinition) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.tools.items) |*tool| tool.deinit(self.allocator);
        self.tools.deinit(self.allocator);
    }

    pub fn register(self: *Self, definition: tool_model.ToolDefinition) !void {
        if (self.get(definition.id) != null) return error.DuplicateToolId;
        try self.tools.append(self.allocator, try definition.clone(self.allocator));
    }

    pub fn get(self: *const Self, id: []const u8) ?*const tool_model.ToolDefinition {
        for (self.tools.items) |*tool| {
            if (std.mem.eql(u8, tool.id, id)) return tool;
        }
        return null;
    }

    pub fn list(self: *const Self) []const tool_model.ToolDefinition {
        return self.tools.items;
    }

    pub fn count(self: *const Self) usize {
        return self.tools.items.len;
    }
};

test "tool registry registers builtin ids" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{
        .id = "read_file",
        .description = "Read file",
    });

    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.get("read_file") != null);
}
