const std = @import("std");
const agent = @import("../agent/root.zig");
const system = @import("system.zig");
const reminders = @import("reminders.zig");

pub const PromptAssets = struct {
    system_prompt: []const u8,
    profile_prompt: []const u8,
    reminder: ?[]const u8 = null,
};

pub const AssembledPrompt = struct {
    profile_id: []u8,
    system_prompt: []u8,
    user_prompt: ?[]u8 = null,

    pub fn deinit(self: *AssembledPrompt, allocator: std.mem.Allocator) void {
        allocator.free(self.profile_id);
        allocator.free(self.system_prompt);
        if (self.user_prompt) |user_prompt| allocator.free(user_prompt);
    }
};

pub fn resolveAssets(profile: *const agent.AgentProfile) !PromptAssets {
    return .{
        .system_prompt = system.base_system_prompt,
        .profile_prompt = system.profilePrompt(profile.prompt_asset) orelse return error.UnknownPromptAsset,
        .reminder = reminders.reminderForProfile(profile.id),
    };
}

pub fn buildSystemPrompt(allocator: std.mem.Allocator, profile: *const agent.AgentProfile) ![]u8 {
    const assets = try resolveAssets(profile);
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    parts[count] = assets.system_prompt;
    count += 1;
    parts[count] = assets.profile_prompt;
    count += 1;
    if (assets.reminder) |reminder| {
        parts[count] = reminder;
        count += 1;
    }

    return std.mem.join(allocator, "\n\n", parts[0..count]);
}

pub fn buildUserPrompt(allocator: std.mem.Allocator, user_input: []const u8) ![]u8 {
    return allocator.dupe(u8, user_input);
}

pub fn assemble(
    allocator: std.mem.Allocator,
    profile: *const agent.AgentProfile,
    user_input: ?[]const u8,
) !AssembledPrompt {
    return .{
        .profile_id = try allocator.dupe(u8, profile.id),
        .system_prompt = try buildSystemPrompt(allocator, profile),
        .user_prompt = if (user_input) |text| try buildUserPrompt(allocator, text) else null,
    };
}

test "prompt assembly adds plan reminder for plan profile" {
    var registry = agent.AgentRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try agent.registerBuiltins(&registry);

    const plan_profile = registry.get("plan").?;
    var assembled = try assemble(std.testing.allocator, plan_profile, "plan this");
    defer assembled.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, assembled.system_prompt, "Planning reminder") != null);
}

test "prompt assembly adds explore reminder for explore profile" {
    var registry = agent.AgentRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try agent.registerBuiltins(&registry);

    const explore_profile = registry.get("explore").?;
    var assembled = try assemble(std.testing.allocator, explore_profile, "explore this");
    defer assembled.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, assembled.system_prompt, "Exploration reminder") != null);
}

test "prompt assembly adds oracle verification guidance for oracle profile" {
    var registry = agent.AgentRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try agent.registerBuiltins(&registry);

    const oracle_profile = registry.get("oracle").?;
    var assembled = try assemble(std.testing.allocator, oracle_profile, "verify this");
    defer assembled.deinit(std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, assembled.system_prompt, "oracle verification mode") != null);
    try std.testing.expect(std.mem.indexOf(u8, assembled.system_prompt, "Oracle reminder") != null);
}
