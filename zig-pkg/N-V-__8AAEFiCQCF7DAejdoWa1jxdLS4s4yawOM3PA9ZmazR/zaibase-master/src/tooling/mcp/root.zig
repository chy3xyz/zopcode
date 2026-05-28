const std = @import("std");

pub const client = @import("client.zig");
pub const server = @import("server.zig");

pub const McpClient = client.McpClient;
pub const McpServer = server.McpServer;

/// MCP JSON-RPC message types (MCP spec 2025-03-26).
pub const JsonRpcRequest = struct {
    jsonrpc: []const u8 = "2.0",
    id: u64,
    method: []const u8,
    params: ?[]const u8 = null,
};

pub const JsonRpcResponse = struct {
    jsonrpc: []const u8 = "2.0",
    id: u64,
    result: ?[]const u8 = null,
    @"error": ?JsonRpcError = null,
};

pub const JsonRpcError = struct {
    code: i32,
    message: []const u8,
    data: ?[]const u8 = null,
};

/// MCP tool definition — what a server advertises.
pub const ToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema: []const u8,
};

/// MCP tool call result.
pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

/// MCP transport kind.
pub const Transport = enum {
    stdio,
    http,
};

test {
    std.testing.refAllDecls(@This());
}

test "JsonRpcRequest defaults" {
    const req = JsonRpcRequest{ .id = 1, .method = "tools/list" };
    try std.testing.expectEqualStrings("2.0", req.jsonrpc);
    try std.testing.expectEqualStrings("tools/list", req.method);
}
