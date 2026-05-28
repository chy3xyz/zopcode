const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const lsp = @import("../../lsp/root.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{ .key = "path", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string, .path_no_traversal } },
    .{ .key = "content", .required = true, .value_kind = .string },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "write_file",
        .description = "Write content to a file",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"path\",\"content\"],\"properties\":{\"path\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const path = paramString(fields, "path") orelse return error.MissingPath;
    const content = paramString(fields, "content") orelse return error.MissingContent;
    const resolved = try context_model.resolvePath(ctx.allocator, ctx.working_dir, path);
    defer ctx.allocator.free(resolved);

    if (ctx.snapshot_service) |service| {
        try service.recordFileBeforeMutation(ctx.session_id, resolved);
    }

    if (std.fs.path.dirname(resolved)) |dir_name| {
        _ = std.c.mkdir(@ptrCast(dir_name.ptr), 0o755);
    }
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), resolved, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), content);

    const formatter_result = try maybeFormat(ctx, resolved);
    defer if (formatter_result) |item| {
        var owned = item;
        owned.deinit(ctx.allocator);
    };

    const diagnostics = try collectDiagnostics(ctx, resolved);
    defer lsp.freeDiagnostics(ctx.allocator, diagnostics);
    const diagnostics_summary = try renderDiagnosticsSummary(ctx, resolved, diagnostics);
    defer ctx.allocator.free(diagnostics_summary);
    const output_text = if (formatter_result) |formatted|
        if (diagnostics_summary.len == 0)
            try std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes\nFormatted with {s}", .{ content.len, formatted.formatter_name })
        else
            try std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes\nFormatted with {s}\n\n{s}", .{ content.len, formatted.formatter_name, diagnostics_summary })
    else if (diagnostics_summary.len == 0)
        try std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes", .{content.len})
    else
        try std.fmt.allocPrint(ctx.allocator, "Wrote {d} bytes\n\n{s}", .{ content.len, diagnostics_summary });

    ctx.logger.child("tools").child("write_file").info("tool executed", &.{
        framework.LogField.string("path", resolved),
        framework.LogField.int("bytes", @intCast(content.len)),
        framework.LogField.int("diagnostic_count", @intCast(diagnostics.len)),
        framework.LogField.boolean("ok", true),
    });

    return .{
        .title = try ctx.allocator.dupe(u8, "write_file"),
        .output_text = output_text,
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .path = resolved,
            .bytes = content.len,
            .formatter = if (formatter_result) |formatted| formatted.formatter_name else null,
            .diagnostics = diagnostics,
        }),
    };
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn collectDiagnostics(ctx: *const context_model.ToolExecutionContext, path: []const u8) ![]lsp.Diagnostic {
    const runtime = ctx.lsp_runtime orelse return ctx.allocator.alloc(lsp.Diagnostic, 0);
    if (!runtime.hasServerForFile(path)) return ctx.allocator.alloc(lsp.Diagnostic, 0);
    return runtime.touchFile(ctx.allocator, path, true) catch ctx.allocator.alloc(lsp.Diagnostic, 0);
}

fn renderDiagnosticsSummary(ctx: *const context_model.ToolExecutionContext, path: []const u8, diagnostics: []const lsp.Diagnostic) ![]u8 {
    const runtime = ctx.lsp_runtime orelse return ctx.allocator.alloc(u8, 0);
    return runtime.renderDiagnosticsSummary(ctx.allocator, path, diagnostics);
}

fn maybeFormat(ctx: *const context_model.ToolExecutionContext, path: []const u8) !?@import("../../formatter/root.zig").FormatResult {
    const runtime = ctx.formatter_runtime orelse return null;
    return runtime.formatFile(ctx.allocator, path);
}
