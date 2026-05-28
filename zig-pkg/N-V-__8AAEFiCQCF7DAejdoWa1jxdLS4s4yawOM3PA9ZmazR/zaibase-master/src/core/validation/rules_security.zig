const std = @import("std");
const issue_model = @import("issue.zig");
const report_model = @import("report.zig");
const rule_model = @import("rule.zig");

pub const ValidationIssue = issue_model.ValidationIssue;
pub const ValidationReport = report_model.ValidationReport;
pub const RuleContext = rule_model.RuleContext;
pub const ValidationRule = rule_model.ValidationRule;
pub const ValidationValue = rule_model.ValidationValue;

pub fn applyRules(report: *ValidationReport, context: RuleContext, value: ValidationValue, rules: []const ValidationRule) !void {
    for (rules) |rule| {
        switch (rule) {
            .path_no_traversal => {
                if (value == .string and hasTraversalSegment(value.string)) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "PATH_TRAVERSAL_NOT_ALLOWED", "path traversal is not allowed", .@"error")
                            .withHint("use a path within the allowed root")
                            .withRetryable(true),
                    );
                }
            },
            .path_within_roots => |roots| {
                if (value == .string and !isWithinAllowedRoots(value.string, roots)) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "PATH_OUTSIDE_ALLOWED_ROOTS", "path is outside the allowed roots", .@"error")
                            .withHint("choose a path under an allowed root")
                            .withRetryable(true),
                    );
                }
            },
            .secret_ref_id => {
                if (value == .string and !isValidSecretRefId(value.string)) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "SECRET_REF_ID_INVALID", "secret ref id format is invalid", .@"error")
                            .withHint("use letters, digits, '-', '_' or ':' only")
                            .withRetryable(true),
                    );
                }
            },
            .url_protocol => |allowed| {
                if (value == .string and !hasAllowedUrlProtocol(value.string, allowed)) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "URL_PROTOCOL_NOT_ALLOWED", "url protocol is not allowed", .@"error")
                            .withHint("use one of the allowed protocols")
                            .withRetryable(true),
                    );
                }
            },
            .hostname_or_ipv4 => {
                if (value == .string and !isValidHostnameOrIpv4(value.string)) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "HOST_INVALID", "host must be a valid hostname or IPv4 address", .@"error")
                            .withHint("use a valid hostname or IPv4 address")
                            .withRetryable(true),
                    );
                }
            },
            .port => {
                if (value == .integer and (value.integer < 1 or value.integer > 65535)) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "VALUE_OUT_OF_RANGE", "port must be between 1 and 65535", .@"error")
                            .withHint("use a port in the allowed range")
                            .withRetryable(true),
                    );
                }
            },
            .command_id_allowed => |allowed| {
                if (value == .string and !containsString(allowed, value.string)) {
                    try report.addIssue(
                        ValidationIssue.init(context.path, "COMMAND_ID_NOT_ALLOWED", "command is not in the allowed list", .@"error")
                            .withHint("use one of the allowed command ids")
                            .withRetryable(true),
                    );
                }
            },
            .non_empty_string, .string_length, .array_length, .int_range, .float_range, .enum_string, .prefix, .suffix, .risk_confirmation => {},
        }
    }
}

fn hasTraversalSegment(path: []const u8) bool {
    var iter = std.mem.splitAny(u8, path, "/\\");
    while (iter.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) {
            return true;
        }
    }
    return false;
}

fn isWithinAllowedRoots(path: []const u8, roots: []const []const u8) bool {
    for (roots) |root| {
        if (pathStartsWithRoot(path, root)) {
            return true;
        }
    }
    return false;
}

fn pathStartsWithRoot(path: []const u8, root: []const u8) bool {
    const trimmed_root = std.mem.trimEnd(u8, root, "/\\");
    if (trimmed_root.len == 0 or path.len < trimmed_root.len) {
        return false;
    }

    for (trimmed_root, 0..) |ch, index| {
        if (normalizePathChar(path[index]) != normalizePathChar(ch)) {
            return false;
        }
    }

    if (path.len == trimmed_root.len) {
        return true;
    }

    const next = normalizePathChar(path[trimmed_root.len]);
    return next == '/';
}

fn normalizePathChar(ch: u8) u8 {
    if (ch == '\\') {
        return '/';
    }
    return std.ascii.toLower(ch);
}

fn isValidSecretRefId(value: []const u8) bool {
    if (value.len == 0) {
        return false;
    }

    for (value) |ch| {
        if (std.ascii.isWhitespace(ch) or ch == '/' or ch == '\\' or ch == '.') {
            return false;
        }
        if (!(std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == ':')) {
            return false;
        }
    }

    return true;
}

fn hasAllowedUrlProtocol(value: []const u8, allowed: []const []const u8) bool {
    const separator_index = std.mem.indexOf(u8, value, "://") orelse return false;
    const scheme = value[0..separator_index];
    return containsAsciiIgnoreCase(allowed, scheme);
}

fn isValidHostnameOrIpv4(value: []const u8) bool {
    return isValidIpv4(value) or isValidHostname(value);
}

fn isValidIpv4(value: []const u8) bool {
    var iter = std.mem.splitScalar(u8, value, '.');
    var segment_count: usize = 0;

    while (iter.next()) |segment| {
        if (segment.len == 0 or segment.len > 3) {
            return false;
        }

        var parsed: u16 = 0;
        for (segment) |ch| {
            if (!std.ascii.isDigit(ch)) {
                return false;
            }
            parsed = parsed * 10 + (ch - '0');
        }

        if (parsed > 255) {
            return false;
        }

        segment_count += 1;
    }

    return segment_count == 4;
}

fn isValidHostname(value: []const u8) bool {
    if (value.len == 0 or value.len > 253) {
        return false;
    }

    var iter = std.mem.splitScalar(u8, value, '.');
    while (iter.next()) |label| {
        if (label.len == 0 or label.len > 63) {
            return false;
        }
        if (label[0] == '-' or label[label.len - 1] == '-') {
            return false;
        }
        for (label) |ch| {
            if (!(std.ascii.isAlphanumeric(ch) or ch == '-')) {
                return false;
            }
        }
    }

    return true;
}

fn containsString(values: []const []const u8, target: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, target)) {
            return true;
        }
    }
    return false;
}

fn containsAsciiIgnoreCase(values: []const []const u8, target: []const u8) bool {
    for (values) |value| {
        if (std.ascii.eqlIgnoreCase(value, target)) {
            return true;
        }
    }
    return false;
}

test "security rules reject traversal and invalid secret refs" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "logging.file.path",
        .mode = .config_write,
    }, .{ .string = "../secret.txt" }, &.{.path_no_traversal});

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "providers.openai.secret_ref",
        .mode = .config_write,
    }, .{ .string = "../token" }, &.{.secret_ref_id});

    try std.testing.expectEqual(@as(usize, 2), report.issueCount());
}

test "security rules validate url protocol host and command id" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "gateway.url",
        .mode = .config_write,
    }, .{ .string = "http://example.com" }, &.{.{ .url_protocol = &.{"https"} }});

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "gateway.host",
        .mode = .config_write,
    }, .{ .string = "bad host" }, &.{.hostname_or_ipv4});

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "command.id",
        .mode = .request,
    }, .{ .string = "service.delete" }, &.{.{ .command_id_allowed = &.{ "service.restart", "service.status" } }});

    try std.testing.expectEqual(@as(usize, 3), report.issueCount());
}

test "security rules accept valid port and allowed roots" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "logging.file.path",
        .mode = .config_write,
    }, .{ .string = "/workspace/logs/app.jsonl" }, &.{.{ .path_within_roots = &.{ "/workspace", "/tmp" } }});

    try applyRules(&report, .{
        .allocator = std.testing.allocator,
        .path = "gateway.port",
        .mode = .config_write,
    }, .{ .integer = 8080 }, &.{.port});

    try std.testing.expect(report.isOk());
}


