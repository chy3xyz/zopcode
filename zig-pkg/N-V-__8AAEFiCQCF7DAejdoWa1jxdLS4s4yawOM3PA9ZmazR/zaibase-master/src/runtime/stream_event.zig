const std = @import("std");

pub fn renderJsonEvent(allocator: std.mem.Allocator, event_name: []const u8, seq: u64, data_json: []const u8) anyerror![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '{');
    try appendJsonStringField(&buf, allocator, "event", event_name, true);
    if (seq > 0) try appendJsonUnsignedField(&buf, allocator, "seq", seq, false);
    try appendRawJsonField(&buf, allocator, "data", data_json, false);
    try buf.append(allocator, '}');
    return allocator.dupe(u8, buf.items);
}

fn appendJsonStringField(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8, first: bool) anyerror!void {
    if (!first) try buf.append(allocator, ',');
    try writeJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try writeJsonString(buf, allocator, value);
}

fn appendJsonUnsignedField(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: u64, first: bool) anyerror!void {
    if (!first) try buf.append(allocator, ',');
    try writeJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try buf.print(allocator, "{d}", .{value});
}

fn appendRawJsonField(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8, first: bool) anyerror!void {
    if (!first) try buf.append(allocator, ',');
    try writeJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try buf.appendSlice(allocator, value);
}

fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) anyerror!void {
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

test "render json event keeps event data shape" {
    const json = try renderJsonEvent(std.testing.allocator, "meta", 7, "{\"ok\":true}");
    defer std.testing.allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"event\":\"meta\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"seq\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"data\":{\"ok\":true}") != null);
}
