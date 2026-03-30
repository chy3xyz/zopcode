const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{
        .key = "operation",
        .required = true,
        .value_kind = .enum_string,
        .rules = &.{.{ .enum_string = &.{ "list", "load" } }},
    },
    .{ .key = "name", .required = false, .value_kind = .string, .rules = &.{ .non_empty_string } },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "skill",
        .description = "List or load discovered local skills",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"operation\"],\"properties\":{\"operation\":{\"type\":\"string\"},\"name\":{\"type\":\"string\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const runtime = ctx.skill_runtime orelse return error.SkillRuntimeUnavailable;
    const operation = paramString(fields, "operation") orelse return error.MissingSkillOperation;

    if (std.mem.eql(u8, operation, "list")) {
        const skills = try runtime.list(ctx.allocator);
        defer {
            for (skills) |*item| item.deinit(ctx.allocator);
            ctx.allocator.free(skills);
        }

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(ctx.allocator);
        const writer = out.writer(ctx.allocator);
        for (skills, 0..) |item, index| {
            if (index > 0) try writer.writeByte('\n');
            try writer.print("{s}: {s}", .{ item.id, item.summary });
        }

        return .{
            .title = try ctx.allocator.dupe(u8, "skill"),
            .output_text = try ctx.allocator.dupe(u8, out.items),
            .metadata_json = try json.stringifyAlloc(ctx.allocator, .{ .count = skills.len }),
        };
    }

    if (std.mem.eql(u8, operation, "load")) {
        const name = paramString(fields, "name") orelse return error.MissingSkillName;
        const contents = (try runtime.load(ctx.allocator, name)) orelse return error.SkillNotFound;
        defer ctx.allocator.free(contents);
        return .{
            .title = try ctx.allocator.dupe(u8, "skill"),
            .output_text = try ctx.allocator.dupe(u8, contents),
            .metadata_json = try json.stringifyAlloc(ctx.allocator, .{ .name = name }),
        };
    }

    return error.InvalidSkillOperation;
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}
