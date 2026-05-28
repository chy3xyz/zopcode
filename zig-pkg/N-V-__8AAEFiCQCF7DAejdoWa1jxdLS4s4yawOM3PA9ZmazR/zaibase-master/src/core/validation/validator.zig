const std = @import("std");
const issue_model = @import("issue.zig");
const report_model = @import("report.zig");
const rule_model = @import("rule.zig");
const rules_basic = @import("rules_basic.zig");
const rules_security = @import("rules_security.zig");

pub const ValidationIssue = issue_model.ValidationIssue;
pub const ValidationSeverity = issue_model.ValidationSeverity;
pub const ValidationReport = report_model.ValidationReport;
pub const ValidationMode = rule_model.ValidationMode;
pub const ValueKind = rule_model.ValueKind;
pub const ValidationField = rule_model.ValidationField;
pub const ValidationValue = rule_model.ValidationValue;
pub const ValidationRule = rule_model.ValidationRule;
pub const RuleContext = rule_model.RuleContext;
pub const FieldDefinition = rule_model.FieldDefinition;
pub const ValidatorOptions = rule_model.ValidatorOptions;

pub const Validator = struct {
    allocator: std.mem.Allocator,
    fields: []const FieldDefinition,
    options: ValidatorOptions,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, fields: []const FieldDefinition, options: ValidatorOptions) Self {
        return .{
            .allocator = allocator,
            .fields = fields,
            .options = options,
        };
    }

    pub fn validateObject(self: *const Self, input: []const ValidationField) anyerror!ValidationReport {
        var report = ValidationReport.init(self.allocator);
        errdefer report.deinit();

        try self.validateObjectInto(&report, input, self.fields, self.options.field_path_prefix);
        return report;
    }

    fn validateObjectInto(
        self: *const Self,
        report: *ValidationReport,
        input: []const ValidationField,
        definitions: []const FieldDefinition,
        prefix: []const u8,
    ) anyerror!void {
        if (self.options.strict_unknown_fields) {
            for (input) |field| {
                if (findDefinition(definitions, field.key) == null) {
                    const path = try buildFieldPath(self.allocator, prefix, field.key);
                    defer self.allocator.free(path);
                    const details = try unknownFieldDetails(self.allocator, definitions);
                    defer self.allocator.free(details);

                    try report.addIssue(
                        ValidationIssue.init(path, "UNKNOWN_FIELD", "field is not allowed", .@"error")
                            .withHint("remove the unknown field or declare it in the schema")
                            .withDetailsJson(details)
                            .withRetryable(true),
                    );
                }
            }
        }

        for (definitions) |definition| {
            const maybe_field = findInputField(input, definition.key);
            const path = try buildFieldPath(self.allocator, prefix, definition.key);
            defer self.allocator.free(path);

            if (maybe_field == null) {
                if (definition.required) {
                    const details = try requiredFieldDetails(self.allocator, definition.value_kind);
                    defer self.allocator.free(details);

                    try report.addIssue(
                        ValidationIssue.init(path, "REQUIRED_FIELD_MISSING", "required field is missing", .@"error")
                            .withHint("provide the missing field before retrying")
                            .withDetailsJson(details)
                            .withRetryable(true),
                    );
                }
                continue;
            }

            try self.validateField(report, path, definition, maybe_field.?.value);
        }
    }

    fn validateField(
        self: *const Self,
        report: *ValidationReport,
        path: []const u8,
        definition: FieldDefinition,
        value: ValidationValue,
    ) anyerror!void {
        if (!matchesKind(definition.value_kind, value)) {
            const hint = try typeHint(self.allocator, definition.value_kind);
            const details = try typeMismatchDetails(self.allocator, definition.value_kind, value);
            defer self.allocator.free(hint);
            defer self.allocator.free(details);

            try report.addIssue(
                ValidationIssue.init(path, "TYPE_MISMATCH", "field type does not match the schema", .@"error")
                    .withHint(hint)
                    .withDetailsJson(details)
                    .withRetryable(true),
            );
            return;
        }

        const context = RuleContext{
            .allocator = self.allocator,
            .path = path,
            .mode = self.options.mode,
            .confirm_risk = self.options.confirm_risk,
        };

        try rules_basic.applyRules(report, context, value, definition.rules);
        try rules_security.applyRules(report, context, value, definition.rules);

        switch (definition.value_kind) {
            .object => {
                if (definition.children.len > 0 and value == .object) {
                    try self.validateObjectInto(report, value.object, definition.children, path);
                }
            },
            .array => {
                if (value == .array) {
                    try self.validateArray(report, path, definition, value.array);
                }
            },
            else => {},
        }
    }

    fn validateArray(
        self: *const Self,
        report: *ValidationReport,
        path: []const u8,
        definition: FieldDefinition,
        items: []const ValidationValue,
    ) anyerror!void {
        const effective_element_kind = definition.element_kind orelse if (definition.element_fields.len > 0) ValueKind.object else null;

        if (effective_element_kind == null and definition.element_rules.len == 0 and definition.element_fields.len == 0) {
            return;
        }

        for (items, 0..) |item, index| {
            const item_path = try buildArrayItemPath(self.allocator, path, index);
            defer self.allocator.free(item_path);

            if (effective_element_kind) |element_kind| {
                if (!matchesKind(element_kind, item)) {
                    const hint = try typeHint(self.allocator, element_kind);
                    const details = try typeMismatchDetails(self.allocator, element_kind, item);
                    defer self.allocator.free(hint);
                    defer self.allocator.free(details);

                    try report.addIssue(
                        ValidationIssue.init(item_path, "TYPE_MISMATCH", "array item type does not match the schema", .@"error")
                            .withHint(hint)
                            .withDetailsJson(details)
                            .withRetryable(true),
                    );
                    continue;
                }

                const context = RuleContext{
                    .allocator = self.allocator,
                    .path = item_path,
                    .mode = self.options.mode,
                    .confirm_risk = self.options.confirm_risk,
                };

                try rules_basic.applyRules(report, context, item, definition.element_rules);
                try rules_security.applyRules(report, context, item, definition.element_rules);

                if (element_kind == .object and definition.element_fields.len > 0 and item == .object) {
                    try self.validateObjectInto(report, item.object, definition.element_fields, item_path);
                }
            } else {
                const context = RuleContext{
                    .allocator = self.allocator,
                    .path = item_path,
                    .mode = self.options.mode,
                    .confirm_risk = self.options.confirm_risk,
                };

                try rules_basic.applyRules(report, context, item, definition.element_rules);
                try rules_security.applyRules(report, context, item, definition.element_rules);
            }
        }
    }
};

fn findDefinition(fields: []const FieldDefinition, key: []const u8) ?FieldDefinition {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key)) {
            return field;
        }
    }
    return null;
}

fn findInputField(input: []const ValidationField, key: []const u8) ?ValidationField {
    for (input) |field| {
        if (std.mem.eql(u8, field.key, key)) {
            return field;
        }
    }
    return null;
}

fn matchesKind(expected: ValueKind, value: ValidationValue) bool {
    return switch (expected) {
        .enum_string => value == .string,
        .string => value == .string,
        .integer => value == .integer,
        .boolean => value == .boolean,
        .float => value == .float,
        .object => value == .object,
        .array => value == .array,
    };
}

fn buildFieldPath(allocator: std.mem.Allocator, prefix: []const u8, key: []const u8) ![]u8 {
    if (prefix.len == 0) {
        return allocator.dupe(u8, key);
    }
    return std.fmt.allocPrint(allocator, "{s}.{s}", .{ prefix, key });
}

fn buildArrayItemPath(allocator: std.mem.Allocator, path: []const u8, index: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
}

fn typeHint(allocator: std.mem.Allocator, kind: ValueKind) ![]u8 {
    return std.fmt.allocPrint(allocator, "expected {s}", .{kind.asText()});
}

fn requiredFieldDetails(allocator: std.mem.Allocator, kind: ValueKind) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"required\":true,\"expected\":\"{s}\"}}", .{kind.asText()});
}

fn typeMismatchDetails(allocator: std.mem.Allocator, expected: ValueKind, actual: ValidationValue) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"expected\":\"{s}\",\"actual\":\"{s}\"}}",
        .{ expected.asText(), actualKindText(actual) },
    );
}

fn actualKindText(value: ValidationValue) []const u8 {
    if (value.kind()) |kind| {
        return kind.asText();
    }
    return "null";
}

fn unknownFieldDetails(allocator: std.mem.Allocator, definitions: []const FieldDefinition) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"allowedFields\":[");
    for (definitions, 0..) |definition, index| {
        if (index > 0) {
            try buf.append(allocator, ',');
        }
        try writeJsonString(&buf, allocator, definition.key);
    }
    try buf.appendSlice(allocator, "]}");

    return allocator.dupe(u8, buf.items);
}

fn writeJsonString(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
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

test "validator rejects unknown fields and missing required fields" {
    const definitions = [_]FieldDefinition{
        .{ .key = "provider", .required = true, .value_kind = .enum_string },
        .{ .key = "timeout_ms", .required = false, .value_kind = .integer },
    };
    const input = [_]ValidationField{
        .{ .key = "unknown", .value = .{ .string = "value" } },
    };

    const validator = Validator.init(std.testing.allocator, definitions[0..], .{
        .mode = .request,
        .field_path_prefix = "params",
        .strict_unknown_fields = true,
    });

    var report = try validator.validateObject(input[0..]);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 2), report.issueCount());
    try std.testing.expectEqualStrings("params.unknown", report.issues.items[0].path);
    try std.testing.expectEqualStrings("params.provider", report.issues.items[1].path);
    try std.testing.expect(report.issues.items[0].details_json != null);
}

test "validator checks type and basic rules" {
    const definitions = [_]FieldDefinition{
        .{
            .key = "port",
            .required = true,
            .value_kind = .integer,
            .rules = &.{.{ .int_range = .{ .min = 1, .max = 65535 } }},
        },
        .{
            .key = "host",
            .required = true,
            .value_kind = .string,
            .rules = &.{.non_empty_string},
        },
    };
    const input = [_]ValidationField{
        .{ .key = "port", .value = .{ .integer = 0 } },
        .{ .key = "host", .value = .{ .boolean = true } },
    };

    const validator = Validator.init(std.testing.allocator, definitions[0..], .{
        .mode = .config_write,
        .field_path_prefix = "gateway",
    });

    var report = try validator.validateObject(input[0..]);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 2), report.issueCount());
    try std.testing.expectEqualStrings("VALUE_OUT_OF_RANGE", report.issues.items[0].code);
    try std.testing.expectEqualStrings("TYPE_MISMATCH", report.issues.items[1].code);
    try std.testing.expect(report.issues.items[1].details_json != null);
}

test "validator supports risk confirmation flows" {
    const definitions = [_]FieldDefinition{
        .{
            .key = "host",
            .required = true,
            .value_kind = .string,
            .rules = &.{.{ .risk_confirmation = "binding to public interface requires confirmation" }},
        },
    };
    const input = [_]ValidationField{
        .{ .key = "host", .value = .{ .string = "0.0.0.0" } },
    };

    const validator_without_confirm = Validator.init(std.testing.allocator, definitions[0..], .{
        .mode = .config_write,
        .field_path_prefix = "gateway",
        .confirm_risk = false,
    });
    var report_without_confirm = try validator_without_confirm.validateObject(input[0..]);
    defer report_without_confirm.deinit();

    try std.testing.expect(report_without_confirm.requiresRiskConfirmation());

    const validator_with_confirm = Validator.init(std.testing.allocator, definitions[0..], .{
        .mode = .config_write,
        .field_path_prefix = "gateway",
        .confirm_risk = true,
    });
    var report_with_confirm = try validator_with_confirm.validateObject(input[0..]);
    defer report_with_confirm.deinit();

    try std.testing.expect(report_with_confirm.isOk());
}

test "validator validates nested objects and nested unknown fields" {
    const gateway_children = [_]FieldDefinition{
        .{
            .key = "host",
            .required = true,
            .value_kind = .string,
            .rules = &.{.hostname_or_ipv4},
        },
        .{
            .key = "port",
            .required = true,
            .value_kind = .integer,
            .rules = &.{.port},
        },
    };
    const definitions = [_]FieldDefinition{
        .{
            .key = "gateway",
            .required = true,
            .value_kind = .object,
            .children = gateway_children[0..],
        },
    };
    const gateway_input = [_]ValidationField{
        .{ .key = "host", .value = .{ .string = "bad host" } },
        .{ .key = "extra", .value = .{ .string = "nope" } },
    };
    const input = [_]ValidationField{
        .{ .key = "gateway", .value = .{ .object = gateway_input[0..] } },
    };

    const validator = Validator.init(std.testing.allocator, definitions[0..], .{
        .mode = .config_write,
    });

    var report = try validator.validateObject(input[0..]);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 3), report.issueCount());
    try std.testing.expectEqualStrings("gateway.extra", report.issues.items[0].path);
    try std.testing.expectEqualStrings("gateway.host", report.issues.items[1].path);
    try std.testing.expectEqualStrings("gateway.port", report.issues.items[2].path);
}

test "validator validates arrays and nested element schemas" {
    const element_fields = [_]FieldDefinition{
        .{ .key = "id", .required = true, .value_kind = .string, .rules = &.{.non_empty_string} },
    };
    const definitions = [_]FieldDefinition{
        .{
            .key = "providers",
            .required = true,
            .value_kind = .array,
            .rules = &.{.{ .array_length = .{ .min = 1, .max = 3 } }},
            .element_kind = .object,
            .element_fields = element_fields[0..],
        },
    };

    const provider_items = [_]ValidationValue{
        .{ .object = &.{.{ .key = "id", .value = .{ .string = "openai" } }} },
        .{ .object = &.{.{ .key = "name", .value = .{ .string = "missing-id" } }} },
    };
    const input = [_]ValidationField{
        .{ .key = "providers", .value = .{ .array = provider_items[0..] } },
    };

    const validator = Validator.init(std.testing.allocator, definitions[0..], .{
        .mode = .config_load,
    });

    var report = try validator.validateObject(input[0..]);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 2), report.issueCount());
    try std.testing.expectEqualStrings("providers[1].name", report.issues.items[0].path);
    try std.testing.expectEqualStrings("providers[1].id", report.issues.items[1].path);
}

test "validator applies element rules for primitive arrays" {
    const definitions = [_]FieldDefinition{
        .{
            .key = "providers",
            .required = true,
            .value_kind = .array,
            .element_kind = .string,
            .element_rules = &.{
                .non_empty_string,
                .{ .enum_string = &.{ "openai", "anthropic" } },
            },
        },
    };
    const items = [_]ValidationValue{
        .{ .string = "openai" },
        .{ .string = "" },
        .{ .string = "unknown" },
    };
    const input = [_]ValidationField{
        .{ .key = "providers", .value = .{ .array = items[0..] } },
    };

    const validator = Validator.init(std.testing.allocator, definitions[0..], .{
        .mode = .config_load,
    });

    var report = try validator.validateObject(input[0..]);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 3), report.issueCount());
    try std.testing.expectEqualStrings("providers[1]", report.issues.items[0].path);
    try std.testing.expectEqualStrings("providers[1]", report.issues.items[1].path);
    try std.testing.expectEqualStrings("providers[2]", report.issues.items[2].path);
}

test "validator infers object array schema when element fields are provided" {
    const element_fields = [_]FieldDefinition{
        .{ .key = "id", .required = true, .value_kind = .string },
    };
    const definitions = [_]FieldDefinition{
        .{
            .key = "tools",
            .required = true,
            .value_kind = .array,
            .element_fields = element_fields[0..],
        },
    };
    const items = [_]ValidationValue{
        .{ .object = &.{.{ .key = "name", .value = .{ .string = "missing-id" } }} },
    };
    const input = [_]ValidationField{
        .{ .key = "tools", .value = .{ .array = items[0..] } },
    };

    const validator = Validator.init(std.testing.allocator, definitions[0..], .{
        .mode = .config_load,
    });

    var report = try validator.validateObject(input[0..]);
    defer report.deinit();

    try std.testing.expectEqual(@as(usize, 2), report.issueCount());
    try std.testing.expectEqualStrings("tools[0].name", report.issues.items[0].path);
    try std.testing.expectEqualStrings("tools[0].id", report.issues.items[1].path);
}


