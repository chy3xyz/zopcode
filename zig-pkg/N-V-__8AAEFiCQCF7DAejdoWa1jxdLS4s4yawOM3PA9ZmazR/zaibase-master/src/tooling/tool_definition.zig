const std = @import("std");
const app = @import("../app/root.zig");
const core = @import("../core/root.zig");
const tool_context = @import("tool_context.zig");
const script_contract = @import("script_contract.zig");

pub const ToolExecutionKind = enum {
    native_zig,
    external_json_stdio,

    pub fn asText(self: ToolExecutionKind) []const u8 {
        return switch (self) {
            .native_zig => "native_zig",
            .external_json_stdio => "external_json_stdio",
        };
    }
};

pub const ToolDefinition = struct {
    id: []const u8,
    description: []const u8,
    authority: app.Authority = .public,
    params: []const core.validation.FieldDefinition = &.{},
    execution_kind: ToolExecutionKind = .native_zig,
    native_handler: ?NativeToolHandler = null,
    script_spec: ?script_contract.ScriptSpec = null,
};

pub const NativeToolHandler = *const fn (ctx: *const tool_context.ToolContext) anyerror![]u8;

test "tool definition keeps stable defaults" {
    const definition = ToolDefinition{
        .id = "demo",
        .description = "demo tool",
    };

    try std.testing.expectEqualStrings("demo", definition.id);
    try std.testing.expectEqualStrings("demo tool", definition.description);
    try std.testing.expectEqual(app.Authority.public, definition.authority);
    try std.testing.expectEqual(@as(usize, 0), definition.params.len);
    try std.testing.expectEqual(ToolExecutionKind.native_zig, definition.execution_kind);
    try std.testing.expect(definition.native_handler == null);
    try std.testing.expect(definition.script_spec == null);
}


