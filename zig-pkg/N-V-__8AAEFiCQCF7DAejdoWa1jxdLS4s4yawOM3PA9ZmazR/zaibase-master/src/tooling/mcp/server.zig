const std = @import("std");
const mcp = @import("root.zig");

pub const McpServer = struct {
    allocator: std.mem.Allocator,
    tools: std.ArrayListUnmanaged(mcp.ToolDefinition) = .empty,

    pub fn init(allocator: std.mem.Allocator) McpServer {
        return .{ .allocator = allocator };
    }

    /// Register a tool that this server exposes.
    pub fn registerTool(self: *McpServer, tool: mcp.ToolDefinition) !void {
        try self.tools.append(self.allocator, tool);
    }

    /// Handle a JSON-RPC request and return a response.
    pub fn handleRequest(self: *McpServer, request: mcp.JsonRpcRequest) mcp.JsonRpcResponse {
        if (std.mem.eql(u8, request.method, "tools/list")) {
            // TODO: serialize self.tools as JSON result
            return .{ .id = request.id, .result = "[]" };
        }
        return .{
            .id = request.id,
            .@"error" = .{ .code = -32601, .message = "Method not found" },
        };
    }

    pub fn deinit(self: *McpServer) void {
        self.tools.deinit(self.allocator);
    }
};

test "server registers tool and handles list" {
    var s = McpServer.init(std.testing.allocator);
    defer s.deinit();
    try s.registerTool(.{ .name = "echo", .description = "Echo input", .input_schema = "{}" });
    try std.testing.expectEqual(@as(usize, 1), s.tools.items.len);

    const resp = s.handleRequest(.{ .id = 1, .method = "tools/list" });
    try std.testing.expectEqual(@as(u64, 1), resp.id);
    try std.testing.expect(resp.@"error" == null);
}

test "server returns error for unknown method" {
    var s = McpServer.init(std.testing.allocator);
    defer s.deinit();
    const resp = s.handleRequest(.{ .id = 1, .method = "unknown/method" });
    try std.testing.expect(resp.@"error" != null);
    try std.testing.expectEqual(@as(i32, -32601), resp.@"error".?.code);
}
