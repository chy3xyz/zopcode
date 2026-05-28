const std = @import("std");
const core = @import("../core/root.zig");
const parser = @import("parser.zig");
const store_model = @import("store.zig");

pub const ValidationField = core.validation.ValidationField;
pub const ValueKind = core.validation.ValueKind;
pub const ConfigStore = store_model.ConfigStore;
pub const ConfigWriteStats = store_model.ConfigWriteStats;

pub const ConfigDefaultEntry = struct {
    path: []const u8,
    value_kind: ValueKind,
    value_json: []const u8,
};

pub const ConfigDefaults = struct {
    entries: []const ConfigDefaultEntry,

    pub fn find(self: ConfigDefaults, path: []const u8) ?ConfigDefaultEntry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry;
        }
        return null;
    }

    pub fn valueJson(self: ConfigDefaults, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
        const entry = self.find(path) orelse return null;
        const owned = try allocator.dupe(u8, entry.value_json);
        return owned;
    }

    pub fn applyToStore(self: ConfigDefaults, allocator: std.mem.Allocator, store: ConfigStore) anyerror!ConfigWriteStats {
        const fields = try allocator.alloc(ValidationField, self.entries.len);
        defer {
            for (fields) |field| field.deinit(allocator);
            allocator.free(fields);
        }

        for (self.entries, 0..) |entry, index| {
            fields[index] = .{
                .key = try allocator.dupe(u8, entry.path),
                .value = try parser.ConfigValueParser.parseJsonValue(allocator, entry.value_kind, entry.value_json),
            };
        }

        return store.applyValidatedWrites(fields);
    }
};

test "config defaults exposes json values by path" {
    const defaults = ConfigDefaults{ .entries = &.{
        .{ .path = "gateway.port", .value_kind = .integer, .value_json = "8080" },
    } };

    const json = try defaults.valueJson(std.testing.allocator, "gateway.port");
    defer if (json) |owned| std.testing.allocator.free(owned);
    try std.testing.expect(json != null);
    try std.testing.expectEqualStrings("8080", json.?);
}

test "config defaults can seed store" {
    var store = store_model.MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();

    const defaults = ConfigDefaults{ .entries = &.{
        .{ .path = "gateway.host", .value_kind = .string, .value_json = "\"127.0.0.1\"" },
        .{ .path = "gateway.port", .value_kind = .integer, .value_json = "8080" },
    } };

    const stats = try defaults.applyToStore(std.testing.allocator, store.asConfigStore());
    try std.testing.expectEqual(@as(usize, 2), stats.applied_count);
    try std.testing.expectEqualStrings("127.0.0.1", store.get("gateway.host").?.string);
}


