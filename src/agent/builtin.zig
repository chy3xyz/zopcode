const profile_model = @import("profile.zig");
const registry_model = @import("registry.zig");

const build_tools = [_][]const u8{
    "read_file",
    "write_file",
    "edit_file",
    "revert_files",
    "execute_shell",
    "list_files",
    "search_files",
    "fetch_url",
    "mcp_resource",
    "mcp.*",
    "question",
    "skill",
};

const read_heavy_tools = [_][]const u8{
    "read_file",
    "list_files",
    "search_files",
    "fetch_url",
    "mcp_resource",
    "mcp.*",
    "question",
    "skill",
};

const builtin_profiles = [_]profile_model.AgentProfile{
    .{
        .id = "build",
        .mode = .build,
        .description = "Implementation-oriented primary agent",
        .prompt_asset = "build",
        .allow_tools = build_tools[0..],
    },
    .{
        .id = "plan",
        .mode = .plan,
        .description = "Planning-oriented primary agent",
        .prompt_asset = "plan",
        .allow_tools = read_heavy_tools[0..],
    },
    .{
        .id = "explore",
        .mode = .explore,
        .description = "Read-heavy exploration agent",
        .prompt_asset = "explore",
        .allow_tools = read_heavy_tools[0..],
    },
    .{
        .id = "oracle",
        .mode = .subagent,
        .description = "Verification-focused oracle agent",
        .prompt_asset = "oracle",
        .allow_tools = read_heavy_tools[0..],
    },
};

pub fn builtins() []const profile_model.AgentProfile {
    return builtin_profiles[0..];
}

pub fn registerBuiltins(registry: *registry_model.AgentRegistry) !void {
    for (builtins()) |profile| {
        try registry.register(profile);
    }
}
