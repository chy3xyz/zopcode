const std = @import("std");

pub const MODULE_NAME = "plugin";

pub const runtime = @import("runtime.zig");

pub const PluginRuntime = runtime.PluginRuntime;
pub const PluginInfo = runtime.PluginInfo;
pub const HookInfo = runtime.HookInfo;

test "plugin module exports are available" {
    try std.testing.expectEqualStrings("plugin", MODULE_NAME);
}
