const std = @import("std");

pub const CapabilityGroup = struct {
    key: []const u8,
    items: []const []const u8 = &.{},
};

pub const CapabilityFlag = struct {
    key: []const u8,
    enabled: bool,
};

pub const CapabilityManifest = struct {
    groups: []const CapabilityGroup = &.{},
    flags: []const CapabilityFlag = &.{},
};

test "capability manifest keeps group and flag slices" {
    const groups = [_]CapabilityGroup{
        .{ .key = "adapters", .items = &.{ "cli", "http" } },
        .{ .key = "providers", .items = &.{"openai"} },
    };
    const flags = [_]CapabilityFlag{
        .{ .key = "supportsAsyncTasks", .enabled = true },
        .{ .key = "supportsObservers", .enabled = true },
    };

    const manifest = CapabilityManifest{
        .groups = groups[0..],
        .flags = flags[0..],
    };

    try std.testing.expectEqual(@as(usize, 2), manifest.groups.len);
    try std.testing.expectEqual(@as(usize, 2), manifest.flags.len);
    try std.testing.expectEqualStrings("adapters", manifest.groups[0].key);
    try std.testing.expect(manifest.flags[0].enabled);
}


