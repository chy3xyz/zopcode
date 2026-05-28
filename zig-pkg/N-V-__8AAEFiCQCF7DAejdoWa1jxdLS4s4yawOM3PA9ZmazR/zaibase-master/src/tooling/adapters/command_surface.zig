const std = @import("std");
const app = @import("../../app/root.zig");
const core = @import("../../core/root.zig");
const effects = @import("../../effects/root.zig");
const runtime = @import("../../runtime/root.zig");
const tool_definition = @import("../tool_definition.zig");
const tool_registry = @import("../tool_registry.zig");
const tool_runner = @import("../tool_runner.zig");

pub const CommandSurface = struct {
    allocator: std.mem.Allocator,
    runner: *tool_runner.ToolRunner,
    effects: *effects.EffectsRuntime,
    event_bus: runtime.EventBus,

    pub fn init(
        allocator: std.mem.Allocator,
        runner: *tool_runner.ToolRunner,
        effects_runtime: *effects.EffectsRuntime,
        event_bus: runtime.EventBus,
    ) CommandSurface {
        return .{
            .allocator = allocator,
            .runner = runner,
            .effects = effects_runtime,
            .event_bus = event_bus,
        };
    }

    pub fn commandMethodForToolId(tool_id: []const u8) []const u8 {
        return tool_id;
    }

    pub fn registerTool(
        self: *CommandSurface,
        registry: *app.CommandRegistry,
        definition: tool_definition.ToolDefinition,
    ) !void {
        try registry.register(.{
            .id = definition.id,
            .method = commandMethodForToolId(definition.id),
            .description = definition.description,
            .authority = definition.authority,
            .params = definition.params,
            .handler = handleToolCommand,
            .user_data = self,
        });
    }

    pub fn registerAll(
        self: *CommandSurface,
        registry: *app.CommandRegistry,
        tools: *const tool_registry.ToolRegistry,
    ) !void {
        for (tools.list()) |definition| {
            try self.registerTool(registry, definition);
        }
    }
};

fn handleToolCommand(ctx: *const app.CommandContext) anyerror![]const u8 {
    const surface: *CommandSurface = @ptrCast(@alignCast(ctx.user_data.?));
    var result = try surface.runner.run(.{
        .tool_id = ctx.command_method,
        .request = ctx.request,
        .params = ctx.validated_params,
    });
    defer result.deinit(ctx.allocator);
    return try ctx.allocator.dupe(u8, result.output_json);
}

test "command surface registers tool as command and dispatcher can run it" {
    const Demo = struct {
        fn call(tool_ctx: *const @import("../tool_context.zig").ToolContext) ![]u8 {
            const value = tool_ctx.param("value").?.value.string;
            return tool_ctx.allocator.dupe(u8, value);
        }
    };

    var app_context = try runtime.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var tools = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer tools.deinit();
    const params = [_]core.validation.FieldDefinition{
        .{ .key = "value", .required = true, .value_kind = .string },
    };
    try tools.register(.{
        .id = "demo.echo",
        .description = "echo command tool",
        .params = params[0..],
        .native_handler = Demo.call,
    });

    var runner = tool_runner.ToolRunner.init(
        std.testing.allocator,
        &tools,
        &effects_runtime,
        null,
        app_context.logger,
        app_context.eventBus(),
    );
    var surface = CommandSurface.init(
        std.testing.allocator,
        &runner,
        &effects_runtime,
        app_context.eventBus(),
    );
    try surface.registerAll(app_context.command_registry, &tools);

    var dispatcher = app_context.makeDispatcher();
    const fields = [_]core.validation.ValidationField{
        .{ .key = "value", .value = .{ .string = "{\"ok\":true}" } },
    };
    var envelope = try dispatcher.dispatch(.{
        .request_id = "cmd_req_01",
        .method = "demo.echo",
        .params = fields[0..],
        .source = .@"test",
        .authority = .public,
    }, false);
    defer if (envelope.result) |*result| {
        switch (result.*) {
            .success_json => |json| std.testing.allocator.free(json),
            else => {},
        }
    };

    try std.testing.expect(envelope.ok);
    try std.testing.expect(envelope.result != null);
    switch (envelope.result.?) {
        .success_json => |json| try std.testing.expectEqualStrings("{\"ok\":true}", json),
        else => return error.UnexpectedEnvelopeVariant,
    }
}

test "command surface and direct tool invocation return same output" {
    const Demo = struct {
        fn call(tool_ctx: *const @import("../tool_context.zig").ToolContext) ![]u8 {
            return tool_ctx.allocator.dupe(u8, "{\"same\":true}");
        }
    };

    var app_context = try runtime.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var tools = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer tools.deinit();
    try tools.register(.{
        .id = "demo.same",
        .description = "same output tool",
        .native_handler = Demo.call,
    });

    var runner = tool_runner.ToolRunner.init(
        std.testing.allocator,
        &tools,
        &effects_runtime,
        null,
        app_context.logger,
        app_context.eventBus(),
    );

    var direct = try runner.run(.{
        .tool_id = "demo.same",
        .request = .{
            .request_id = "tool_req_same",
            .source = .@"test",
            .authority = .public,
        },
        .params = &.{},
    });
    defer direct.deinit(std.testing.allocator);

    var surface = CommandSurface.init(
        std.testing.allocator,
        &runner,
        &effects_runtime,
        app_context.eventBus(),
    );
    try surface.registerAll(app_context.command_registry, &tools);

    var dispatcher = app_context.makeDispatcher();
    var envelope = try dispatcher.dispatch(.{
        .request_id = "cmd_req_same",
        .method = "demo.same",
        .params = &.{},
        .source = .@"test",
        .authority = .public,
    }, false);
    defer if (envelope.result) |*result| {
        switch (result.*) {
            .success_json => |json| std.testing.allocator.free(json),
            else => {},
        }
    };

    try std.testing.expect(envelope.ok);
    try std.testing.expect(envelope.result != null);
    switch (envelope.result.?) {
        .success_json => |json| try std.testing.expectEqualStrings(direct.output_json, json),
        else => return error.UnexpectedEnvelopeVariant,
    }
}


