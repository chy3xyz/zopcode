const std = @import("std");

pub const MODULE_NAME = "loop";

pub const types = @import("types.zig");
pub const state_store = @import("state_store.zig");
pub const service = @import("service.zig");

pub const LoopStrategy = types.LoopStrategy;
pub const LoopPhase = types.LoopPhase;
pub const LoopStartRequest = types.LoopStartRequest;
pub const LoopState = types.LoopState;
pub const LoopStateStore = state_store.LoopStateStore;
pub const FileLoopStateStore = state_store.FileLoopStateStore;
pub const LoopService = service.LoopService;
pub const LoopServiceDependencies = service.Dependencies;

test "loop module exports runtime surface" {
    try std.testing.expectEqualStrings("loop", MODULE_NAME);
}
