const std = @import("std");
const app = @import("../app/root.zig");
const core = @import("../core/root.zig");
const effects = @import("../effects/root.zig");
const runtime = @import("../runtime/root.zig");

pub const ToolContext = struct {
    allocator: std.mem.Allocator,
    request: app.RequestContext,
    tool_id: []const u8,
    logger: core.logging.SubsystemLogger,
    validated_params: []const core.validation.ValidationField,
    event_bus: runtime.EventBus,
    effects: *effects.EffectsRuntime,

    pub fn param(self: *const ToolContext, key: []const u8) ?core.validation.ValidationField {
        for (self.validated_params) |field| {
            if (std.mem.eql(u8, field.key, key)) return field;
        }
        return null;
    }
};

test "tool context can read validated params" {
    var sink = core.logging.sinks.Memory.init(std.testing.allocator, 1);
    defer sink.deinit();
    var logger = core.logging.Logger.init(sink.asLogSink(), .silent);
    defer logger.deinit();

    var event_bus = runtime.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    var effects_runtime = effects.EffectsRuntime.init(.{});
    const params = [_]core.validation.ValidationField{
        .{ .key = "path", .value = .{ .string = "README.md" } },
    };

    const ctx = ToolContext{
        .allocator = std.testing.allocator,
        .request = .{
            .request_id = "req_tool_01",
            .source = .@"test",
            .authority = .public,
        },
        .tool_id = "file.read",
        .logger = logger.child("tooling"),
        .validated_params = params[0..],
        .event_bus = event_bus.asEventBus(),
        .effects = &effects_runtime,
    };

    try std.testing.expect(ctx.param("path") != null);
    try std.testing.expect(ctx.param("missing") == null);
}


