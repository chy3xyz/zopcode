const std = @import("std");
const issue_model = @import("issue.zig");
const report_model = @import("report.zig");
const rule_model = @import("rule.zig");

pub const ValidationIssue = issue_model.ValidationIssue;
pub const ValidationSeverity = issue_model.ValidationSeverity;
pub const ValidationReport = report_model.ValidationReport;
pub const RuleContext = rule_model.RuleContext;
pub const ValidationRule = rule_model.ValidationRule;
pub const ValidationValue = rule_model.ValidationValue;

pub fn applyRules(report: *ValidationReport, context: RuleContext, value: ValidationValue, rules: []const ValidationRule) !void {
    for (rules) |rule| {
        switch (rule) {
            .non_empty_string => {
                if (value == .string) {
                    if (std.mem.trim(u8, value.string, " \t\r\n").len == 0) {
                        try report.addIssue(
                            ValidationIssue.init(context.path, "EMPTY_STRING", "value must not be empty", .@"error")
                                .withHint("provide a non-empty string")
                                .withRetryable(true),
                        );
                    }
                }
            },
            .string_length => |range| {
                if (value == .string) {
                    const len = value.string.len;
                    if (range.min) |min| {
                        if (len < min) {
                            const details = try lengthDetails(context.allocator, range.min, range.max, len);
                            defer context.allocator.free(details);

                            try report.addIssue(
                                ValidationIssue.init(context.path, "VALUE_TOO_SHORT", "string is shorter than allowed", .@"error")
                                    .withHint("increase the string length")
                                    .withDetailsJson(details)
                                    .withRetryable(true),
                            );
                        }
                    }
                    if (range.max) |max| {
                        if (len > max) {
                            const details = try lengthDetails(context.allocator, range.min, range.max, len);
                            defer context.allocator.free(details);

                            try report.addIssue(
                                ValidationIssue.init(context.path, "VALUE_TOO_LONG", "string is longer than allowed", .@"error")
                                    .withHint("shorten the string value")
                                    .withDetailsJson(details)
                                    .withRetryable(true),
                            );
                        }
                    }
                }
            },
            .array_length => |range| {
                if (value == .array) {
                    const len = value.array.len;
                    if (range.min) |min| {
                        if (len < min) {
                            const details = try lengthDetails(context.allocator, range.min, range.max, len);
                            defer context.allocator.free(details);

                            try report.addIssue(
                                ValidationIssue.init(context.path, "ARRAY_TOO_SHORT", "array has fewer items than allowed", .@"error")
                                    .withHint("add more items to satisfy the schema")
                                    .withDetailsJson(details)
                                    .withRetryable(true),
                            );
                        }
                    }
                    if (range.max) |max| {
                        if (len > max) {
                            const details = try lengthDetails(context.allocator, range.min, range.max, len);
                            defer context.allocator.free(details);

                            try report.addIssue(
                                ValidationIssue.init(context.path, "ARRAY_TOO_LONG", "array has more items than allowed", .@"error")
                                    .withHint("remove extra items to satisfy the schema")
                                    .withDetailsJson(details)
                                    .withRetryable(true),
                            );
                        }
                    }
                }
            },
            .int_range => |range| {
                if (value == .integer) {
                    if (range.min) |min| {
                        if (value.integer < min) {
                            const details = try intRangeDetails(context.allocator, range.min, range.max, value.integer);
                            defer context.allocator.free(details);

                            try report.addIssue(
                                ValidationIssue.init(context.path, "VALUE_OUT_OF_RANGE", "integer is below the allowed minimum", .@"error")
                                    .withHint("use a value inside the allowed range")
                                    .withDetailsJson(details)
                                    .withRetryable(true),
                            );
                        }
                    }
                    if (range.max) |max| {
                        if (value.integer > max) {
                            const details = try intRangeDetails(context.allocator, range.min, range.max, value.integer);
                            defer context.allocator.free(details);

                            try report.addIssue(
                                ValidationIssue.init(context.path, "VALUE_OUT_OF_RANGE", "integer exceeds the allowed maximum", .@"error")
                                    .withHint("use a value inside the allowed range")
                                    .withDetailsJson(details)
                                    .withRetryable(true),
                            );
                        }
                    }
                }
            },
            .float_range => |range| {
                if (value == .float) {
                    if (range.min) |min| {
                        if (value.float < min) {
                            const details = try floatRangeDetails(context.allocator, range.min, range.max, value.float);
                            defer context.allocator.free(details);

                            try report.addIssue(
                                ValidationIssue.init(context.path, "VALUE_OUT_OF_RANGE", "float is below the allowed minimum", .@"error")
                                    .withHint("use a value inside the allowed range")
                                    .withDetailsJson(details)
                                    .withRetryable(true),
                            );
                        }
                    }
                    if (range.max) |max| {
                        if (value.float > max) {
                            const details = try floatRangeDetails(context.allocator, range.min, range.max, value.float);
                            defer context.allocator.free(details);

                            try report.addIssue(
                                ValidationIssue.init(context.path, "VALUE_OUT_OF_RANGE", "float exceeds the allowed maximum", .@"error")
                                    .withHint("use a value inside the allowed range")
                                    .withDetailsJson(details)
                                    .withRetryable(true),
                            );
                        }
                    }
                }
            },
            .enum_string => |allowed| {
                if (value == .string) {
                    var matched = false;
                    for (allowed) |candidate| {
                        if (std.mem.eql(u8, value.string, candidate)) {
                            matched = true;
                            break;
                        }
                    }
                    if (!matched) {
                        const details = try enumDetails(context.allocator, allowed, value.string);
                        defer context.allocator.free(details);

                        try report.addIssue(
                            ValidationIssue.init(context.path, "ENUM_VALUE_INVALID", "value is not in the allowed enum set", .@"error")
                                .withHint("use one of the declared enum values")
                                .withDetailsJson(details)
                                .withRetryable(true),
                        );
                    }
                }
            },
            .prefix => |expected| {
                if (value == .string and !std.mem.startsWith(u8, value.string, expected)) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "PREFIX_MISMATCH", "string does not have the required prefix", .@"error")
                            .withRetryable(true),
                    );
                }
            },
            .suffix => |expected| {
                if (value == .string and !std.mem.endsWith(u8, value.string, expected)) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "SUFFIX_MISMATCH", "string does not have the required suffix", .@"error")
                            .withRetryable(true),
                    );
                }
            },
            .risk_confirmation => |message| {
                if (!context.confirm_risk) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "RISK_CONFIRMATION_REQUIRED", message, .@"error")
                            .withHint("retry with explicit risk confirmation")
                            .withRetryable(true),
                    );
                }
            },
            .path_no_traversal, .path_within_roots, .secret_ref_id, .url_protocol, .hostname_or_ipv4, .port, .command_id_allowed => {},
        }
    }
}

fn lengthDetails(allocator: std.mem.Allocator, min: ?usize, max: ?usize, actual: usize) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"min\":");
    if (min) |value| {
        try buf.print(allocator, "{d}", .{value});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"max\":");
    if (max) |value| {
        try buf.print(allocator, "{d}", .{value});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.print(allocator, ",\"actual\":{d}}}", .{actual});

    return allocator.dupe(u8, buf.items);
}

fn intRangeDetails(allocator: std.mem.Allocator, min: ?i64, max: ?i64, actual: i64) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"min\":");
    if (min) |value| {
        try buf.print(allocator, "{d}", .{value});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"max\":");
    if (max) |value| {
        try buf.print(allocator, "{d}", .{value});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.print(allocator, ",\"actual\":{d}}}", .{actual});

    return allocator.dupe(u8, buf.items);
}

fn floatRangeDetails(allocator: std.mem.Allocator, min: ?f64, max: ?f64, actual: f64) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"min\":");
    if (min) |value| {
        try buf.print(allocator, "{d}", .{value});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.appendSlice(allocator, ",\"max\":");
    if (max) |value| {
        try buf.print(allocator, "{d}", .{value});
    } else {
        try buf.appendSlice(allocator, "null");
    }
    try buf.print(allocator, ",\"actual\":{d}}}", .{actual});

    return allocator.dupe(u8, buf.items);
}

fn enumDetails(allocator: std.mem.Allocator, allowed: []const []const u8, actual: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"allowed\":[");
    for (allowed, 0..) |value, index| {
        if (index > 0) {
            try buf.append(allocator, ',');
        }
        try writeJsonString(&buf, allocator, value);
    }
    try buf.appendSlice(allocator, "],\"actual\":");
    try writeJsonString(&buf, allocator, actual);
    try buf.append(allocator, '}');

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

test "basic rules catch empty strings and enum mismatch" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "params.provider",
        .mode = .request,
    }, .{ .string = "   " }, &.{
        .non_empty_string,
        .{ .enum_string = &.{ "openai", "anthropic" } },
    });

    try std.testing.expectEqual(@as(usize, 2), report.issueCount());
}

test "basic rules catch integer range and risk confirmation" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "gateway.port",
        .mode = .config_write,
        .confirm_risk = false,
    }, .{ .integer = 0 }, &.{
        .{ .int_range = .{ .min = 1, .max = 65535 } },
        .{ .risk_confirmation = "binding to public interface requires confirmation" },
    });

    try std.testing.expectEqual(@as(usize, 2), report.issueCount());
    try std.testing.expect(report.requiresRiskConfirmation());
}

test "basic rules catch array length constraints" {
    const values = [_]ValidationValue{
        .{ .string = "a" },
    };

    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "params.items",
        .mode = .request,
    }, .{ .array = values[0..] }, &.{
        .{ .array_length = .{ .min = 2, .max = 4 } },
    });

    try std.testing.expectEqual(@as(usize, 1), report.issueCount());
    try std.testing.expectEqualStrings("ARRAY_TOO_SHORT", report.issues.items[0].code);
}

test "basic rules include structured details for enum violations" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "params.provider",
        .mode = .request,
    }, .{ .string = "unknown" }, &.{
        .{ .enum_string = &.{ "openai", "anthropic" } },
    });

    try std.testing.expect(report.issues.items[0].details_json != null);
    try std.testing.expect(std.mem.indexOf(u8, report.issues.items[0].details_json.?, "\"allowed\":[\"openai\",\"anthropic\"]") != null);
}


