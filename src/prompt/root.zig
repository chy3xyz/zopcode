const std = @import("std");

pub const MODULE_NAME = "prompt";

pub const system = @import("system.zig");
pub const reminders = @import("reminders.zig");
pub const assembly = @import("assembly.zig");

pub const PromptAssets = assembly.PromptAssets;
pub const AssembledPrompt = assembly.AssembledPrompt;
pub const resolveAssets = assembly.resolveAssets;
pub const buildSystemPrompt = assembly.buildSystemPrompt;
pub const buildUserPrompt = assembly.buildUserPrompt;
pub const assemble = assembly.assemble;

test "prompt module exports assembly surface" {
    try std.testing.expectEqualStrings("prompt", MODULE_NAME);
}
