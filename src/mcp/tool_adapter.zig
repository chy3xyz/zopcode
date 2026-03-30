const std = @import("std");
const framework = @import("framework");
const context_model = @import("../tools/context.zig");
const json = @import("../tools/json.zig");
const runtime_model = @import("runtime.zig");
const result_model = @import("../tools/result.zig");
const tool_model = @import("../tools/tool.zig");
const registry_model = @import("../tools/registry.zig");

const params = [_]framework.FieldDefinition{
    .{
        .key = "input_json",
        .required = false,
        .value_kind = .string,
    },
};

pub fn registerConnectedTools(
    allocator: std.mem.Allocator,
    runtime: *runtime_model.McpRuntime,
    registry: *registry_model.ToolRegistry,
) !void {
    const tools = try runtime.listTools(allocator);
    defer @import("types.zig").freeTools(allocator, tools);

    for (tools) |item| {
        const tool_id = try toolIdFor(allocator, item.server_id, item.name);
        defer allocator.free(tool_id);
        const description = try std.fmt.allocPrint(allocator, "[MCP {s}] {s}", .{ item.server_id, item.description });
        defer allocator.free(description);

        try registry.register(.{
            .id = tool_id,
            .description = description,
            .input_schema_json = item.input_schema_json,
            .params = params[0..],
            .execute_fn = execute,
        });
    }
}

pub fn toolIdFor(allocator: std.mem.Allocator, server_id: []const u8, tool_name: []const u8) ![]u8 {
    const safe_server = try sanitize(allocator, server_id);
    defer allocator.free(safe_server);
    const safe_tool = try sanitize(allocator, tool_name);
    defer allocator.free(safe_tool);
    return std.fmt.allocPrint(allocator, "mcp.{s}.{s}", .{ safe_server, safe_tool });
}

pub fn parseToolId(tool_id: []const u8) ?struct { server_id: []const u8, tool_name: []const u8 } {
    if (!std.mem.startsWith(u8, tool_id, "mcp.")) return null;
    const rest = tool_id["mcp.".len..];
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse return null;
    return .{
        .server_id = rest[0..dot],
        .tool_name = rest[dot + 1 ..],
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const runtime = ctx.mcp_runtime orelse return error.McpRuntimeUnavailable;
    const parsed = parseToolId(ctx.tool_id) orelse return error.InvalidMcpToolId;
    const input_json = paramString(fields, "input_json") orelse "{}";

    var result = try runtime.callTool(ctx.allocator, parsed.server_id, parsed.tool_name, input_json);
    defer result.deinit(ctx.allocator);

    ctx.logger.child("tools").child("mcp").info("tool executed", &.{
        framework.LogField.string("tool_id", ctx.tool_id),
        framework.LogField.string("server_id", parsed.server_id),
    });

    return .{
        .title = try ctx.allocator.dupe(u8, ctx.tool_id),
        .output_text = try ctx.allocator.dupe(u8, result.output_text),
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .server_id = parsed.server_id,
            .tool_name = parsed.tool_name,
            .result = result.metadata_json,
        }),
    };
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn sanitize(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    const cloned = try allocator.dupe(u8, input);
    for (cloned) |*ch| {
        if (!(std.ascii.isAlphanumeric(ch.*) or ch.* == '_' or ch.* == '-' or ch.* == '.')) ch.* = '_';
    }
    return cloned;
}

test "mcp tool id round-trips server and tool name" {
    const tool_id = try toolIdFor(std.testing.allocator, "docs", "echo");
    defer std.testing.allocator.free(tool_id);
    const parsed = parseToolId(tool_id).?;
    try std.testing.expectEqualStrings("docs", parsed.server_id);
    try std.testing.expectEqualStrings("echo", parsed.tool_name);
}

test "connected mcp tools are registered into the tool registry" {
    const MockFactory = struct {
        const MockClient = struct {
            const vtable = @import("transport.zig").McpClient.VTable{
                .list_tools = listToolsErased,
                .call_tool = callToolErased,
                .list_resources = listResourcesErased,
                .read_resource = readResourceErased,
                .deinit = deinitErased,
            };

            fn asClient(self: *@This()) @import("transport.zig").McpClient {
                return .{ .ptr = @ptrCast(self), .vtable = &vtable };
            }

            fn listToolsErased(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]@import("types.zig").ToolInfo {
                const items = try allocator.alloc(@import("types.zig").ToolInfo, 1);
                items[0] = .{
                    .server_id = try allocator.dupe(u8, "docs"),
                    .name = try allocator.dupe(u8, "echo"),
                    .description = try allocator.dupe(u8, "Echo"),
                    .input_schema_json = try allocator.dupe(u8, "{\"type\":\"object\"}"),
                };
                return items;
            }

            fn callToolErased(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!@import("types.zig").ToolCallResult {
                return .{
                    .output_text = try allocator.dupe(u8, "ok"),
                    .metadata_json = try allocator.dupe(u8, "{}"),
                };
            }

            fn listResourcesErased(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]@import("types.zig").ResourceInfo {
                return allocator.alloc(@import("types.zig").ResourceInfo, 0);
            }

            fn readResourceErased(_: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror!@import("types.zig").ResourceContent {
                return .{
                    .server_id = try allocator.dupe(u8, "docs"),
                    .uri = try allocator.dupe(u8, uri),
                    .text = try allocator.dupe(u8, ""),
                };
            }

            fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                allocator.destroy(self);
            }
        };

        fn connect(_: *anyopaque, allocator: std.mem.Allocator, _: @import("../config/root.zig").McpServerConfig, _: []const u8) anyerror!@import("transport.zig").McpClient {
            const client = try allocator.create(MockClient);
            client.* = .{};
            return client.asClient();
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 32);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();
    var registry = registry_model.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const local_cmd = [_][]const u8{"mock"};
    const servers = [_]@import("../config/root.zig").McpServerConfig{
        .{ .id = "docs", .transport = .local, .command = @constCast(local_cmd[0..]) },
    };
    const runtime = try runtime_model.McpRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
        .workspace_dir = ".",
        .mcp = .{ .servers = @constCast(servers[0..]) },
        .client_factory = .{
            .ptr = undefined,
            .connect_fn = MockFactory.connect,
            .deinit_fn = MockFactory.deinit,
        },
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    try registerConnectedTools(std.testing.allocator, runtime, &registry);
    try std.testing.expect(registry.get("mcp.docs.echo") != null);
}
