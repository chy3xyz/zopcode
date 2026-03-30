const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const lsp = @import("../../lsp/root.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{
        .key = "operation",
        .required = true,
        .value_kind = .enum_string,
        .rules = &.{.{ .enum_string = &.{
            "go_to_definition",
            "find_references",
            "hover",
            "document_symbols",
            "workspace_symbols",
            "go_to_implementation",
        } }},
    },
    .{ .key = "file_path", .required = false, .value_kind = .string, .rules = &.{ .path_no_traversal } },
    .{ .key = "line", .required = false, .value_kind = .integer, .rules = &.{.{ .int_range = .{ .min = 1 } }} },
    .{ .key = "character", .required = false, .value_kind = .integer, .rules = &.{.{ .int_range = .{ .min = 1 } }} },
    .{ .key = "query", .required = false, .value_kind = .string },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "lsp",
        .description = "Query configured LSP servers for code intelligence operations",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"operation\"],\"properties\":{\"operation\":{\"type\":\"string\"},\"file_path\":{\"type\":\"string\"},\"line\":{\"type\":\"integer\"},\"character\":{\"type\":\"integer\"},\"query\":{\"type\":\"string\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const runtime = ctx.lsp_runtime orelse return error.LspRuntimeUnavailable;
    const operation_text = paramString(fields, "operation") orelse return error.MissingLspOperation;
    const operation = lsp.Operation.fromText(operation_text) orelse return error.InvalidLspOperation;
    const file_path = if (paramString(fields, "file_path")) |raw_path|
        try context_model.resolvePath(ctx.allocator, ctx.working_dir, raw_path)
    else
        null;
    defer if (file_path) |resolved| ctx.allocator.free(resolved);

    const result_json = try runtime.requestOperation(ctx.allocator, .{
        .operation = operation,
        .file_path = file_path,
        .line = if (paramInt(fields, "line")) |value| @intCast(value - 1) else null,
        .character = if (paramInt(fields, "character")) |value| @intCast(value - 1) else null,
        .query = paramString(fields, "query"),
    });
    defer ctx.allocator.free(result_json);

    ctx.logger.child("tools").child("lsp").info("tool executed", &.{
        framework.LogField.string("operation", operation_text),
        framework.LogField.string("file_path", file_path orelse ""),
        framework.LogField.boolean("ok", true),
    });

    return .{
        .title = try ctx.allocator.dupe(u8, "lsp"),
        .output_text = try ctx.allocator.dupe(u8, result_json),
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .operation = operation_text,
            .file_path = file_path,
        }),
    };
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn paramInt(fields: []const framework.ValidationField, key: []const u8) ?i64 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .integer) return field.value.integer;
    }
    return null;
}
