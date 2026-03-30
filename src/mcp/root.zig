const std = @import("std");

pub const MODULE_NAME = "mcp";

pub const types = @import("types.zig");
pub const resource = @import("resource.zig");
pub const transport = @import("transport.zig");
pub const runtime = @import("runtime.zig");
pub const tool_adapter = @import("tool_adapter.zig");

pub const StatusKind = types.StatusKind;
pub const Status = types.Status;
pub const ToolInfo = types.ToolInfo;
pub const ResourceInfo = types.ResourceInfo;
pub const ResourceContent = types.ResourceContent;
pub const ToolCallResult = types.ToolCallResult;
pub const McpClient = transport.McpClient;
pub const ClientFactory = transport.ClientFactory;
pub const StdioMcpClient = transport.StdioMcpClient;
pub const McpRuntime = runtime.McpRuntime;
pub const McpRuntimeDependencies = runtime.Dependencies;
pub const MCP_UPDATED_EVENT_TOPIC = runtime.MCP_UPDATED_EVENT_TOPIC;

test "mcp module exports are available" {
    try std.testing.expectEqualStrings("mcp", MODULE_NAME);
}
