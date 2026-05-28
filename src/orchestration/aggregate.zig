const std = @import("std");
const types = @import("types.zig");

pub fn toJson(allocator: std.mem.Allocator, result: types.AggregatedResult) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"batch_id\":");
    try writeJsonString(&buf, allocator, result.batch_id);
    try buf.appendSlice(allocator, ",\"parent_session_id\":");
    try writeJsonString(&buf, allocator, result.parent_session_id);
    try buf.appendSlice(allocator, ",\"summary\":");
    try writeJsonString(&buf, allocator, result.summary);
    try buf.print(allocator, ",\"success_count\":{d}", .{result.success_count});
    try buf.print(allocator, ",\"failure_count\":{d}", .{result.failure_count});
    try buf.appendSlice(allocator, ",\"items\":[");
    for (result.items, 0..) |item, index| {
        if (index > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"child_session_id\":");
        try writeJsonString(&buf, allocator, item.child_session_id);
        try buf.appendSlice(allocator, ",\"agent_id\":");
        try writeJsonString(&buf, allocator, item.agent_id);
        try buf.appendSlice(allocator, ",\"status\":");
        try writeJsonString(&buf, allocator, item.status);
        try buf.appendSlice(allocator, ",\"request_id\":");
        try writeJsonString(&buf, allocator, item.request_id);
        try buf.appendSlice(allocator, ",\"task_id\":");
        try writeJsonString(&buf, allocator, item.task_id);
        try buf.appendSlice(allocator, ",\"summary\":");
        try writeJsonString(&buf, allocator, item.summary);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
    return allocator.dupe(u8, buf.items);
}

pub fn childResultsJson(allocator: std.mem.Allocator, items: []const types.ChildResult) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.append(allocator, '[');
    for (items, 0..) |item, index| {
        if (index > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"child_session_id\":");
        try writeJsonString(&buf, allocator, item.child_session_id);
        try buf.appendSlice(allocator, ",\"agent_id\":");
        try writeJsonString(&buf, allocator, item.agent_id);
        try buf.appendSlice(allocator, ",\"status\":");
        try writeJsonString(&buf, allocator, item.status);
        try buf.appendSlice(allocator, ",\"request_id\":");
        try writeJsonString(&buf, allocator, item.request_id);
        try buf.appendSlice(allocator, ",\"task_id\":");
        try writeJsonString(&buf, allocator, item.task_id);
        try buf.appendSlice(allocator, ",\"summary\":");
        try writeJsonString(&buf, allocator, item.summary);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    return allocator.dupe(u8, buf.items);
}

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
