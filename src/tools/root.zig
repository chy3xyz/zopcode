const std = @import("std");

pub const MODULE_NAME = "tools";

pub const tool = @import("tool.zig");
pub const context = @import("context.zig");
pub const result = @import("result.zig");
pub const registry = @import("registry.zig");
pub const runtime = @import("runtime.zig");
pub const builtin = @import("builtin/root.zig");
pub const hashline = @import("hashline/root.zig");

pub const ToolDefinition = tool.ToolDefinition;
pub const ToolExecutionContext = context.ToolExecutionContext;
pub const HashlineEditBackend = context.HashlineEditBackend;
pub const ToolResult = result.ToolResult;
pub const ToolRegistry = registry.ToolRegistry;
pub const ToolRuntime = runtime.ToolRuntime;

pub const ModuleStage = enum {
    registry,
};

pub const MODULE_STAGE: ModuleStage = .registry;

test "tools scaffold exports are stable" {
    try std.testing.expectEqualStrings("tools", MODULE_NAME);
    try std.testing.expectEqualStrings("read_file", builtin.builtins()[0].id);
}
