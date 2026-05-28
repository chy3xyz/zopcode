const std = @import("std");
const core = @import("../core/root.zig");

pub const ValidationField = core.validation.ValidationField;
pub const ValidationValue = core.validation.ValidationValue;
pub const ValueKind = core.validation.ValueKind;

pub const ConfigChangeKind = enum {
    added,
    updated,
    unchanged,

    pub fn asText(self: ConfigChangeKind) []const u8 {
        return switch (self) {
            .added => "added",
            .updated => "updated",
            .unchanged => "unchanged",
        };
    }
};

pub const ConfigSideEffectKind = enum {
    none,
    notify_runtime,
    reload_logging,
    refresh_providers,
    restart_required,

    pub fn asText(self: ConfigSideEffectKind) []const u8 {
        return switch (self) {
            .none => "none",
            .notify_runtime => "notify_runtime",
            .reload_logging => "reload_logging",
            .refresh_providers => "refresh_providers",
            .restart_required => "restart_required",
        };
    }
};

pub const ConfigWriteStats = struct {
    applied_count: usize,
    changed_count: usize,
};

pub const ConfigChange = struct {
    path: []u8,
    kind: ConfigChangeKind,
    changed: bool,
    sensitive: bool,
    requires_restart: bool,
    side_effect_kind: ConfigSideEffectKind,
    value_kind: ?ValueKind,
    old_value_json: ?[]u8,
    new_value_json: []u8,

    pub fn deinit(self: *ConfigChange, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.old_value_json) |old_value_json| allocator.free(old_value_json);
        allocator.free(self.new_value_json);
    }
};

pub const ConfigDiffSummary = struct {
    changes: []ConfigChange,
    changed_count: usize,
    requires_restart: bool,

    pub fn deinit(self: *ConfigDiffSummary, allocator: std.mem.Allocator) void {
        for (self.changes) |*change| {
            change.deinit(allocator);
        }
        allocator.free(self.changes);
    }
};

pub const ConfigChangeLogEntry = struct {
    ts_unix_ms: i64,
    path: []u8,
    requires_restart: bool,
    side_effect_kind: ConfigSideEffectKind,
    old_value_json: ?[]u8,
    new_value_json: []u8,

    pub fn deinit(self: *ConfigChangeLogEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        if (self.old_value_json) |old_value_json| allocator.free(old_value_json);
        allocator.free(self.new_value_json);
    }
};

pub const ConfigChangeLog = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        append: *const fn (ptr: *anyopaque, entry: ConfigChangeLogEntry) anyerror!void,
    };

    pub fn append(self: ConfigChangeLog, entry: ConfigChangeLogEntry) anyerror!void {
        return self.vtable.append(self.ptr, entry);
    }
};

pub const ConfigStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        apply_validated_writes: *const fn (ptr: *anyopaque, updates: []const ValidationField) anyerror!ConfigWriteStats,
        read_value_json: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8,
    };

    pub fn applyValidatedWrites(self: ConfigStore, updates: []const ValidationField) anyerror!ConfigWriteStats {
        return self.vtable.apply_validated_writes(self.ptr, updates);
    }

    pub fn readValueJson(self: ConfigStore, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
        return self.vtable.read_value_json(self.ptr, allocator, path);
    }
};

pub const MemoryConfigChangeLog = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(ConfigChangeLogEntry) = .empty,

    const Self = @This();

    const vtable = ConfigChangeLog.VTable{
        .append = appendErased,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn asChangeLog(self: *Self) ConfigChangeLog {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn append(self: *Self, entry: ConfigChangeLogEntry) !void {
        try self.entries.append(self.allocator, .{
            .ts_unix_ms = entry.ts_unix_ms,
            .path = try self.allocator.dupe(u8, entry.path),
            .requires_restart = entry.requires_restart,
            .side_effect_kind = entry.side_effect_kind,
            .old_value_json = if (entry.old_value_json) |old_value_json| try self.allocator.dupe(u8, old_value_json) else null,
            .new_value_json = try self.allocator.dupe(u8, entry.new_value_json),
        });
    }

    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    fn appendErased(ptr: *anyopaque, entry: ConfigChangeLogEntry) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.append(entry);
    }
};

pub const StoredField = struct {
    key: []u8,
    value: StoredValue,

    pub fn deinit(self: *StoredField, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
    }
};

pub const StoredValue = union(enum) {
    string: []u8,
    integer: i64,
    boolean: bool,
    float: f64,
    object: []StoredField,
    array: []StoredValue,
    null: void,

    pub fn cloneFromValidation(allocator: std.mem.Allocator, value: ValidationValue) anyerror!StoredValue {
        return switch (value) {
            .string => |text| .{ .string = try allocator.dupe(u8, text) },
            .integer => |number| .{ .integer = number },
            .boolean => |flag| .{ .boolean = flag },
            .float => |number| .{ .float = number },
            .null => .null,
            .object => |fields| blk: {
                const cloned_fields = try allocator.alloc(StoredField, fields.len);
                errdefer allocator.free(cloned_fields);

                for (fields, 0..) |field, index| {
                    cloned_fields[index] = .{
                        .key = try allocator.dupe(u8, field.key),
                        .value = try cloneFromValidation(allocator, field.value),
                    };
                }

                break :blk .{ .object = cloned_fields };
            },
            .array => |items| blk: {
                const cloned_items = try allocator.alloc(StoredValue, items.len);
                errdefer allocator.free(cloned_items);

                for (items, 0..) |item, index| {
                    cloned_items[index] = try cloneFromValidation(allocator, item);
                }

                break :blk .{ .array = cloned_items };
            },
        };
    }

    pub fn deinit(self: *StoredValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |text| allocator.free(text),
            .object => |fields| {
                for (fields) |*field| {
                    field.deinit(allocator);
                }
                allocator.free(fields);
            },
            .array => |items| {
                for (items) |*item| {
                    item.deinit(allocator);
                }
                allocator.free(items);
            },
            else => {},
        }
    }

    pub fn equalsValidation(self: *const StoredValue, value: ValidationValue) bool {
        return switch (self.*) {
            .string => value == .string and std.mem.eql(u8, self.string, value.string),
            .integer => value == .integer and self.integer == value.integer,
            .boolean => value == .boolean and self.boolean == value.boolean,
            .float => value == .float and self.float == value.float,
            .null => value == .null,
            .object => if (value == .object) objectEquals(self.object, value.object) else false,
            .array => if (value == .array) arrayEquals(self.array, value.array) else false,
        };
    }

    pub fn writeJson(self: *const StoredValue, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) anyerror!void {
        switch (self.*) {
            .string => |text| try writeJsonString(buf, allocator, text),
            .integer => |number| try buf.print(allocator, "{d}", .{number}),
            .boolean => |flag| try buf.appendSlice(allocator, if (flag) "true" else "false"),
            .float => |number| try buf.print(allocator, "{d}", .{number}),
            .null => try buf.appendSlice(allocator, "null"),
            .object => |fields| {
                try buf.append(allocator, '{');
                for (fields, 0..) |field, index| {
                    if (index > 0) {
                        try buf.append(allocator, ',');
                    }
                    try writeJsonString(buf, allocator, field.key);
                    try buf.append(allocator, ':');
                    try field.value.writeJson(buf, allocator);
                }
                try buf.append(allocator, '}');
            },
            .array => |items| {
                try buf.append(allocator, '[');
                for (items, 0..) |item, index| {
                    if (index > 0) {
                        try buf.append(allocator, ',');
                    }
                    try item.writeJson(buf, allocator);
                }
                try buf.append(allocator, ']');
            },
        }
    }
};

pub const MemoryConfigStore = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Self = @This();

    const Entry = struct {
        path: []u8,
        value: StoredValue,

        fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
            allocator.free(self.path);
            self.value.deinit(allocator);
        }
    };

    const vtable = ConfigStore.VTable{
        .apply_validated_writes = applyValidatedWritesErased,
        .read_value_json = readValueJsonErased,
    };

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |*entry| {
            entry.deinit(self.allocator);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn asConfigStore(self: *Self) ConfigStore {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn applyValidatedWrites(self: *Self, updates: []const ValidationField) anyerror!ConfigWriteStats {
        var changed_count: usize = 0;

        for (updates) |update| {
            if (self.findEntryIndex(update.key)) |index| {
                if (!self.entries.items[index].value.equalsValidation(update.value)) {
                    self.entries.items[index].value.deinit(self.allocator);
                    self.entries.items[index].value = try StoredValue.cloneFromValidation(self.allocator, update.value);
                    changed_count += 1;
                }
            } else {
                try self.entries.append(self.allocator, .{
                    .path = try self.allocator.dupe(u8, update.key),
                    .value = try StoredValue.cloneFromValidation(self.allocator, update.value),
                });
                changed_count += 1;
            }
        }

        return .{
            .applied_count = updates.len,
            .changed_count = changed_count,
        };
    }

    pub fn get(self: *const Self, path: []const u8) ?*const StoredValue {
        if (self.findEntryIndex(path)) |index| {
            return &self.entries.items[index].value;
        }
        return null;
    }

    pub fn count(self: *const Self) usize {
        return self.entries.items.len;
    }

    pub fn readValueJson(self: *const Self, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
        const value = self.get(path) orelse return null;
        const json = try serializeStoredValue(allocator, value.*);
        return json;
    }

    fn findEntryIndex(self: *const Self, path: []const u8) ?usize {
        for (self.entries.items, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.path, path)) {
                return index;
            }
        }
        return null;
    }

    fn applyValidatedWritesErased(ptr: *anyopaque, updates: []const ValidationField) anyerror!ConfigWriteStats {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.applyValidatedWrites(updates);
    }

    fn readValueJsonErased(ptr: *anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.readValueJson(allocator, path);
    }
};

pub fn serializeValidationValue(allocator: std.mem.Allocator, value: ValidationValue) anyerror![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try writeValidationValueJson(&buf, allocator, value);
    return allocator.dupe(u8, buf.items);
}

pub fn serializeStoredValue(allocator: std.mem.Allocator, value: StoredValue) anyerror![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try value.writeJson(&buf, allocator);
    return allocator.dupe(u8, buf.items);
}

fn writeValidationValueJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: ValidationValue) anyerror!void {
    switch (value) {
        .string => |text| try writeJsonString(buf, allocator, text),
        .integer => |number| try buf.print(allocator, "{d}", .{number}),
        .boolean => |flag| try buf.appendSlice(allocator, if (flag) "true" else "false"),
        .float => |number| try buf.print(allocator, "{d}", .{number}),
        .null => try buf.appendSlice(allocator, "null"),
        .object => |fields| {
            try buf.append(allocator, '{');
            for (fields, 0..) |field, index| {
                if (index > 0) {
                    try buf.append(allocator, ',');
                }
                try writeJsonString(buf, allocator, field.key);
                try buf.append(allocator, ':');
                try writeValidationValueJson(buf, allocator, field.value);
            }
            try buf.append(allocator, '}');
        },
        .array => |items| {
            try buf.append(allocator, '[');
            for (items, 0..) |item, index| {
                if (index > 0) {
                    try buf.append(allocator, ',');
                }
                try writeValidationValueJson(buf, allocator, item);
            }
            try buf.append(allocator, ']');
        },
    }
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

fn objectEquals(stored: []const StoredField, runtime: []const ValidationField) bool {
    if (stored.len != runtime.len) {
        return false;
    }

    for (stored, runtime) |stored_field, runtime_field| {
        if (!std.mem.eql(u8, stored_field.key, runtime_field.key)) {
            return false;
        }
        if (!stored_field.value.equalsValidation(runtime_field.value)) {
            return false;
        }
    }

    return true;
}

fn arrayEquals(stored: []const StoredValue, runtime: []const ValidationValue) bool {
    if (stored.len != runtime.len) {
        return false;
    }

    for (stored, runtime) |stored_item, runtime_item| {
        if (!stored_item.equalsValidation(runtime_item)) {
            return false;
        }
    }

    return true;
}

test "memory config store writes and updates flat values" {
    var store = MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();

    const first = [_]ValidationField{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
        .{ .key = "gateway.host", .value = .{ .string = "127.0.0.1" } },
    };
    const first_stats = try store.applyValidatedWrites(first[0..]);

    try std.testing.expectEqual(@as(usize, 2), first_stats.applied_count);
    try std.testing.expectEqual(@as(usize, 2), first_stats.changed_count);
    try std.testing.expectEqual(@as(usize, 2), store.count());
    try std.testing.expect(store.get("gateway.port") != null);

    const second = [_]ValidationField{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
        .{ .key = "gateway.host", .value = .{ .string = "0.0.0.0" } },
    };
    const second_stats = try store.applyValidatedWrites(second[0..]);

    try std.testing.expectEqual(@as(usize, 2), second_stats.applied_count);
    try std.testing.expectEqual(@as(usize, 1), second_stats.changed_count);
    try std.testing.expectEqualStrings("0.0.0.0", store.get("gateway.host").?.string);
}

test "memory config store keeps nested object and array values" {
    var store = MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();

    const providers = [_]ValidationValue{
        .{ .string = "openai" },
        .{ .string = "anthropic" },
    };
    const object_fields = [_]ValidationField{
        .{ .key = "enabled", .value = .{ .boolean = true } },
    };
    const updates = [_]ValidationField{
        .{ .key = "providers.list", .value = .{ .array = providers[0..] } },
        .{ .key = "logging.file", .value = .{ .object = object_fields[0..] } },
    };

    _ = try store.applyValidatedWrites(updates[0..]);

    try std.testing.expect(store.get("providers.list").?.array.len == 2);
    try std.testing.expect(store.get("logging.file").?.object.len == 1);
}

test "memory config store can serialize existing values to json" {
    var store = MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();

    _ = try store.applyValidatedWrites(&.{
        .{ .key = "gateway.port", .value = .{ .integer = 8080 } },
    });

    const json = try store.readValueJson(std.testing.allocator, "gateway.port");
    defer if (json) |value| std.testing.allocator.free(value);

    try std.testing.expect(json != null);
    try std.testing.expectEqualStrings("8080", json.?);
}

test "memory config change log stores copied entries" {
    var change_log = MemoryConfigChangeLog.init(std.testing.allocator);
    defer change_log.deinit();

    const path = try std.testing.allocator.dupe(u8, "gateway.port");
    defer std.testing.allocator.free(path);
    const old_value = try std.testing.allocator.dupe(u8, "8000");
    defer std.testing.allocator.free(old_value);
    const new_value = try std.testing.allocator.dupe(u8, "8080");
    defer std.testing.allocator.free(new_value);

    try change_log.append(.{
        .ts_unix_ms = 1,
        .path = path,
        .requires_restart = true,
        .side_effect_kind = .restart_required,
        .old_value_json = old_value,
        .new_value_json = new_value,
    });

    try std.testing.expectEqual(@as(usize, 1), change_log.count());
    try std.testing.expectEqualStrings("gateway.port", change_log.entries.items[0].path);
}


