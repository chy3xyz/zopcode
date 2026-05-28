const std = @import("std");

pub const ValidationMode = enum {
    request,
    config_write,
    config_load,
    security_check,
};

pub const ValueKind = enum {
    string,
    integer,
    boolean,
    float,
    enum_string,
    object,
    array,

    pub fn asText(self: ValueKind) []const u8 {
        return switch (self) {
            .string => "string",
            .integer => "integer",
            .boolean => "boolean",
            .float => "float",
            .enum_string => "enum_string",
            .object => "object",
            .array => "array",
        };
    }
};

pub const ValidationField = struct {
    key: []const u8,
    value: ValidationValue,

    pub fn clone(self: ValidationField, allocator: std.mem.Allocator) anyerror!ValidationField {
        return .{
            .key = try allocator.dupe(u8, self.key),
            .value = try self.value.clone(allocator),
        };
    }

    pub fn deinit(self: ValidationField, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        self.value.deinit(allocator);
    }
};

pub const ValidationValue = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    float: f64,
    object: []const ValidationField,
    array: []const ValidationValue,
    null: void,

    pub fn kind(self: ValidationValue) ?ValueKind {
        return switch (self) {
            .string => .string,
            .integer => .integer,
            .boolean => .boolean,
            .float => .float,
            .object => .object,
            .array => .array,
            .null => null,
        };
    }

    pub fn clone(self: ValidationValue, allocator: std.mem.Allocator) anyerror!ValidationValue {
        return switch (self) {
            .string => |value| .{ .string = try allocator.dupe(u8, value) },
            .integer => |value| .{ .integer = value },
            .boolean => |value| .{ .boolean = value },
            .float => |value| .{ .float = value },
            .null => .null,
            .object => |fields| blk: {
                const cloned = try allocator.alloc(ValidationField, fields.len);
                errdefer allocator.free(cloned);

                for (fields, 0..) |field, index| {
                    cloned[index] = try field.clone(allocator);
                }

                break :blk .{ .object = cloned };
            },
            .array => |items| blk: {
                const cloned = try allocator.alloc(ValidationValue, items.len);
                errdefer allocator.free(cloned);

                for (items, 0..) |item, index| {
                    cloned[index] = try item.clone(allocator);
                }

                break :blk .{ .array = cloned };
            },
        };
    }

    pub fn deinit(self: ValidationValue, allocator: std.mem.Allocator) void {
        switch (self) {
            .string => |value| allocator.free(value),
            .object => |fields| {
                for (fields) |field| {
                    field.deinit(allocator);
                }
                allocator.free(fields);
            },
            .array => |items| {
                for (items) |item| {
                    item.deinit(allocator);
                }
                allocator.free(items);
            },
            else => {},
        }
    }
};

pub const LengthRange = struct {
    min: ?usize = null,
    max: ?usize = null,
};

pub const IntRange = struct {
    min: ?i64 = null,
    max: ?i64 = null,
};

pub const FloatRange = struct {
    min: ?f64 = null,
    max: ?f64 = null,
};

pub const ValidationRule = union(enum) {
    non_empty_string,
    string_length: LengthRange,
    array_length: LengthRange,
    int_range: IntRange,
    float_range: FloatRange,
    enum_string: []const []const u8,
    prefix: []const u8,
    suffix: []const u8,
    risk_confirmation: []const u8,
    path_no_traversal,
    path_within_roots: []const []const u8,
    secret_ref_id,
    url_protocol: []const []const u8,
    hostname_or_ipv4,
    port,
    command_id_allowed: []const []const u8,
};

pub const RuleContext = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    mode: ValidationMode,
    confirm_risk: bool = false,
};

pub const FieldDefinition = struct {
    key: []const u8,
    required: bool = false,
    sensitive: bool = false,
    requires_restart: bool = false,
    value_kind: ValueKind,
    rules: []const ValidationRule = &.{},
    children: []const FieldDefinition = &.{},
    element_kind: ?ValueKind = null,
    element_rules: []const ValidationRule = &.{},
    element_fields: []const FieldDefinition = &.{},
};

pub const ValidatorOptions = struct {
    mode: ValidationMode = .request,
    field_path_prefix: []const u8 = "",
    strict_unknown_fields: bool = true,
    confirm_risk: bool = false,
};

test "value kind text values stay stable" {
    try std.testing.expectEqualStrings("string", ValueKind.string.asText());
    try std.testing.expectEqualStrings("enum_string", ValueKind.enum_string.asText());
}


