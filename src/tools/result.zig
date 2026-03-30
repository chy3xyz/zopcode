const std = @import("std");

pub const ToolResult = struct {
    title: []const u8,
    output_text: []const u8,
    metadata_json: []const u8 = "{}",

    pub fn clone(self: ToolResult, allocator: std.mem.Allocator) !ToolResult {
        return .{
            .title = try allocator.dupe(u8, self.title),
            .output_text = try allocator.dupe(u8, self.output_text),
            .metadata_json = try allocator.dupe(u8, self.metadata_json),
        };
    }

    pub fn deinit(self: *ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.output_text);
        allocator.free(self.metadata_json);
    }

    pub fn toJson(self: ToolResult, allocator: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        defer buf.deinit(allocator);
        const writer = buf.writer(allocator);

        try writer.writeAll("{\"title\":");
        try writeJsonString(writer, self.title);
        try writer.writeAll(",\"output_text\":");
        try writeJsonString(writer, self.output_text);
        try writer.writeAll(",\"metadata\":");
        try writer.writeAll(self.metadata_json);
        try writer.writeByte('}');

        return allocator.dupe(u8, buf.items);
    }
};

fn writeJsonString(writer: anytype, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |ch| {
        switch (ch) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => {
                if (ch < 32) {
                    try writer.print("\\u00{x:0>2}", .{ch});
                } else {
                    try writer.writeByte(ch);
                }
            },
        }
    }
    try writer.writeByte('"');
}

test "tool result serializes to json" {
    const json = try (ToolResult{
        .title = "read_file",
        .output_text = "hello",
        .metadata_json = "{\"path\":\"src/main.zig\"}",
    }).toJson(std.testing.allocator);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"title\":\"read_file\"") != null);
}
