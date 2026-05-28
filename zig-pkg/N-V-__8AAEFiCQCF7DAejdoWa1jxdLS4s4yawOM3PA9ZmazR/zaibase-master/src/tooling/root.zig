const std = @import("std");

pub const MODULE_NAME = "tooling";
pub const tool_definition = @import("tool_definition.zig");
pub const tool_context = @import("tool_context.zig");
pub const tool_registry = @import("tool_registry.zig");
pub const tool_runner = @import("tool_runner.zig");
pub const native_interface = @import("native_interface.zig");
pub const script_contract = @import("script_contract.zig");
pub const script_host = @import("script_host.zig");
pub const runtime = @import("runtime.zig");
pub const adapters = @import("adapters/root.zig");
pub const examples = @import("examples/root.zig");

pub const ToolExecutionKind = tool_definition.ToolExecutionKind;
pub const NativeToolHandler = tool_definition.NativeToolHandler;
pub const ToolDefinition = tool_definition.ToolDefinition;
pub const ToolContext = tool_context.ToolContext;
pub const ToolRegistry = tool_registry.ToolRegistry;
pub const ToolRunRequest = tool_runner.ToolRunRequest;
pub const ToolExecutionResult = tool_runner.ToolExecutionResult;
pub const ToolRunner = tool_runner.ToolRunner;
pub const ToolVTable = native_interface.ToolVTable;
pub const assertToolInterface = native_interface.assertToolInterface;
pub const defineTool = native_interface.defineTool;
pub const ScriptRequest = script_contract.ScriptRequest;
pub const ScriptResult = script_contract.ScriptResult;
pub const ScriptSpec = script_contract.ScriptSpec;
pub const ToolingRuntime = runtime.ToolingRuntime;
pub const CommandSurface = adapters.command_surface.CommandSurface;
pub const RepoHealthCheckTool = examples.RepoHealthCheckTool;
pub const ScriptMarkdownFetchTool = examples.ScriptMarkdownFetchTool;
pub const ExampleServices = examples.ExampleServices;

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test {
    std.testing.refAllDecls(@This());
}

test "tooling scaffold exports are stable" {
    try std.testing.expectEqualStrings("tooling", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);
    try std.testing.expectEqualStrings("native_zig", ToolExecutionKind.native_zig.asText());
}


