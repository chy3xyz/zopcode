const std = @import("std");

pub const MODULE_NAME = "framework_integration";

pub const ToolingBridge = @import("tooling_bridge.zig").ToolingBridge;
pub const ScriptBridge = @import("script_bridge.zig").ScriptBridge;

test "framework integration exports are stable" {
    try std.testing.expectEqualStrings("framework_integration", MODULE_NAME);
    _ = ToolingBridge;
    _ = ScriptBridge;
}
