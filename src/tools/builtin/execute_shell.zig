const std = @import("std");
const builtin = @import("builtin");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{ .key = "command", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string } },
    .{ .key = "cwd", .required = false, .value_kind = .string, .rules = &.{ .path_no_traversal } },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "execute_shell",
        .description = "Execute a shell command asynchronously",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"command\"],\"properties\":{\"command\":{\"type\":\"string\"},\"cwd\":{\"type\":\"string\"}}}",
        .params = params[0..],
        .execution_mode = .async_task,
        .async_execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const command = paramString(fields, "command") orelse return error.MissingCommand;
    const cwd = if (paramString(fields, "cwd")) |value|
        try context_model.resolvePath(ctx.allocator, ctx.working_dir, value)
    else
        try ctx.allocator.dupe(u8, ctx.working_dir);
    defer ctx.allocator.free(cwd);

    var trace = try framework.StepTrace.begin(ctx.allocator, ctx.logger, "tools/execute_shell", command, 250);
    defer trace.deinit();

    const result = runShell(ctx.allocator, cwd, command) catch |err| {
        ctx.logger.child("tools").child("execute_shell").warn("tool failed", &.{
            framework.LogField.string("cwd", cwd),
            framework.LogField.string("command", command),
            framework.LogField.string("error_code", @errorName(err)),
        });
        trace.finish("SHELL_EXEC_FAILED");
        return err;
    };
    defer {
        ctx.allocator.free(result.stdout);
        ctx.allocator.free(result.stderr);
    }

    const exit_code: u8 = switch (result.term) {
        .Exited => |code| code,
        .Signal, .Stopped, .Unknown => 1,
    };
    const success = exit_code == 0;

    ctx.logger.child("tools").child("execute_shell").info("tool executed", &.{
        framework.LogField.string("cwd", cwd),
        framework.LogField.string("command", command),
        framework.LogField.int("exit_code", exit_code),
        framework.LogField.boolean("ok", success),
    });
    trace.finish(if (success) null else "SHELL_NON_ZERO_EXIT");

    return .{
        .title = try ctx.allocator.dupe(u8, "execute_shell"),
        .output_text = if (result.stdout.len > 0)
            try ctx.allocator.dupe(u8, result.stdout)
        else
            try ctx.allocator.dupe(u8, result.stderr),
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .command = command,
            .cwd = cwd,
            .exitCode = exit_code,
            .stderr = result.stderr,
        }),
    };
}

fn runShell(allocator: std.mem.Allocator, cwd: []const u8, command: []const u8) !std.process.Child.RunResult {
    const argv = if (builtin.os.tag == .windows)
        &[_][]const u8{ "powershell", "-NoProfile", "-Command", command }
    else
        &[_][]const u8{ "sh", "-lc", command };

    return std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv,
        .cwd = cwd,
        .max_output_bytes = 512 * 1024,
    });
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}
