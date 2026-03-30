const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const mcp = @import("../../mcp/root.zig");
const resource = @import("../../mcp/resource.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{
        .key = "operation",
        .required = true,
        .value_kind = .enum_string,
        .rules = &.{.{ .enum_string = &.{ "list_resources", "read_resource" } }},
    },
    .{ .key = "server_id", .required = false, .value_kind = .string, .rules = &.{.non_empty_string} },
    .{ .key = "uri", .required = false, .value_kind = .string, .rules = &.{.non_empty_string} },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "mcp_resource",
        .description = "List or read resources exposed by connected MCP servers",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"operation\"],\"properties\":{\"operation\":{\"type\":\"string\"},\"server_id\":{\"type\":\"string\"},\"uri\":{\"type\":\"string\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const runtime = ctx.mcp_runtime orelse return error.McpRuntimeUnavailable;
    const operation = paramString(fields, "operation") orelse return error.MissingMcpOperation;

    if (std.mem.eql(u8, operation, "list_resources")) {
        const resources = try runtime.listResources(ctx.allocator, paramString(fields, "server_id"));
        defer mcp.types.freeResources(ctx.allocator, resources);
        const output_text = try resource.renderList(ctx.allocator, resources);
        errdefer ctx.allocator.free(output_text);

        return .{
            .title = try ctx.allocator.dupe(u8, "mcp_resource"),
            .output_text = output_text,
            .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
                .operation = operation,
                .count = resources.len,
            }),
        };
    }

    if (std.mem.eql(u8, operation, "read_resource")) {
        const server_id = paramString(fields, "server_id") orelse return error.MissingMcpServerId;
        const uri = paramString(fields, "uri") orelse return error.MissingMcpResourceUri;
        var content = try runtime.readResource(ctx.allocator, server_id, uri);
        defer content.deinit(ctx.allocator);

        return .{
            .title = try ctx.allocator.dupe(u8, "mcp_resource"),
            .output_text = try ctx.allocator.dupe(u8, content.text),
            .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
                .operation = operation,
                .server_id = server_id,
                .uri = uri,
                .mime_type = content.mime_type,
            }),
        };
    }

    return error.InvalidMcpOperation;
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}
