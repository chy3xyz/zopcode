const std = @import("std");
const agent = @import("../agent/root.zig");
const prompt = @import("../prompt/root.zig");
const framework = @import("framework");

pub const PreparedPromptInput = struct {
    agent_id: []u8,
    system_prompt: []u8,
    user_prompt: ?[]u8 = null,

    pub fn deinit(self: *PreparedPromptInput, allocator: std.mem.Allocator) void {
        allocator.free(self.agent_id);
        allocator.free(self.system_prompt);
        if (self.user_prompt) |user_prompt| allocator.free(user_prompt);
    }
};

pub fn prepareForProfile(
    allocator: std.mem.Allocator,
    profile: *const agent.AgentProfile,
    user_input: ?[]const u8,
) !PreparedPromptInput {
    var assembled = try prompt.assemble(allocator, profile, user_input);
    errdefer assembled.deinit(allocator);

    return .{
        .agent_id = assembled.profile_id,
        .system_prompt = assembled.system_prompt,
        .user_prompt = assembled.user_prompt,
    };
}

pub fn logPreparedPrompt(
    logger: *framework.Logger,
    profile: *const agent.AgentProfile,
    prepared: *const PreparedPromptInput,
) void {
    logger.child("prompt").child("prepare").info("prepared prompt materialized", &.{
        framework.LogField.string("profile_id", profile.id),
        framework.LogField.string("prompt_asset", profile.prompt_asset),
        framework.LogField.int("system_prompt_len", @intCast(prepared.system_prompt.len)),
        framework.LogField.int("user_prompt_len", @intCast(if (prepared.user_prompt) |text| text.len else 0)),
    });
}

test "session prompt input consumes assembled prompt output" {
    var registry = agent.AgentRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try agent.registerBuiltins(&registry);

    const build_profile = registry.get("build").?;
    var prepared = try prepareForProfile(std.testing.allocator, build_profile, "ship it");
    defer prepared.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("build", prepared.agent_id);
    try std.testing.expect(std.mem.indexOf(u8, prepared.system_prompt, "build mode") != null);
}

test "prompt preparation logging does not dump full prompt body" {
    var registry = agent.AgentRegistry.init(std.testing.allocator);
    defer registry.deinit();
    try agent.registerBuiltins(&registry);

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 8);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    const profile = registry.get("plan").?;
    var prepared = try prepareForProfile(std.testing.allocator, profile, "ship it");
    defer prepared.deinit(std.testing.allocator);

    logPreparedPrompt(&logger, profile, &prepared);

    const latest = memory_sink.latest().?;
    try std.testing.expectEqualStrings("prepared prompt materialized", latest.message);
    try std.testing.expect(std.mem.indexOf(u8, latest.message, "ship it") == null);
}
