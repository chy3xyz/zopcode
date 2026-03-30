const std = @import("std");
const framework = @import("framework");
const context_model = @import("context.zig");
const result_model = @import("result.zig");

pub const SyncToolExecuteFn = *const fn (ctx: *const context_model.ToolExecutionContext, params: []const framework.ValidationField) anyerror!result_model.ToolResult;
pub const AsyncToolExecuteFn = *const fn (ctx: *const context_model.ToolExecutionContext, params: []const framework.ValidationField) anyerror!result_model.ToolResult;

pub const ToolDefinition = struct {
    id: []const u8,
    description: []const u8,
    input_schema_json: []const u8 = "{}",
    params: []const framework.FieldDefinition = &.{},
    execution_mode: framework.CommandExecutionMode = .sync,
    execute_fn: ?SyncToolExecuteFn = null,
    async_execute_fn: ?AsyncToolExecuteFn = null,

    pub fn clone(self: ToolDefinition, allocator: std.mem.Allocator) !ToolDefinition {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .description = try allocator.dupe(u8, self.description),
            .input_schema_json = try allocator.dupe(u8, self.input_schema_json),
            .params = self.params,
            .execution_mode = self.execution_mode,
            .execute_fn = self.execute_fn,
            .async_execute_fn = self.async_execute_fn,
        };
    }

    pub fn deinit(self: *ToolDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.description);
        allocator.free(self.input_schema_json);
    }
};

test "tool definition can be cloned" {
    var cloned = try (ToolDefinition{
        .id = "read_file",
        .description = "Read file contents",
    }).clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("read_file", cloned.id);
}
