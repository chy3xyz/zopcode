const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{
        .key = "paths",
        .required = true,
        .value_kind = .array,
        .rules = &.{.{ .array_length = .{ .min = 1 } }},
        .element_kind = .string,
        .element_rules = &.{ .non_empty_string, .path_no_traversal },
    },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "revert_files",
        .description = "Restore tracked files to the latest session snapshot",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"paths\"],\"properties\":{\"paths\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const snapshot_service = ctx.snapshot_service orelse return error.SnapshotServiceUnavailable;
    const session_id = ctx.session_id orelse return error.SessionIdRequired;
    const paths = try resolvedPaths(ctx, fields);
    defer {
        for (paths) |path| ctx.allocator.free(path);
        ctx.allocator.free(paths);
    }

    var result = try snapshot_service.revertLatest(ctx.allocator, session_id, paths);
    defer result.deinit(ctx.allocator);

    return .{
        .title = try ctx.allocator.dupe(u8, "revert_files"),
        .output_text = try std.fmt.allocPrint(ctx.allocator, "Restored {d} file(s)", .{result.restored_count}),
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .restored_count = result.restored_count,
            .paths = result.restored_paths,
        }),
    };
}

fn resolvedPaths(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) ![][]const u8 {
    const field = for (fields) |item| {
        if (std.mem.eql(u8, item.key, "paths")) break item;
    } else return error.MissingPaths;
    if (field.value != .array) return error.InvalidPaths;

    const items = try ctx.allocator.alloc([]const u8, field.value.array.len);
    errdefer ctx.allocator.free(items);
    for (field.value.array, 0..) |value, index| {
        if (value != .string) return error.InvalidPaths;
        items[index] = try context_model.resolvePath(ctx.allocator, ctx.working_dir, value.string);
    }
    return items;
}
