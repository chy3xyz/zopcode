const std = @import("std");
const issue_model = @import("issue.zig");

pub const ValidationIssue = issue_model.ValidationIssue;
pub const ValidationSeverity = issue_model.ValidationSeverity;

pub const ValidationReport = struct {
    allocator: std.mem.Allocator,
    issues: std.ArrayListUnmanaged(ValidationIssue) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.issues.items) |*issue| {
            issue.deinit(self.allocator);
        }
        self.issues.deinit(self.allocator);
    }

    pub fn addIssue(self: *Self, issue: ValidationIssue) !void {
        try self.issues.append(self.allocator, try issue.clone(self.allocator));
    }

    pub fn appendClonedFrom(self: *Self, other: *const Self) !void {
        for (other.issues.items) |issue| {
            try self.addIssue(issue);
        }
    }

    pub fn add(self: *Self, path: []const u8, code: []const u8, message: []const u8, severity: ValidationSeverity) !void {
        try self.addIssue(ValidationIssue.init(path, code, message, severity));
    }

    pub fn issueCount(self: *const Self) usize {
        return self.issues.items.len;
    }

    pub fn countBySeverity(self: *const Self, severity: ValidationSeverity) usize {
        var count: usize = 0;
        for (self.issues.items) |issue| {
            if (issue.severity == severity) {
                count += 1;
            }
        }
        return count;
    }

    pub fn hasErrors(self: *const Self) bool {
        return self.countBySeverity(.@"error") > 0;
    }

    pub fn isOk(self: *const Self) bool {
        return !self.hasErrors();
    }

    pub fn hasWarnings(self: *const Self) bool {
        return self.countBySeverity(.warn) > 0;
    }

    pub fn requiresRiskConfirmation(self: *const Self) bool {
        for (self.issues.items) |issue| {
            if (std.mem.eql(u8, issue.code, "RISK_CONFIRMATION_REQUIRED") or
                std.mem.eql(u8, issue.code, "VALIDATION_RISK_CONFIRMATION_REQUIRED"))
            {
                return true;
            }
        }

        return false;
    }

    pub fn primaryIssue(self: *const Self) ?*const ValidationIssue {
        for (self.issues.items) |*issue| {
            if (issue.severity == .@"error") {
                return issue;
            }
        }

        if (self.issues.items.len == 0) {
            return null;
        }

        return &self.issues.items[0];
    }

    pub fn writeJson(self: *const Self, buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator) !void {
        try buf.append(allocator, '{');
        try buf.appendSlice(allocator, "\"ok\":");
        try buf.appendSlice(allocator, if (self.isOk()) "true" else "false");
        try buf.appendSlice(allocator, ",\"issues\":[");

        for (self.issues.items, 0..) |issue, index| {
            if (index > 0) {
                try buf.append(allocator, ',');
            }
            try writeIssueJson(buf, allocator, issue);
        }

        try buf.append(allocator, ']');
        try buf.append(allocator, '}');
    }
};

fn writeIssueJson(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, issue: ValidationIssue) !void {
    try buf.append(allocator, '{');
    try writeJsonStringField(buf, allocator, "path", issue.path, true);
    try writeJsonStringField(buf, allocator, "code", issue.code, false);
    try writeJsonStringField(buf, allocator, "message", issue.message, false);
    try writeJsonStringField(buf, allocator, "severity", issue.severity.asText(), false);

    if (issue.hint) |hint| {
        try writeJsonStringField(buf, allocator, "hint", hint, false);
    }

    if (issue.details_json) |details_json| {
        try buf.appendSlice(allocator, ",\"details\":");
        try buf.appendSlice(allocator, details_json);
    }

    try buf.appendSlice(allocator, ",\"retryable\":");
    try buf.appendSlice(allocator, if (issue.retryable) "true" else "false");
    try buf.append(allocator, '}');
}

fn writeJsonStringField(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, key: []const u8, value: []const u8, first: bool) !void {
    if (!first) {
        try buf.append(allocator, ',');
    }
    try writeJsonString(buf, allocator, key);
    try buf.append(allocator, ':');
    try writeJsonString(buf, allocator, value);
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

test "validation report counts issues by severity" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try report.add("gateway.port", "VALUE_OUT_OF_RANGE", "port must be between 1 and 65535", .@"error");
    try report.add("logging.level", "UNKNOWN_FIELD", "field is not allowed", .warn);
    try report.add("runtime.mode", "NOTICE", "using default mode", .info);

    try std.testing.expectEqual(@as(usize, 3), report.issueCount());
    try std.testing.expectEqual(@as(usize, 1), report.countBySeverity(.@"error"));
    try std.testing.expectEqual(@as(usize, 1), report.countBySeverity(.warn));
    try std.testing.expectEqual(@as(usize, 1), report.countBySeverity(.info));
    try std.testing.expect(report.hasErrors());
    try std.testing.expect(!report.isOk());
}

test "validation report primary issue prefers first error" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try report.add("logging.level", "NOTICE", "using default level", .info);
    try report.add("gateway.port", "UNKNOWN_FIELD", "field is not allowed", .@"error");
    try report.add("gateway.host", "TYPE_MISMATCH", "expected string", .@"error");

    try std.testing.expectEqualStrings("gateway.port", report.primaryIssue().?.path);
}

test "validation report json includes issues array" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try report.addIssue(
        ValidationIssue.init("gateway.port", "RISK_CONFIRMATION_REQUIRED", "requires explicit confirmation", .warn)
            .withHint("retry with confirm flag"),
    );

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try report.writeJson(&buf, std.testing.allocator);

    try std.testing.expect(report.requiresRiskConfirmation());
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"issues\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"hint\":\"retry with confirm flag\"") != null);
}

test "validation report writes issue details as raw json" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try report.addIssue(
        ValidationIssue.init("params.provider", "TYPE_MISMATCH", "field type does not match the schema", .@"error")
            .withDetailsJson("{\"expected\":\"string\",\"actual\":\"boolean\"}"),
    );

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);

    try report.writeJson(&buf, std.testing.allocator);

    try std.testing.expect(std.mem.indexOf(u8, buf.items, "\"details\":{\"expected\":\"string\",\"actual\":\"boolean\"}") != null);
}


