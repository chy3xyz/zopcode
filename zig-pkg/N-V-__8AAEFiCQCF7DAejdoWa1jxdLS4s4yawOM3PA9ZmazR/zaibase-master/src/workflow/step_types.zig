const core = @import("../core/root.zig");

pub const CommandStep = struct {
    method: []const u8,
    params: []const core.validation.ValidationField = &.{},
};

pub const ShellStep = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
};

pub const EmitEventStep = struct {
    topic: []const u8,
    payload_json: []const u8,
};

pub const RetryTarget = union(enum) {
    command: CommandStep,
    shell: ShellStep,
};

pub const RetryStep = struct {
    attempts: usize,
    delay_ms: u64 = 0,
    target: RetryTarget,
};

pub const WorkflowStep = union(enum) {
    command: CommandStep,
    shell: ShellStep,
    emit_event: EmitEventStep,
    retry: RetryStep,
};


