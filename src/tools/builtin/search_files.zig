const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{ .key = "query", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string } },
    .{ .key = "path", .required = false, .value_kind = .string, .rules = &.{ .path_no_traversal } },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "search_files",
        .description = "Search file contents with grep-style line matches",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"query\"],\"properties\":{\"query\":{\"type\":\"string\"},\"path\":{\"type\":\"string\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const query = paramString(fields, "query") orelse return error.MissingQuery;
    const raw_path = paramString(fields, "path") orelse ".";
    const resolved = try context_model.resolvePath(ctx.allocator, ctx.working_dir, raw_path);
    defer ctx.allocator.free(resolved);

    var output: std.ArrayListUnmanaged(u8) = .empty;
    defer output.deinit(ctx.allocator);
    var metadata: std.ArrayListUnmanaged(u8) = .empty;
    defer metadata.deinit(ctx.allocator);
    try metadata.writer(ctx.allocator).writeByte('[');

    var match_count: usize = 0;
    try searchDir(ctx.allocator, resolved, query, &output, &metadata, &match_count);
    try metadata.writer(ctx.allocator).writeByte(']');

    ctx.logger.child("tools").child("search_files").info("tool executed", &.{
        framework.LogField.string("path", resolved),
        framework.LogField.string("query", query),
        framework.LogField.int("match_count", @intCast(match_count)),
        framework.LogField.boolean("ok", true),
    });

    return .{
        .title = try ctx.allocator.dupe(u8, "search_files"),
        .output_text = try ctx.allocator.dupe(u8, output.items),
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .path = resolved,
            .query = query,
            .match_count = match_count,
            .matches = metadata.items,
        }),
    };
}

fn searchDir(
    allocator: std.mem.Allocator,
    path: []const u8,
    query: []const u8,
    output: *std.ArrayListUnmanaged(u8),
    metadata: *std.ArrayListUnmanaged(u8),
    match_count: *usize,
) !void {
    var dir = std.Io.Dir.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();

    var iterator = dir.iterate();
    while (try iterator.next()) |entry| {
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);

        switch (entry.kind) {
            .directory => try searchDir(allocator, child_path, query, output, metadata, match_count),
            .file => try searchFile(allocator, child_path, query, output, metadata, match_count),
            else => {},
        }
    }
}

fn searchFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    query: []const u8,
    output: *std.ArrayListUnmanaged(u8),
    metadata: *std.ArrayListUnmanaged(u8),
    match_count: *usize,
) !void {
    const contents = std.Io.Dir.cwd().readFileAlloc(allocator, path, 256 * 1024) catch return;
    defer allocator.free(contents);

    var lines = std.mem.splitScalar(u8, contents, '\n');
    var line_no: usize = 1;
    while (lines.next()) |line| : (line_no += 1) {
        if (std.mem.indexOf(u8, line, query) == null) continue;
        if (match_count.* > 0) try metadata.writer(allocator).writeByte(',');
        try output.writer(allocator).print("{s}:{d}:{s}\n", .{ path, line_no, line });
        try metadata.writer(allocator).print("{{\"path\":\"{s}\",\"line\":{d}}}", .{ path, line_no });
        match_count.* += 1;
    }
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}
