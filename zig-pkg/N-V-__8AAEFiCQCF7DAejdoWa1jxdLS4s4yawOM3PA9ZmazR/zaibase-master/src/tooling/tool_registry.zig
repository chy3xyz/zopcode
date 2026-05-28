const std = @import("std");
const tool_definition = @import("tool_definition.zig");

pub const ToolDefinition = tool_definition.ToolDefinition;

pub const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    definitions: std.ArrayListUnmanaged(ToolDefinition) = .empty,

    pub fn init(allocator: std.mem.Allocator) ToolRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ToolRegistry) void {
        self.definitions.deinit(self.allocator);
    }

    pub fn register(self: *ToolRegistry, definition: ToolDefinition) !void {
        if (self.find(definition.id) != null) return error.DuplicateToolId;
        try self.definitions.append(self.allocator, definition);
    }

    pub fn find(self: *const ToolRegistry, id: []const u8) ?ToolDefinition {
        for (self.definitions.items) |definition| {
            if (std.mem.eql(u8, definition.id, id)) return definition;
        }
        return null;
    }

    pub fn list(self: *const ToolRegistry) []const ToolDefinition {
        return self.definitions.items;
    }

    pub fn count(self: *const ToolRegistry) usize {
        return self.definitions.items.len;
    }
};

test "tool registry supports register find and duplicate detection" {
    var registry = ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{
        .id = "demo",
        .description = "demo tool",
    });

    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.find("demo") != null);
    try std.testing.expectEqual(@as(usize, 1), registry.list().len);
    try std.testing.expectError(error.DuplicateToolId, registry.register(.{
        .id = "demo",
        .description = "duplicate tool",
    }));
}


