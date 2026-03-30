const std = @import("std");

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);
    try writer.print("{f}", .{std.json.fmt(value, .{})});
    return allocator.dupe(u8, buf.items);
}
