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
    
        try buf.appendSlice(allocator, "{\"title\":");
        try writeJsonString(&buf, allocator, self.title);
        try buf.appendSlice(allocator, ",\"output_text\":");
        try writeJsonString(&buf, allocator, self.output_text);
        try buf.appendSlice(allocator, ",\"metadata\":");
        try buf.appendSlice(allocator, self.metadata_json);
        try buf.append(allocator, '}');

        return allocator.dupe(u8, buf.items);
    }
};

fn writeJsonString(buf: anytype, allocator: std.mem.Allocator, value: []const u8) !void {
    try buf.append(allocator, '"');
    for (value) |ch| {
        switch (ch) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 32) {
                    try buf.print(allocator, "\\u00{x:0>2}", .{ch});
                } else {
                    try buf.append(allocator, ch);
                }
            },
        }
    }
    try buf.append(allocator, '"');
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
