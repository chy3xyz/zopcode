const std = @import("std");
const contracts = @import("../contracts/root.zig");

pub fn renderCapabilityManifestJson(allocator: std.mem.Allocator, manifest: contracts.capability_manifest.CapabilityManifest) anyerror![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try writeCapabilityManifestJson(&buf, allocator, manifest);
    return allocator.dupe(u8, buf.items);
}

pub fn writeCapabilityManifestJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, manifest: contracts.capability_manifest.CapabilityManifest) anyerror!void {
    try buf.append(allocator, '{');
    var first = true;
    for (manifest.groups) |group| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try writeJsonString(buf, allocator, group.key);
        try buf.append(allocator, ':');
        try buf.append(allocator, '[');
        for (group.items, 0..) |item, index| {
            if (index > 0) try buf.append(allocator, ',');
            try writeJsonString(buf, allocator, item);
        }
        try buf.append(allocator, ']');
    }
    for (manifest.flags) |flag| {
        if (!first) try buf.append(allocator, ',');
        first = false;
        try writeJsonString(buf, allocator, flag.key);
        try buf.append(allocator, ':');
        try buf.appendSlice(allocator, if (flag.enabled) "true" else "false");
    }
    try buf.append(allocator, '}');
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

test "runtime helper renders capability manifest json" {
    const groups = [_]contracts.capability_manifest.CapabilityGroup{
        .{ .key = "adapters", .items = &.{ "cli", "http" } },
        .{ .key = "providers", .items = &.{"openai"} },
    };
    const flags = [_]contracts.capability_manifest.CapabilityFlag{
        .{ .key = "supportsAsyncTasks", .enabled = true },
        .{ .key = "supportsObservers", .enabled = false },
    };
    const manifest = contracts.capability_manifest.CapabilityManifest{
        .groups = groups[0..],
        .flags = flags[0..],
    };

    const json = try renderCapabilityManifestJson(std.testing.allocator, manifest);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"adapters\":[\"cli\",\"http\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"supportsAsyncTasks\":true") != null);
}
