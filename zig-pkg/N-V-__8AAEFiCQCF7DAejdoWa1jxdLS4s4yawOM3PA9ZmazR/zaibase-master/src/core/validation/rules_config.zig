const std = @import("std");
const issue_model = @import("issue.zig");
const report_model = @import("report.zig");
const rule_model = @import("rule.zig");

pub const ValidationIssue = issue_model.ValidationIssue;
pub const ValidationReport = report_model.ValidationReport;
pub const ValidationField = rule_model.ValidationField;
pub const ValidationValue = rule_model.ValidationValue;

pub const ConfigRule = union(enum) {
    require_present_when_bool: struct {
        flag_path: []const u8,
        expected: bool,
        required_path: []const u8,
        message: []const u8,
    },
    require_non_empty_string_when_bool: struct {
        flag_path: []const u8,
        expected: bool,
        required_path: []const u8,
        message: []const u8,
    },
    risk_confirmation_for_string_value: struct {
        path: []const u8,
        expected: []const u8,
        message: []const u8,
    },
    risk_confirmation_for_boolean_value: struct {
        path: []const u8,
        expected: bool,
        message: []const u8,
    },
};

pub fn applyRules(
    allocator: std.mem.Allocator,
    report: *ValidationReport,
    updates: []const ValidationField,
    rules: []const ConfigRule,
    confirm_risk: bool,
) !void {
    for (rules) |rule| {
        switch (rule) {
            .require_present_when_bool => |config_rule| {
                if (getBool(updates, config_rule.flag_path) == config_rule.expected and
                    findField(updates, config_rule.required_path) == null)
                {
                    const details = try std.fmt.allocPrint(
                        allocator,
                        "{{\"dependsOn\":\"{s}\",\"requiredPath\":\"{s}\"}}",
                        .{ config_rule.flag_path, config_rule.required_path },
                    );
                    defer allocator.free(details);

                    try report.addIssue(
                        ValidationIssue.init(config_rule.required_path, "REQUIRED_FIELD_MISSING", config_rule.message, .@"error")
                            .withHint("provide the dependent field before retrying")
                            .withDetailsJson(details)
                            .withRetryable(true),
                    );
                }
            },
            .require_non_empty_string_when_bool => |config_rule| {
                if (getBool(updates, config_rule.flag_path) == config_rule.expected) {
                    if (findField(updates, config_rule.required_path)) |field| {
                        if (field.value == .string and std.mem.trim(u8, field.value.string, " \t\r\n").len > 0) {
                            continue;
                        }
                    }

                    const details = try std.fmt.allocPrint(
                        allocator,
                        "{{\"dependsOn\":\"{s}\",\"requiredPath\":\"{s}\"}}",
                        .{ config_rule.flag_path, config_rule.required_path },
                    );
                    defer allocator.free(details);

                    try report.addIssue(
                        ValidationIssue.init(config_rule.required_path, "EMPTY_STRING", config_rule.message, .@"error")
                            .withHint("provide a non-empty string value")
                            .withDetailsJson(details)
                            .withRetryable(true),
                    );
                }
            },
            .risk_confirmation_for_string_value => |config_rule| {
                if (!confirm_risk) {
                    if (getString(updates, config_rule.path)) |actual| {
                        if (std.mem.eql(u8, actual, config_rule.expected)) {
                            const details = try std.fmt.allocPrint(
                                allocator,
                                "{{\"path\":\"{s}\",\"expected\":\"{s}\"}}",
                                .{ config_rule.path, config_rule.expected },
                            );
                            defer allocator.free(details);

                            try report.addIssue(
                                ValidationIssue.init(config_rule.path, "RISK_CONFIRMATION_REQUIRED", config_rule.message, .@"error")
                                    .withHint("retry with explicit risk confirmation")
                                    .withDetailsJson(details)
                                    .withRetryable(true),
                            );
                        }
                    }
                }
            },
            .risk_confirmation_for_boolean_value => |config_rule| {
                if (!confirm_risk and getBool(updates, config_rule.path) == config_rule.expected) {
                    const details = try std.fmt.allocPrint(
                        allocator,
                        "{{\"path\":\"{s}\",\"expected\":{s}}}",
                        .{ config_rule.path, if (config_rule.expected) "true" else "false" },
                    );
                    defer allocator.free(details);

                    try report.addIssue(
                        ValidationIssue.init(config_rule.path, "RISK_CONFIRMATION_REQUIRED", config_rule.message, .@"error")
                            .withHint("retry with explicit risk confirmation")
                            .withDetailsJson(details)
                            .withRetryable(true),
                    );
                }
            },
        }
    }
}

fn findField(fields: []const ValidationField, path: []const u8) ?ValidationField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, path)) {
            return field;
        }
    }
    return null;
}

fn getBool(fields: []const ValidationField, path: []const u8) ?bool {
    if (findField(fields, path)) |field| {
        if (field.value == .boolean) {
            return field.value.boolean;
        }
    }
    return null;
}

fn getString(fields: []const ValidationField, path: []const u8) ?[]const u8 {
    if (findField(fields, path)) |field| {
        if (field.value == .string) {
            return field.value.string;
        }
    }
    return null;
}

test "config rules require dependent path when logging file is enabled" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try applyRules(
        std.testing.allocator,
        &report,
        &.{.{ .key = "logging.file.enabled", .value = .{ .boolean = true } }},
        &.{.{ .require_non_empty_string_when_bool = .{
            .flag_path = "logging.file.enabled",
            .expected = true,
            .required_path = "logging.file.path",
            .message = "logging.file.path is required when file logging is enabled",
        } }},
        false,
    );

    try std.testing.expectEqual(@as(usize, 1), report.issueCount());
    try std.testing.expectEqualStrings("logging.file.path", report.issues.items[0].path);
}

test "config rules require risk confirmation for public bind and pairing disable" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try applyRules(
        std.testing.allocator,
        &report,
        &.{
            .{ .key = "gateway.host", .value = .{ .string = "0.0.0.0" } },
            .{ .key = "gateway.require_pairing", .value = .{ .boolean = false } },
        },
        &.{
            .{ .risk_confirmation_for_string_value = .{
                .path = "gateway.host",
                .expected = "0.0.0.0",
                .message = "binding to 0.0.0.0 requires explicit confirmation",
            } },
            .{ .risk_confirmation_for_boolean_value = .{
                .path = "gateway.require_pairing",
                .expected = false,
                .message = "disabling pairing protection requires explicit confirmation",
            } },
        },
        false,
    );

    try std.testing.expectEqual(@as(usize, 2), report.issueCount());
    try std.testing.expect(report.requiresRiskConfirmation());
}


