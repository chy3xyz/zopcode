const std = @import("std");
const types = @import("types.zig");

pub fn toJson(allocator: std.mem.Allocator, result: types.AggregatedResult) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeAll("{\"batch_id\":");
    try writeJsonString(writer, result.batch_id);
    try writer.writeAll(",\"parent_session_id\":");
    try writeJsonString(writer, result.parent_session_id);
    try writer.writeAll(",\"summary\":");
    try writeJsonString(writer, result.summary);
    try writer.print(",\"success_count\":{d}", .{result.success_count});
    try writer.print(",\"failure_count\":{d}", .{result.failure_count});
    try writer.writeAll(",\"items\":[");
    for (result.items, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"child_session_id\":");
        try writeJsonString(writer, item.child_session_id);
        try writer.writeAll(",\"agent_id\":");
        try writeJsonString(writer, item.agent_id);
        try writer.writeAll(",\"status\":");
        try writeJsonString(writer, item.status);
        try writer.writeAll(",\"request_id\":");
        try writeJsonString(writer, item.request_id);
        try writer.writeAll(",\"task_id\":");
        try writeJsonString(writer, item.task_id);
        try writer.writeAll(",\"summary\":");
        try writeJsonString(writer, item.summary);
        try writer.writeByte('}');
    }
    try writer.writeAll("]}");
    return allocator.dupe(u8, buf.items);
}

pub fn childResultsJson(allocator: std.mem.Allocator, items: []const types.ChildResult) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const writer = buf.writer(allocator);

    try writer.writeByte('[');
    for (items, 0..) |item, index| {
        if (index > 0) try writer.writeByte(',');
        try writer.writeAll("{\"child_session_id\":");
        try writeJsonString(writer, item.child_session_id);
        try writer.writeAll(",\"agent_id\":");
        try writeJsonString(writer, item.agent_id);
        try writer.writeAll(",\"status\":");
        try writeJsonString(writer, item.status);
        try writer.writeAll(",\"request_id\":");
        try writeJsonString(writer, item.request_id);
        try writer.writeAll(",\"task_id\":");
        try writeJsonString(writer, item.task_id);
        try writer.writeAll(",\"summary\":");
        try writeJsonString(writer, item.summary);
        try writer.writeByte('}');
    }
    try writer.writeByte(']');
    return allocator.dupe(u8, buf.items);
}

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

test "aggregated result renders stable json" {
    var items = [_]types.ChildResult{.{
        .child_session_id = "child_01",
        .agent_id = "build",
        .status = "completed",
        .request_id = "req_01",
        .task_id = "task_01",
        .summary = "done",
    }};
    const rendered = try toJson(std.testing.allocator, .{
        .batch_id = "batch_01",
        .parent_session_id = "parent_01",
        .summary = "all done",
        .success_count = 1,
        .failure_count = 0,
        .items = items[0..],
    });
    defer std.testing.allocator.free(rendered);

    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"child_session_id\":\"child_01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "\"batch_id\":\"batch_01\"") != null);
}
