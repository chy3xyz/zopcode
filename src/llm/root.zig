const std = @import("std");

pub const MODULE_NAME = "llm";

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test "llm scaffold exports are stable" {
    try std.testing.expectEqualStrings("llm", MODULE_NAME);
}
