const std = @import("std");
const defaults_model = @import("defaults.zig");
const store_model = @import("store.zig");

pub const ConfigDefaults = defaults_model.ConfigDefaults;
pub const ConfigStore = store_model.ConfigStore;
pub const ValidationField = @import("../core/root.zig").validation.ValidationField;
pub const FieldDefinition = @import("../core/root.zig").validation.FieldDefinition;
pub const ValidationValue = @import("../core/root.zig").validation.ValidationValue;
const parser = @import("parser.zig");

pub const EnvPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const ConfigValueSource = enum {
    runtime_store,
    bootstrap_default,
    unset,

    pub fn asText(self: ConfigValueSource) []const u8 {
        return switch (self) {
            .runtime_store => "runtime_store",
            .bootstrap_default => "bootstrap_default",
            .unset => "unset",
        };
    }

    pub fn hint(self: ConfigValueSource) []const u8 {
        return switch (self) {
            .runtime_store => "present in runtime config store",
            .bootstrap_default => "seeded by bootstrap defaults",
            .unset => "field is currently unset",
        };
    }
};

pub const LoadedConfigValue = struct {
    current_value_json: ?[]u8,
    default_value_json: ?[]u8,
    source: ConfigValueSource,

    pub fn deinit(self: *LoadedConfigValue, allocator: std.mem.Allocator) void {
        if (self.current_value_json) |owned| allocator.free(owned);
        if (self.default_value_json) |owned| allocator.free(owned);
    }

    pub fn effectiveValueJson(self: *const LoadedConfigValue) ?[]const u8 {
        return self.current_value_json orelse self.default_value_json;
    }

    pub fn present(self: *const LoadedConfigValue) bool {
        return self.current_value_json != null;
    }
};

pub const ConfigLoader = struct {
    allocator: std.mem.Allocator,
    store: ConfigStore,
    defaults: ConfigDefaults,

    pub fn init(allocator: std.mem.Allocator, store: ConfigStore, defaults: ConfigDefaults) ConfigLoader {
        return .{ .allocator = allocator, .store = store, .defaults = defaults };
    }

    pub fn loadValue(self: ConfigLoader, path: []const u8) anyerror!LoadedConfigValue {
        const current_value_json = try self.store.readValueJson(self.allocator, path);
        const default_value_json = try self.defaults.valueJson(self.allocator, path);
        const source: ConfigValueSource = blk: {
            if (current_value_json) |current| {
                if (default_value_json) |default_value| {
                    if (std.mem.eql(u8, current, default_value)) break :blk .bootstrap_default;
                }
                break :blk .runtime_store;
            }
            if (default_value_json != null) break :blk .bootstrap_default;
            break :blk .unset;
        };

        return .{
            .current_value_json = current_value_json,
            .default_value_json = default_value_json,
            .source = source,
        };
    }

    pub fn loadSnapshotJson(allocator: std.mem.Allocator, json_text: []const u8, definitions: []const FieldDefinition) anyerror![]ValidationField {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidConfigSnapshot;

        var fields: std.ArrayListUnmanaged(ValidationField) = .empty;
        errdefer {
            for (fields.items) |field| field.deinit(allocator);
            fields.deinit(allocator);
        }
        try appendSnapshotObject(allocator, &fields, parsed.value.object, definitions, "");
        return fields.toOwnedSlice(allocator);
    }

    pub fn loadSnapshotFile(allocator: std.mem.Allocator, file_path: []const u8, definitions: []const FieldDefinition) anyerror![]ValidationField {
        const json_text = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), file_path, allocator, std.Io.Limit.limited(1024 * 1024));
        defer allocator.free(json_text);
        return loadSnapshotJson(allocator, json_text, definitions);
    }

    pub fn loadEnvOverrides(allocator: std.mem.Allocator, _: []const FieldDefinition, _: []const u8) anyerror![]ValidationField {
        return allocator.alloc(ValidationField, 0);
    }

    pub fn loadEnvOverridesFromPairs(allocator: std.mem.Allocator, definitions: []const FieldDefinition, prefix: []const u8, pairs: []const EnvPair) anyerror![]ValidationField {
        var fields: std.ArrayListUnmanaged(ValidationField) = .empty;
        errdefer {
            for (fields.items) |field| field.deinit(allocator);
            fields.deinit(allocator);
        }

        for (definitions) |definition| {
            const env_name = try envNameForPath(allocator, prefix, definition.key);
            defer allocator.free(env_name);
            const value = findEnvValue(pairs, env_name) orelse continue;
            const parsed_value = try parser.ConfigValueParser.parseRawValue(allocator, definition.value_kind, value);
            try fields.append(allocator, .{ .key = try allocator.dupe(u8, definition.key), .value = parsed_value });
        }

        return fields.toOwnedSlice(allocator);
    }
};

fn appendSnapshotObject(
    allocator: std.mem.Allocator,
    fields: *std.ArrayListUnmanaged(ValidationField),
    object: std.json.ObjectMap,
    definitions: []const FieldDefinition,
    prefix: []const u8,
) anyerror!void {
    var iterator = object.iterator();
    while (iterator.next()) |entry| {
        const full_key = if (prefix.len == 0)
            try allocator.dupe(u8, entry.key_ptr.*)
        else
            try std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, entry.key_ptr.* });
        defer allocator.free(full_key);

        if (findDefinition(definitions, full_key)) |definition| {
            const parsed_value = try parser.ConfigValueParser.parseJsonStdValue(allocator, definition.value_kind, entry.value_ptr.*);
            try fields.append(allocator, .{ .key = try allocator.dupe(u8, full_key), .value = parsed_value });
            continue;
        }

        if (entry.value_ptr.* == .object) {
            try appendSnapshotObject(allocator, fields, entry.value_ptr.*.object, definitions, full_key);
        }
    }
}

fn findDefinition(definitions: []const FieldDefinition, key: []const u8) ?FieldDefinition {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.key, key)) return definition;
    }
    return null;
}

fn envNameForPath(allocator: std.mem.Allocator, prefix: []const u8, path: []const u8) anyerror![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    for (prefix) |ch| try buf.append(allocator, std.ascii.toUpper(ch));
    if (prefix.len > 0) try buf.append(allocator, '_');
    for (path) |ch| {
        if (ch == '.') {
            try buf.append(allocator, '_');
        } else {
            try buf.append(allocator, std.ascii.toUpper(ch));
        }
    }
    return allocator.dupe(u8, buf.items);
}

fn findEnvValue(pairs: []const EnvPair, name: []const u8) ?[]const u8 {
    for (pairs) |pair| {
        if (std.mem.eql(u8, pair.name, name)) return pair.value;
    }
    return null;
}

test "config loader resolves runtime value before default" {
    var store = store_model.MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.applyValidatedWrites(&.{
        .{ .key = "gateway.host", .value = .{ .string = "0.0.0.0" } },
    });

    const defaults = ConfigDefaults{ .entries = &.{
        .{ .path = "gateway.host", .value_kind = .string, .value_json = "\"127.0.0.1\"" },
    } };

    var loaded = try ConfigLoader.init(std.testing.allocator, store.asConfigStore(), defaults).loadValue("gateway.host");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(ConfigValueSource.runtime_store, loaded.source);
    try std.testing.expectEqualStrings("\"0.0.0.0\"", loaded.effectiveValueJson().?);
}

test "config loader preserves bootstrap default source when runtime value matches default" {
    var store = store_model.MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();
    _ = try store.applyValidatedWrites(&.{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
    });

    const defaults = ConfigDefaults{ .entries = &.{
        .{ .path = "gateway.port", .value_kind = .integer, .value_json = "8080" },
    } };

    var loaded = try ConfigLoader.init(std.testing.allocator, store.asConfigStore(), defaults).loadValue("gateway.port");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(ConfigValueSource.bootstrap_default, loaded.source);
}

test "config loader falls back to bootstrap default" {
    var store = store_model.MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();

    const defaults = ConfigDefaults{ .entries = &.{
        .{ .path = "gateway.port", .value_kind = .integer, .value_json = "8080" },
    } };

    var loaded = try ConfigLoader.init(std.testing.allocator, store.asConfigStore(), defaults).loadValue("gateway.port");
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(ConfigValueSource.bootstrap_default, loaded.source);
    try std.testing.expectEqualStrings("8080", loaded.effectiveValueJson().?);
}

test "config loader can flatten json snapshot file structure" {
    const definitions = [_]FieldDefinition{
        .{ .key = "gateway.host", .value_kind = .string },
        .{ .key = "gateway.port", .value_kind = .integer },
        .{ .key = "logging.file.enabled", .value_kind = .boolean },
    };
    const fields = try ConfigLoader.loadSnapshotJson(std.testing.allocator, "{\"gateway\":{\"host\":\"0.0.0.0\",\"port\":9090},\"logging\":{\"file\":{\"enabled\":true}}}", definitions[0..]);
    defer {
        for (fields) |field| field.deinit(std.testing.allocator);
        std.testing.allocator.free(fields);
    }
    try std.testing.expectEqual(@as(usize, 3), fields.len);
}

test "config loader can read env overrides" {
    const definitions = [_]FieldDefinition{
        .{ .key = "gateway.port", .value_kind = .integer },
        .{ .key = "logging.file.enabled", .value_kind = .boolean },
    };
    const pairs = [_]EnvPair{
        .{ .name = "OURCLAW_GATEWAY_PORT", .value = "9191" },
    };
    const fields = try ConfigLoader.loadEnvOverridesFromPairs(std.testing.allocator, definitions[0..], "ourclaw", pairs[0..]);
    defer {
        for (fields) |field| field.deinit(std.testing.allocator);
        std.testing.allocator.free(fields);
    }
    try std.testing.expectEqual(@as(usize, 1), fields.len);
    try std.testing.expectEqualStrings("gateway.port", fields[0].key);
    try std.testing.expectEqual(@as(i64, 9191), fields[0].value.integer);
}


