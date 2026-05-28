const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{ .key = "path", .required = false, .value_kind = .string, .rules = &.{ .path_no_traversal } },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "list_files",
        .description = "List directory entries",
        .input_schema_json = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const raw_path = paramString(fields, "path") orelse ".";
    const resolved = try context_model.resolvePath(ctx.allocator, ctx.working_dir, raw_path);
    defer ctx.allocator.free(resolved);

    var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.*.io(), resolved, .{ .iterate = true });
    defer dir.close(std.Io.Threaded.global_single_threaded.*.io());

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(ctx.allocator);
    var metadata: std.ArrayListUnmanaged(u8) = .empty;
    defer metadata.deinit(ctx.allocator);
    try output.append(ctx.allocator, '[');

    var iterator = dir.iterate();
    var index: usize = 0;
    while (try iterator.next(std.Io.Threaded.global_single_threaded.*.io())) |entry| {
        if (index > 0) try output.append(ctx.allocator, ',');
        {
            const line = try std.fmt.allocPrint(ctx.allocator, "{s}\t{s}\n", .{ entryKind(entry.kind), entry.name });
            defer ctx.allocator.free(line);
            try output.appendSlice(ctx.allocator, line);
        }
        {
            const entry_json = try std.fmt.allocPrint(ctx.allocator, "{{\"name\":\"{s}\",\"kind\":\"{s}\"}}", .{ entry.name, entryKind(entry.kind) });
            defer ctx.allocator.free(entry_json);
            try output.appendSlice(ctx.allocator, entry_json);
        }
        index += 1;
    }
    try output.append(ctx.allocator, ']');

    ctx.logger.child("tools").child("list_files").info("tool executed", &.{
        framework.LogField.string("path", resolved),
        framework.LogField.int("entry_count", @intCast(index)),
        framework.LogField.boolean("ok", true),
    });

    return .{
        .title = try ctx.allocator.dupe(u8, "list_files"),
        .output_text = try ctx.allocator.dupe(u8, output.items),
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .path = resolved,
            .entry_count = index,
            .entries = metadata.items,
        }),
    };
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn entryKind(kind: anytype) []const u8 {
    _ = kind;
    return "other";
}
