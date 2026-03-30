const std = @import("std");
const types = @import("types.zig");

pub fn wildcardMatch(pattern: []const u8, value: []const u8) bool {
    return wildcardMatchInner(pattern, value, 0, 0);
}

fn wildcardMatchInner(pattern: []const u8, value: []const u8, pi: usize, vi: usize) bool {
    if (pi == pattern.len) return vi == value.len;
    if (pattern[pi] == '*') {
        if (pi + 1 == pattern.len) return true;
        var next_vi = vi;
        while (next_vi <= value.len) : (next_vi += 1) {
            if (wildcardMatchInner(pattern, value, pi + 1, next_vi)) return true;
        }
        return false;
    }
    if (vi == value.len) return false;
    if (pattern[pi] != value[vi]) return false;
    return wildcardMatchInner(pattern, value, pi + 1, vi + 1);
}

pub fn evaluate(permission_name: []const u8, target: []const u8, rules: []const types.PermissionRule) types.PermissionAction {
    var index = rules.len;
    while (index > 0) {
        index -= 1;
        const rule = rules[index];
        if (wildcardMatch(rule.permission, permission_name) and wildcardMatch(rule.pattern, target)) {
            return rule.action;
        }
    }
    return .ask;
}

test "permission rules evaluate with last-match wins and wildcard support" {
    const configured = [_]types.PermissionRule{
        .{ .permission = "edit", .pattern = "*", .action = .ask },
        .{ .permission = "edit", .pattern = "*.md", .action = .allow },
    };

    try std.testing.expectEqual(types.PermissionAction.allow, evaluate("edit", "README.md", configured[0..]));
    try std.testing.expectEqual(types.PermissionAction.ask, evaluate("edit", "main.zig", configured[0..]));
}
