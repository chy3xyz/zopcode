const std = @import("std");
const provider_types = @import("provider_types.zig");

pub const ProviderDefinition = provider_types.ProviderDefinition;
pub const ProviderHealth = provider_types.ProviderHealth;
pub const ProviderModelInfo = provider_types.ProviderModelInfo;

pub const ProviderRegistry = struct {
    allocator: std.mem.Allocator,
    definitions: std.ArrayListUnmanaged(ProviderDefinition) = .empty,

    pub fn init(allocator: std.mem.Allocator) ProviderRegistry {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProviderRegistry) void {
        self.definitions.deinit(self.allocator);
    }

    pub fn register(self: *ProviderRegistry, definition: ProviderDefinition) !void {
        if (self.find(definition.id) != null) return error.DuplicateProviderId;
        try self.definitions.append(self.allocator, definition);
    }

    pub fn find(self: *const ProviderRegistry, id: []const u8) ?ProviderDefinition {
        for (self.definitions.items) |definition| {
            if (std.mem.eql(u8, definition.id, id)) return definition;
        }
        return null;
    }

    pub fn list(self: *const ProviderRegistry) []const ProviderDefinition {
        return self.definitions.items;
    }

    pub fn count(self: *const ProviderRegistry) usize {
        return self.definitions.items.len;
    }
};

test "provider registry supports register find and duplicate detection" {
    var registry = ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{
        .id = "openai",
        .label = "OpenAI",
        .default_model = "gpt-4o-mini",
        .supports_streaming = true,
    });

    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.find("openai") != null);
    try std.testing.expectError(error.DuplicateProviderId, registry.register(.{
        .id = "openai",
        .label = "Duplicate OpenAI",
        .default_model = "gpt-4o-mini",
    }));
}


