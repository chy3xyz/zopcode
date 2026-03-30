const std = @import("std");

pub const MODULE_NAME = "permission";

pub const types = @import("types.zig");
pub const rules = @import("rules.zig");
pub const runtime = @import("runtime.zig");

pub const PermissionAction = types.PermissionAction;
pub const PermissionReply = types.PermissionReply;
pub const PermissionRule = types.PermissionRule;
pub const PermissionRequest = types.PermissionRequest;
pub const PermissionAskInput = types.PermissionAskInput;
pub const PermissionRuntime = runtime.PermissionRuntime;
pub const PermissionRuntimeDependencies = runtime.Dependencies;
pub const PERMISSION_ASKED_EVENT_TOPIC = runtime.PERMISSION_ASKED_EVENT_TOPIC;
pub const PERMISSION_REPLIED_EVENT_TOPIC = runtime.PERMISSION_REPLIED_EVENT_TOPIC;
pub const wildcardMatch = rules.wildcardMatch;
pub const evaluate = rules.evaluate;

test "permission module exports are available" {
    try std.testing.expectEqualStrings("permission", MODULE_NAME);
}
