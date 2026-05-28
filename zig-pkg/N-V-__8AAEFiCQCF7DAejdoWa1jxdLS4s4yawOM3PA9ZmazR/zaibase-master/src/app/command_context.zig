const std = @import("std");
const core = @import("../core/root.zig");
const command_types = @import("command_types.zig");

pub const SubsystemLogger = core.logging.SubsystemLogger;
pub const ValidationField = core.validation.ValidationField;
pub const RequestContext = command_types.RequestContext;

pub const CommandContext = struct {
    allocator: std.mem.Allocator,
    request: RequestContext,
    command_id: []const u8,
    command_method: []const u8,
    command_description: []const u8,
    user_data: ?*anyopaque = null,
    logger: SubsystemLogger,
    validated_params: []const ValidationField,

    pub fn param(self: *const CommandContext, key: []const u8) ?ValidationField {
        for (self.validated_params) |field| {
            if (std.mem.eql(u8, field.key, key)) {
                return field;
            }
        }
        return null;
    }
};

test "command context can read validated params" {
    var sink = core.logging.sinks.Memory.init(std.testing.allocator, 1);
    defer sink.deinit();
    var logger = core.logging.Logger.init(sink.asLogSink(), .silent);
    defer logger.deinit();

    const params = [_]ValidationField{
        .{ .key = "method", .value = .{ .string = "app.meta" } },
    };
    const ctx = CommandContext{
        .allocator = std.testing.allocator,
        .request = .{
            .request_id = "req_01",
            .source = .@"test",
            .authority = .public,
        },
        .command_id = "app.meta",
        .command_method = "app.meta",
        .command_description = "",
        .logger = logger.child("runtime"),
        .validated_params = params[0..],
    };

    try std.testing.expect(ctx.param("method") != null);
    try std.testing.expect(ctx.param("missing") == null);
}


