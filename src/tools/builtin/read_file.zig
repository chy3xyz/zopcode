const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const hashline = @import("../hashline/root.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{ .key = "path", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string, .path_no_traversal } },
    .{ .key = "hashline", .required = false, .value_kind = .boolean },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "read_file",
        .description = "Read the contents of a file",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"path\"],\"properties\":{\"path\":{\"type\":\"string\"},\"hashline\":{\"type\":\"boolean\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const path = paramString(fields, "path") orelse return error.MissingPath;
    const resolved = try context_model.resolvePath(ctx.allocator, ctx.working_dir, path);
    defer ctx.allocator.free(resolved);

    const contents = try std.fs.cwd().readFileAlloc(ctx.allocator, resolved, 1024 * 1024);
    defer ctx.allocator.free(contents);

    const hashline_mode = paramBool(fields, "hashline") orelse false;
    const output_text = if (hashline_mode)
        try hashline.read.renderHashlineRead(ctx.allocator, contents)
    else
        try ctx.allocator.dupe(u8, contents);
    errdefer ctx.allocator.free(output_text);

    ctx.logger.child("tools").child("read_file").info("tool executed", &.{
        framework.LogField.string("path", resolved),
        framework.LogField.boolean("hashline", hashline_mode),
        framework.LogField.boolean("ok", true),
    });

    return .{
        .title = try ctx.allocator.dupe(u8, "read_file"),
        .output_text = output_text,
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .path = resolved,
            .bytes = contents.len,
            .hashline = hashline_mode,
        }),
    };
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn paramBool(fields: []const framework.ValidationField, key: []const u8) ?bool {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .boolean) return field.value.boolean;
    }
    return null;
}
