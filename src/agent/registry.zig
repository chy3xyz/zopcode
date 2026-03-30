const std = @import("std");
const profile_model = @import("profile.zig");

pub const AgentRegistry = struct {
    allocator: std.mem.Allocator,
    profiles: std.ArrayListUnmanaged(profile_model.AgentProfile) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.profiles.items) |*profile| profile.deinit(self.allocator);
        self.profiles.deinit(self.allocator);
    }

    pub fn register(self: *Self, profile: profile_model.AgentProfile) !void {
        if (self.get(profile.id) != null) return error.AgentProfileAlreadyRegistered;
        try self.profiles.append(self.allocator, try profile.clone(self.allocator));
    }

    pub fn get(self: *const Self, id: []const u8) ?*const profile_model.AgentProfile {
        for (self.profiles.items) |*profile| {
            if (std.mem.eql(u8, profile.id, id)) return profile;
        }
        return null;
    }

    pub fn defaultPrimary(self: *const Self) ?*const profile_model.AgentProfile {
        for (self.profiles.items) |*profile| {
            if (profile.isPrimary()) return profile;
        }
        return null;
    }

    pub fn list(self: *const Self) []const profile_model.AgentProfile {
        return self.profiles.items;
    }
};

test "agent registry registers and resolves profiles" {
    var registry = AgentRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{
        .id = "build",
        .mode = .build,
        .description = "Build agent",
        .prompt_asset = "build",
        .allow_tools = &.{},
    });

    try std.testing.expect(registry.get("build") != null);
    try std.testing.expectEqualStrings("build", registry.defaultPrimary().?.id);
}
