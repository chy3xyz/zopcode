const std = @import("std");

pub const ValidationSeverity = enum(u8) {
    info,
    warn,
    @"error",

    pub fn asText(self: ValidationSeverity) []const u8 {
        return switch (self) {
            .info => "info",
            .warn => "warn",
            .@"error" => "error",
        };
    }
};

pub const ValidationIssue = struct {
    path: []const u8,
    code: []const u8,
    message: []const u8,
    severity: ValidationSeverity = .@"error",
    hint: ?[]const u8 = null,
    details_json: ?[]const u8 = null,
    retryable: bool = false,

    const Self = @This();

    pub fn init(path: []const u8, code: []const u8, message: []const u8, severity: ValidationSeverity) Self {
        return .{
            .path = path,
            .code = code,
            .message = message,
            .severity = severity,
        };
    }

    pub fn withHint(self: Self, hint: []const u8) Self {
        var next = self;
        next.hint = hint;
        return next;
    }

    pub fn withDetailsJson(self: Self, details_json: []const u8) Self {
        var next = self;
        next.details_json = details_json;
        return next;
    }

    pub fn withRetryable(self: Self, retryable: bool) Self {
        var next = self;
        next.retryable = retryable;
        return next;
    }

    pub fn clone(self: Self, allocator: std.mem.Allocator) !Self {
        return .{
            .path = try allocator.dupe(u8, self.path),
            .code = try allocator.dupe(u8, self.code),
            .message = try allocator.dupe(u8, self.message),
            .severity = self.severity,
            .hint = if (self.hint) |hint| try allocator.dupe(u8, hint) else null,
            .details_json = if (self.details_json) |details_json| try allocator.dupe(u8, details_json) else null,
            .retryable = self.retryable,
        };
    }

    pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.code);
        allocator.free(self.message);
        if (self.hint) |hint| {
            allocator.free(hint);
        }
        if (self.details_json) |details_json| {
            allocator.free(details_json);
        }
    }
};

test "validation issue builder preserves severity and hint" {
    const issue = ValidationIssue.init(
        "gateway.port",
        "VALUE_OUT_OF_RANGE",
        "port must be between 1 and 65535",
        .@"error",
    ).withHint("use a non-zero port").withRetryable(true);

    try std.testing.expectEqualStrings("gateway.port", issue.path);
    try std.testing.expectEqualStrings("VALUE_OUT_OF_RANGE", issue.code);
    try std.testing.expectEqualStrings("error", issue.severity.asText());
    try std.testing.expect(issue.hint != null);
    try std.testing.expect(issue.retryable);
}

test "validation issue can keep structured details json" {
    const issue = ValidationIssue.init(
        "params.provider",
        "TYPE_MISMATCH",
        "field type does not match the schema",
        .@"error",
    ).withDetailsJson("{\"expected\":\"string\",\"actual\":\"boolean\"}");

    try std.testing.expect(issue.details_json != null);
    try std.testing.expectEqualStrings("{\"expected\":\"string\",\"actual\":\"boolean\"}", issue.details_json.?);
}

test "validation issue clone owns copied slices" {
    var cloned = try ValidationIssue.init(
        "config.path",
        "UNKNOWN_FIELD",
        "field is not allowed",
        .warn,
    ).clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("config.path", cloned.path);
    try std.testing.expectEqualStrings("warn", cloned.severity.asText());
}


