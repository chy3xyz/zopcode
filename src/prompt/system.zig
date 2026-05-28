pub const base_system_prompt =
    \\You are zopcode, a Zig-native coding agent built on zig-framework.
    \\Prefer precise, direct, implementation-oriented reasoning.
;

pub fn profilePrompt(asset_id: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, asset_id, "build")) return build_profile_prompt;
    if (std.mem.eql(u8, asset_id, "plan")) return plan_profile_prompt;
    if (std.mem.eql(u8, asset_id, "explore")) return explore_profile_prompt;
    if (std.mem.eql(u8, asset_id, "oracle")) return oracle_profile_prompt;
    return null;
}

const std = @import("std");

const build_profile_prompt =
    \\You are in build mode.
    \\Prioritize implementation correctness, minimal drift, and concrete code changes.
;

const plan_profile_prompt =
    \\You are in plan mode.
    \\Focus on understanding, sequencing, and risk identification before implementation.
;

const explore_profile_prompt =
    \\You are in explore mode.
    \\Prioritize reading, mapping, and clarifying the codebase before proposing changes.
;

const oracle_profile_prompt =
    \\You are in oracle verification mode.
    \\Be skeptical, verify completion claims, and only approve when the work is actually complete.
;
