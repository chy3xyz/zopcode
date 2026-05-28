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
    defer dir.close();

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(ctx.allocator);
    var metadata: std.ArrayListUnmanaged(u8) = .empty;
    defer metadata.deinit(ctx.allocator);
    const out_writer = output.writer(ctx.allocator);
    const meta_writer = metadata.writer(ctx.allocator);
    try meta_writer.writeByte('[');

    var iterator = dir.iterate();
    var index: usize = 0;
    while (try iterator.next()) |entry| {
        if (index > 0) try meta_writer.writeByte(',');
        try out_writer.print("{s}\t{s}\n", .{ entryKind(entry.kind), entry.name });
        try meta_writer.print("{{\"name\":\"{s}\",\"kind\":\"{s}\"}}", .{ entry.name, entryKind(entry.kind) });
        index += 1;
    }
    try meta_writer.writeByte(']');

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

fn entryKind(kind: std.fs.Dir.Entry.Kind) []const u8 {
    return switch (kind) {
        .directory => "dir",
        .file => "file",
        .sym_link => "symlink",
        else => "other",
    };
}
