const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{ .key = "path", .required = false, .value_kind = .string, .rules = &.{ .path_no_traversal } },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "repo_health_check",
        .description = "Run framework-backed repository health checks",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const bridge = ctx.framework_tooling orelse return error.FrameworkToolingUnavailable;
    const raw_path = paramString(fields, "path") orelse ".";
    const output_json = try bridge.runRepoHealth(
        ctx.allocator,
        ctx.request_id,
        ctx.trace_id,
        ctx.working_dir,
        raw_path,
    );
    errdefer ctx.allocator.free(output_json);

    ctx.logger.child("tools").child("repo_health_check").info("tool executed", &.{
        framework.LogField.string("path", raw_path),
        framework.LogField.boolean("ok", true),
        framework.LogField.boolean("framework_backed", true),
    });

    return .{
        .title = try ctx.allocator.dupe(u8, "repo_health_check"),
        .output_text = try ctx.allocator.dupe(u8, output_json),
        .metadata_json = output_json,
    };
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}
