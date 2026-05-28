const std = @import("std");

pub const MODULE_NAME = "validation";

pub const issue = @import("issue.zig");
pub const report = @import("report.zig");
pub const rule = @import("rule.zig");
pub const rules_basic = @import("rules_basic.zig");
pub const rules_security = @import("rules_security.zig");
pub const rules_config = @import("rules_config.zig");
pub const validator = @import("validator.zig");

pub const ValidationIssue = issue.ValidationIssue;
pub const ValidationSeverity = issue.ValidationSeverity;
pub const ValidationReport = report.ValidationReport;
pub const ValidationMode = rule.ValidationMode;
pub const ValueKind = rule.ValueKind;
pub const ValidationField = rule.ValidationField;
pub const ValidationValue = rule.ValidationValue;
pub const ValidationRule = rule.ValidationRule;
pub const RuleContext = rule.RuleContext;
pub const FieldDefinition = rule.FieldDefinition;
pub const ValidatorOptions = rule.ValidatorOptions;
pub const ConfigRule = rules_config.ConfigRule;
pub const Validator = validator.Validator;

test {
    std.testing.refAllDecls(@This());
}

test "validation module exports are available" {
    try std.testing.expectEqualStrings("validation", MODULE_NAME);
    try std.testing.expectEqualStrings("error", ValidationSeverity.@"error".asText());
    try std.testing.expectEqualStrings("request", @tagName(ValidationMode.request));
}


