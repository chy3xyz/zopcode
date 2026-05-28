const std = @import("std");

pub const MODULE_NAME = "runtime";
pub const app_context = @import("app_context.zig");
pub const capability_manifest = @import("capability_manifest.zig");
pub const event_bus = @import("event_bus.zig");
pub const stream_body = @import("stream_body.zig");
pub const stream_event = @import("stream_event.zig");
pub const stream_sink = @import("stream_sink.zig");
pub const task_runner = @import("task_runner.zig");

pub const AppBootstrapConfig = app_context.AppBootstrapConfig;
pub const AppContext = app_context.AppContext;
pub const renderCapabilityManifestJson = capability_manifest.renderCapabilityManifestJson;
pub const writeCapabilityManifestJson = capability_manifest.writeCapabilityManifestJson;
pub const renderJsonEvent = stream_event.renderJsonEvent;
pub const ByteSink = stream_sink.ByteSink;
pub const ArrayListSink = stream_sink.ArrayListSink;
pub const netStreamSink = stream_sink.netStreamSink;
pub const fileSink = stream_sink.fileSink;
pub const StreamingBody = stream_body.StreamingBody;
pub const WebSocketBody = stream_body.WebSocketBody;
pub const WebSocketClientEventHandler = stream_body.WebSocketClientEventHandler;
pub const RuntimeEvent = event_bus.RuntimeEvent;
pub const EventBatch = event_bus.EventBatch;
pub const EventBus = event_bus.EventBus;
pub const MemoryEventBus = event_bus.MemoryEventBus;
pub const TaskState = task_runner.TaskState;
pub const TaskJob = task_runner.TaskJob;
pub const TaskRecord = task_runner.TaskRecord;
pub const TaskSummary = task_runner.TaskSummary;
pub const TaskRunner = task_runner.TaskRunner;

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test "runtime scaffold exports are stable" {
    try std.testing.expectEqualStrings("runtime", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);
    try std.testing.expectEqualStrings("queued", TaskState.queued.asText());
    _ = MemoryEventBus;
    _ = AppContext;
}


