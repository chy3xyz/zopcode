const std = @import("std");

pub const MODULE_NAME = "orchestration";

pub const types = @import("types.zig");
pub const aggregate = @import("aggregate.zig");
pub const wait = @import("wait.zig");
pub const service = @import("service.zig");

pub const ChildRequest = types.ChildRequest;
pub const ChildHandle = types.ChildHandle;
pub const ChildResult = types.ChildResult;
pub const BatchRequest = types.BatchRequest;
pub const AggregatedResult = types.AggregatedResult;
pub const OrchestrationService = service.OrchestrationService;
pub const OrchestrationDependencies = service.Dependencies;
pub const registerDelegateBatchCommand = service.registerDelegateBatchCommand;

test {
    std.testing.refAllDecls(@This());
}

test "orchestration module exports are available" {
    try std.testing.expectEqualStrings("orchestration", MODULE_NAME);
}
