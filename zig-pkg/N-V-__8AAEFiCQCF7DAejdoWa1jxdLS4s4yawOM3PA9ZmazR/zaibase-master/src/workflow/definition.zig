const step_types = @import("step_types.zig");

pub const WorkflowDefinition = struct {
    id: []const u8,
    description: []const u8 = "",
    steps: []const step_types.WorkflowStep,
};


