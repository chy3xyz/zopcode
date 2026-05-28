const std = @import("std");

pub const MODULE_NAME = "contracts";
pub const envelope = @import("envelope.zig");
pub const capability_manifest = @import("capability_manifest.zig");

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test "contracts scaffold exports are stable" {
    try std.testing.expectEqualStrings("contracts", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);

    const accepted = envelope.TaskAccepted{
        .task_id = "task_01",
        .state = "queued",
    };
    try std.testing.expect(accepted.accepted);
    _ = capability_manifest.CapabilityManifest{};
}


