const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const lsp = @import("../../lsp/root.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{ .key = "path", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string, .path_no_traversal } },
    .{ .key = "edits", .required = true, .value_kind = .array, .element_kind = .object },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "edit_file",
        .description = "Canonical edit surface that delegates to hashline-backed editing when available",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"path\",\"edits\"],\"properties\":{\"path\":{\"type\":\"string\"},\"edits\":{\"type\":\"array\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const path = paramString(fields, "path") orelse return error.MissingPath;
    const resolved = try context_model.resolvePath(ctx.allocator, ctx.working_dir, path);
    defer ctx.allocator.free(resolved);

    if (ctx.snapshot_service) |service| {
        try service.recordFileBeforeMutation(ctx.session_id, resolved);
    }

    if (ctx.hashline_backend) |backend| {
        var result = try backend.edit(backend.ptr, ctx, fields);
        errdefer result.deinit(ctx.allocator);

        const formatter_result = try maybeFormat(ctx, resolved);
        defer if (formatter_result) |item| {
            var owned = item;
            owned.deinit(ctx.allocator);
        };

        const diagnostics = try collectDiagnostics(ctx, resolved);
        defer lsp.freeDiagnostics(ctx.allocator, diagnostics);
        if (diagnostics.len == 0 and formatter_result == null) {
            return result;
        }

        const diagnostics_summary = try renderDiagnosticsSummary(ctx, resolved, diagnostics);
        defer ctx.allocator.free(diagnostics_summary);
        const merged_output = if (formatter_result) |formatted|
            if (diagnostics_summary.len == 0)
                try std.fmt.allocPrint(ctx.allocator, "{s}\n\nFormatted with {s}", .{ result.output_text, formatted.formatter_name })
            else
                try std.fmt.allocPrint(ctx.allocator, "{s}\n\nFormatted with {s}\n\n{s}", .{ result.output_text, formatted.formatter_name, diagnostics_summary })
        else
            try std.fmt.allocPrint(ctx.allocator, "{s}\n\n{s}", .{
                result.output_text,
                diagnostics_summary,
            });
        const merged_metadata = try json.stringifyAlloc(ctx.allocator, .{
            .backend_metadata_json = result.metadata_json,
            .formatter = if (formatter_result) |formatted| formatted.formatter_name else null,
            .diagnostics = diagnostics,
        });

        result.deinit(ctx.allocator);
        return .{
            .title = try ctx.allocator.dupe(u8, "edit_file"),
            .output_text = merged_output,
            .metadata_json = merged_metadata,
        };
    }

    ctx.logger.child("tools").child("edit_file").warn("hashline backend unavailable", &.{});
    return error.HashlineEditUnavailable;
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
