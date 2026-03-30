const std = @import("std");

pub const MODULE_NAME = "skill";

pub const runtime = @import("runtime.zig");

pub const SkillRuntime = runtime.SkillRuntime;
pub const SkillInfo = runtime.SkillInfo;

test "skill module exports are available" {
    try std.testing.expectEqualStrings("skill", MODULE_NAME);
}
