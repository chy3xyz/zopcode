const std = @import("std");

pub const MODULE_NAME = "workflow";
pub const definition = @import("definition.zig");
pub const step_types = @import("step_types.zig");
pub const runner = @import("runner.zig");
pub const state = @import("state.zig");

pub const WorkflowDefinition = definition.WorkflowDefinition;
pub const WorkflowStep = step_types.WorkflowStep;
pub const WorkflowStatus = state.WorkflowStatus;
pub const WorkflowRunResult = state.WorkflowRunResult;
pub const WorkflowRunner = runner.WorkflowRunner;

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test {
    std.testing.refAllDecls(@This());
}

test "workflow scaffold exports are stable" {
    try std.testing.expectEqualStrings("workflow", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);
    try std.testing.expectEqualStrings("succeeded", WorkflowStatus.succeeded.asText());
}


