const std = @import("std");
const anchor = @import("anchor.zig");

pub fn renderHashlineRead(allocator: std.mem.Allocator, contents: []const u8) ![]u8 {
    const normalized = if (contents.len > 0 and contents[contents.len - 1] == '\n')
        contents[0 .. contents.len - 1]
    else
        contents;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    var lines = std.mem.splitScalar(u8, normalized, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (line_no > 1) try writer.writeByte('\n');
        const formatted = try anchor.formatReadLine(allocator, line_no, std.mem.trimRight(u8, line, "\r"));
        defer allocator.free(formatted);
        try writer.writeAll(formatted);
    }

    return allocator.dupe(u8, out.items);
}

test "hashline read output preserves original content segment" {
    const rendered = try renderHashlineRead(std.testing.allocator, "alpha\nbeta");
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "|alpha") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "|beta") != null);
}
