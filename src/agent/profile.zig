const std = @import("std");
const provider = @import("../provider/root.zig");

pub const AgentMode = enum {
    build,
    plan,
    explore,
    subagent,
};

pub const AgentProfile = struct {
    id: []const u8,
    mode: AgentMode,
    description: []const u8,
    prompt_asset: []const u8,
    max_steps: ?usize = null,
    default_model: ?provider.ModelRef = null,
    allow_tools: []const []const u8 = &.{},

    pub fn clone(self: AgentProfile, allocator: std.mem.Allocator) !AgentProfile {
        const cloned_tools = try allocator.alloc([]const u8, self.allow_tools.len);
        errdefer allocator.free(cloned_tools);
        for (self.allow_tools, 0..) |tool, index| {
            cloned_tools[index] = try allocator.dupe(u8, tool);
        }

        return .{
            .id = try allocator.dupe(u8, self.id),
            .mode = self.mode,
            .description = try allocator.dupe(u8, self.description),
            .prompt_asset = try allocator.dupe(u8, self.prompt_asset),
            .max_steps = self.max_steps,
            .default_model = if (self.default_model) |model| .{
                .provider_id = try allocator.dupe(u8, model.provider_id),
                .model_id = try allocator.dupe(u8, model.model_id),
            } else null,
            .allow_tools = cloned_tools,
        };
    }

    pub fn deinit(self: *AgentProfile, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        allocator.free(self.prompt_asset);
        if (self.default_model) |model| {
            allocator.free(model.provider_id);
            allocator.free(model.model_id);
        }
        for (self.allow_tools) |tool| allocator.free(tool);
        allocator.free(self.allow_tools);
    }

    pub fn isPrimary(self: AgentProfile) bool {
        return self.mode != .subagent;
    }
};

test "agent profile reports primary mode correctly" {
    const build_profile = AgentProfile{
        .id = "build",
        .mode = .build,
        .description = "Build agent",
        .prompt_asset = "build",
        .allow_tools = &.{},
    };

    const subagent_profile = AgentProfile{
        .id = "subagent",
        .mode = .subagent,
        .description = "Subagent",
        .prompt_asset = "subagent",
        .allow_tools = &.{},
    };

    try std.testing.expect(build_profile.isPrimary());
    try std.testing.expect(!subagent_profile.isPrimary());
}
