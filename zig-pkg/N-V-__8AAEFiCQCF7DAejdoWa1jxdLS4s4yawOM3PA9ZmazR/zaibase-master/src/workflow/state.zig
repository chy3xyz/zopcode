const std = @import("std");

pub const WorkflowStatus = enum {
    idle,
    running,
    succeeded,
    failed,

    pub fn asText(self: WorkflowStatus) []const u8 {
        return switch (self) {
            .idle => "idle",
            .running => "running",
            .succeeded => "succeeded",
            .failed => "failed",
        };
    }
};

pub const WorkflowRunResult = struct {
    status: WorkflowStatus,
    completed_steps: usize,
    last_output_json: ?[]u8 = null,
    last_error_code: ?[]u8 = null,

    pub fn deinit(self: *WorkflowRunResult, allocator: std.mem.Allocator) void {
        if (self.last_output_json) |value| allocator.free(value);
        if (self.last_error_code) |value| allocator.free(value);
    }
};


