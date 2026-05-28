const std = @import("std");
const mcp = @import("root.zig");

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    transport: mcp.Transport = .stdio,
    next_id: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) McpClient {
        return .{ .allocator = allocator };
    }

    /// Build a JSON-RPC request for tools/list.
    pub fn buildListToolsRequest(self: *McpClient) mcp.JsonRpcRequest {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .id = id, .method = "tools/list" };
    }

    /// Build a JSON-RPC request for tools/call.
    pub fn buildCallToolRequest(self: *McpClient, name: []const u8, arguments: []const u8) mcp.JsonRpcRequest {
        const id = self.next_id;
        self.next_id += 1;
        return .{ .id = id, .method = "tools/call", .params = arguments };
        // TODO: encode name + arguments as proper MCP params JSON
        _ = name;
    }

    pub fn deinit(_: *McpClient) void {}
};

test "client builds list request" {
    var c = McpClient.init(std.testing.allocator);
    const req = c.buildListToolsRequest();
    try std.testing.expectEqualStrings("tools/list", req.method);
    try std.testing.expectEqual(@as(u64, 1), req.id);
    const req2 = c.buildListToolsRequest();
    try std.testing.expectEqual(@as(u64, 2), req2.id);
}
