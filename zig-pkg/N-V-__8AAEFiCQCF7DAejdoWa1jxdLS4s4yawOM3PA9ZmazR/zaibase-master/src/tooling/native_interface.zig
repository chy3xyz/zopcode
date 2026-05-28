const std = @import("std");
const app = @import("../app/root.zig");
const core = @import("../core/root.zig");
const tool_context = @import("tool_context.zig");
const tool_definition = @import("tool_definition.zig");

pub fn ToolVTable(comptime T: type) tool_definition.NativeToolHandler {
    assertToolInterface(T);
    return &struct {
        fn call(ctx: *const tool_context.ToolContext) anyerror![]u8 {
            return T.execute(ctx);
        }
    }.call;
}

pub fn assertToolInterface(comptime T: type) void {
    if (!@hasDecl(T, "tool_id")) @compileError(@typeName(T) ++ " missing tool_id");
    if (!@hasDecl(T, "tool_description")) @compileError(@typeName(T) ++ " missing tool_description");
    if (!@hasDecl(T, "tool_params")) @compileError(@typeName(T) ++ " missing tool_params");
    if (!@hasDecl(T, "execute")) @compileError(@typeName(T) ++ " missing execute(ctx) function");

    const execute_info = @typeInfo(@TypeOf(T.execute));
    if (execute_info != .@"fn") @compileError(@typeName(T) ++ ".execute must be a function");

    const fn_info = execute_info.@"fn";
    if (fn_info.params.len != 1) @compileError(@typeName(T) ++ ".execute must accept exactly one parameter");
    if (fn_info.params[0].type != *const tool_context.ToolContext) {
        @compileError(@typeName(T) ++ ".execute must accept *const ToolContext");
    }
}

pub fn defineTool(comptime T: type) tool_definition.ToolDefinition {
    assertToolInterface(T);
    return .{
        .id = T.tool_id,
        .description = T.tool_description,
        .authority = if (@hasDecl(T, "tool_authority")) T.tool_authority else app.Authority.public,
        .params = T.tool_params,
        .execution_kind = .native_zig,
        .native_handler = ToolVTable(T),
    };
}

test "native tool helper builds definition and executes through handler" {
    const Demo = struct {
        pub const tool_id = "demo.helper";
        pub const tool_description = "demo helper tool";
        pub const tool_params = &[_]core.validation.FieldDefinition{
            .{ .key = "value", .required = true, .value_kind = .string },
        };
        pub const tool_authority = app.Authority.operator;

        pub fn execute(ctx: *const tool_context.ToolContext) ![]u8 {
            return ctx.allocator.dupe(u8, ctx.param("value").?.value.string);
        }
    };

    const definition = defineTool(Demo);
    try std.testing.expectEqualStrings("demo.helper", definition.id);
    try std.testing.expectEqualStrings("demo helper tool", definition.description);
    try std.testing.expectEqual(app.Authority.operator, definition.authority);
    try std.testing.expectEqual(@as(usize, 1), definition.params.len);
    try std.testing.expect(definition.native_handler != null);

    var sink = core.logging.sinks.Memory.init(std.testing.allocator, 1);
    defer sink.deinit();
    var logger = core.logging.Logger.init(sink.asLogSink(), .silent);
    defer logger.deinit();

    var bus = @import("../runtime/root.zig").MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();
    var effects_runtime = @import("../effects/root.zig").EffectsRuntime.init(.{});
    const params = [_]core.validation.ValidationField{
        .{ .key = "value", .value = .{ .string = "{\"via\":\"helper\"}" } },
    };
    const ctx = tool_context.ToolContext{
        .allocator = std.testing.allocator,
        .request = .{
            .request_id = "helper_req_01",
            .source = .@"test",
            .authority = .operator,
        },
        .tool_id = definition.id,
        .logger = logger.child("helper"),
        .validated_params = params[0..],
        .event_bus = bus.asEventBus(),
        .effects = &effects_runtime,
    };

    const output = try definition.native_handler.?(&ctx);
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("{\"via\":\"helper\"}", output);
}


