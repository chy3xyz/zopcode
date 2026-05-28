const std = @import("std");
const core = @import("../core/root.zig");

pub const ValueKind = core.validation.ValueKind;
pub const ValidationValue = core.validation.ValidationValue;

pub const ConfigValueParser = struct {
    pub fn parseRawValue(allocator: std.mem.Allocator, kind: ValueKind, raw: []const u8) anyerror!ValidationValue {
        if (kind == .object or kind == .array) {
            return parseJsonValue(allocator, kind, raw);
        }
        return switch (kind) {
            .string, .enum_string => .{ .string = try allocator.dupe(u8, raw) },
            .integer => .{ .integer = try std.fmt.parseInt(i64, raw, 10) },
            .boolean => .{ .boolean = try parseBoolean(raw) },
            .float => .{ .float = try std.fmt.parseFloat(f64, raw) },
            .object, .array => error.UnsupportedValueKind,
        };
    }

    pub fn parseJsonValue(allocator: std.mem.Allocator, kind: ValueKind, raw_json: []const u8) anyerror!ValidationValue {
        const trimmed = std.mem.trim(u8, raw_json, " \t\r\n");
        return switch (kind) {
            .string, .enum_string => .{ .string = try parseJsonString(allocator, trimmed) },
            .integer => .{ .integer = try std.fmt.parseInt(i64, trimmed, 10) },
            .boolean => .{ .boolean = try parseBoolean(trimmed) },
            .float => .{ .float = try std.fmt.parseFloat(f64, trimmed) },
            .object => try parseJsonObjectValue(allocator, trimmed),
            .array => try parseJsonArrayValue(allocator, trimmed),
        };
    }

    pub fn parseJsonStdValue(allocator: std.mem.Allocator, kind: ValueKind, value: std.json.Value) anyerror!ValidationValue {
        return switch (kind) {
            .string, .enum_string => switch (value) {
                .string => |text| .{ .string = try allocator.dupe(u8, text) },
                else => error.InvalidJsonString,
            },
            .integer => switch (value) {
                .integer => |number| .{ .integer = number },
                else => error.InvalidJsonInteger,
            },
            .boolean => switch (value) {
                .bool => |flag| .{ .boolean = flag },
                else => error.InvalidBooleanValue,
            },
            .float => switch (value) {
                .float => |number| .{ .float = number },
                .integer => |number| .{ .float = @floatFromInt(number) },
                else => error.InvalidJsonFloat,
            },
            .object => switch (value) {
                .object => try convertJsonValue(allocator, value),
                else => error.InvalidJsonObject,
            },
            .array => switch (value) {
                .array => try convertJsonValue(allocator, value),
                else => error.InvalidJsonArray,
            },
        };
    }
};

fn parseJsonObjectValue(allocator: std.mem.Allocator, raw_json: []const u8) anyerror!ValidationValue {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJsonObject;
    return convertJsonValue(allocator, parsed.value);
}

fn parseJsonArrayValue(allocator: std.mem.Allocator, raw_json: []const u8) anyerror!ValidationValue {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw_json, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidJsonArray;
    return convertJsonValue(allocator, parsed.value);
}

fn convertJsonValue(allocator: std.mem.Allocator, value: std.json.Value) anyerror!ValidationValue {
    return switch (value) {
        .null => .null,
        .bool => |flag| .{ .boolean = flag },
        .integer => |number| .{ .integer = number },
        .float => |number| .{ .float = number },
        .number_string => |number| .{ .float = try std.fmt.parseFloat(f64, number) },
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .array => |items| blk: {
            const converted = try allocator.alloc(ValidationValue, items.items.len);
            errdefer allocator.free(converted);
            for (items.items, 0..) |item, index| {
                converted[index] = try convertJsonValue(allocator, item);
            }
            break :blk .{ .array = converted };
        },
        .object => |object| blk: {
            const fields = try allocator.alloc(core.validation.ValidationField, object.count());
            errdefer allocator.free(fields);
            var iterator = object.iterator();
            var index: usize = 0;
            while (iterator.next()) |entry| : (index += 1) {
                fields[index] = .{
                    .key = try allocator.dupe(u8, entry.key_ptr.*),
                    .value = try convertJsonValue(allocator, entry.value_ptr.*),
                };
            }
            break :blk .{ .object = fields };
        },
    };
}

fn parseBoolean(raw: []const u8) anyerror!bool {
    if (std.mem.eql(u8, raw, "true")) return true;
    if (std.mem.eql(u8, raw, "false")) return false;
    return error.InvalidBooleanValue;
}

fn parseJsonString(allocator: std.mem.Allocator, raw_json: []const u8) anyerror![]u8 {
    if (raw_json.len < 2 or raw_json[0] != '"' or raw_json[raw_json.len - 1] != '"') {
        return error.InvalidJsonString;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    var index: usize = 1;
    while (index + 1 < raw_json.len) : (index += 1) {
        const ch = raw_json[index];
        if (ch == '\\') {
            index += 1;
            if (index >= raw_json.len - 1) return error.InvalidJsonString;
            const next = raw_json[index];
            switch (next) {
                '"' => try buf.append(allocator, '"'),
                '\\' => try buf.append(allocator, '\\'),
                'n' => try buf.append(allocator, '\n'),
                'r' => try buf.append(allocator, '\r'),
                't' => try buf.append(allocator, '\t'),
                else => return error.InvalidJsonString,
            }
            continue;
        }
        try buf.append(allocator, ch);
    }

    return allocator.dupe(u8, buf.items);
}

test "config parser parses scalar raw values" {
    const string_value = try ConfigValueParser.parseRawValue(std.testing.allocator, .string, "hello");
    defer string_value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello", string_value.string);

    const int_value = try ConfigValueParser.parseRawValue(std.testing.allocator, .integer, "8080");
    defer int_value.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 8080), int_value.integer);

    const bool_value = try ConfigValueParser.parseRawValue(std.testing.allocator, .boolean, "false");
    defer bool_value.deinit(std.testing.allocator);
    try std.testing.expectEqual(false, bool_value.boolean);
}

test "config parser parses scalar json values" {
    const string_value = try ConfigValueParser.parseJsonValue(std.testing.allocator, .string, "\"127.0.0.1\"");
    defer string_value.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("127.0.0.1", string_value.string);

    const int_value = try ConfigValueParser.parseJsonValue(std.testing.allocator, .integer, "8080");
    defer int_value.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i64, 8080), int_value.integer);

    const bool_value = try ConfigValueParser.parseJsonValue(std.testing.allocator, .boolean, "true");
    defer bool_value.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, bool_value.boolean);
}

test "config parser parses object and array json values" {
    const object_value = try ConfigValueParser.parseJsonValue(std.testing.allocator, .object, "{\"enabled\":true,\"path\":\"app.log\"}");
    defer object_value.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), object_value.object.len);

    const array_value = try ConfigValueParser.parseJsonValue(std.testing.allocator, .array, "[\"openai\",\"anthropic\"]");
    defer array_value.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), array_value.array.len);
}


