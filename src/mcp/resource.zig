const std = @import("std");
const types = @import("types.zig");

pub const ResourceInfo = types.ResourceInfo;
pub const ResourceContent = types.ResourceContent;

pub fn renderList(allocator: std.mem.Allocator, items: []const types.ResourceInfo) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeByte('\n');
        try writer.print("[{s}] {s} ({s})", .{ item.server_id, item.name, item.uri });
    }

    return allocator.dupe(u8, out.items);
}

test "resource list renderer includes server and uri" {
    const items = [_]types.ResourceInfo{
        .{
            .server_id = "docs",
            .uri = "mcp://docs/readme",
            .name = "README",
        },
    };

    const rendered = try renderList(std.testing.allocator, items[0..]);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "mcp://docs/readme") != null);
}
