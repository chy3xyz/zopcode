const std = @import("std");

pub const MODULE_NAME = "pty";

pub const types = @import("types.zig");
pub const backend = @import("backend.zig");
pub const runtime = @import("runtime.zig");

pub const PtyInfo = types.PtyInfo;
pub const OutputChunk = types.OutputChunk;
pub const StatusKind = types.StatusKind;
pub const StreamKind = types.StreamKind;
pub const freeInfos = types.freeInfos;
pub const freeChunks = types.freeChunks;
pub const PtyHandle = backend.PtyHandle;
pub const BackendFactory = backend.BackendFactory;
pub const PtyRuntime = runtime.PtyRuntime;
pub const PtyCreateRequest = runtime.CreateRequest;
pub const PTY_OUTPUT_EVENT_TOPIC = runtime.PTY_OUTPUT_EVENT_TOPIC;
pub const PTY_STATUS_EVENT_TOPIC = runtime.PTY_STATUS_EVENT_TOPIC;

test "pty module exports are available" {
    try std.testing.expectEqualStrings("pty", MODULE_NAME);
}
