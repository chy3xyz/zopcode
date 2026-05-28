const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const params = [_]framework.FieldDefinition{
    .{ .key = "url", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string, .{ .url_protocol = &.{ "http", "https" } } } },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "fetch_url",
        .description = "Fetch a HTTP or HTTPS resource",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"url\"],\"properties\":{\"url\":{\"type\":\"string\"}}}",
        .params = params[0..],
        .execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const url = paramString(fields, "url") orelse return error.MissingUrl;
    var client = std.http.Client{ .allocator = ctx.allocator, .io = std.Io.Threaded.global_single_threaded.*.io() };
    defer client.deinit();

    const uri = try std.Uri.parse(url);
    var req = try client.request(.GET, uri, .{
        .keep_alive = false,
        .headers = .{
            .user_agent = .{ .override = "zopcode/0.1.0" },
        },
    });
    defer req.deinit();
    try req.sendBodiless();

    var head_buffer: [4096]u8 = undefined;
    var response = try req.receiveHead(head_buffer[0..]);
    var transfer_buffer: [4096]u8 = undefined;
    const reader = response.reader(transfer_buffer[0..]);
    const body = try reader.allocRemaining(ctx.allocator, .limited(512 * 1024));
    defer ctx.allocator.free(body);

    ctx.logger.child("tools").child("fetch_url").info("tool executed", &.{
        framework.LogField.string("url", url),
        framework.LogField.int("status", @intFromEnum(response.head.status)),
        framework.LogField.boolean("ok", true),
    });

    return .{
        .title = try ctx.allocator.dupe(u8, "fetch_url"),
        .output_text = try ctx.allocator.dupe(u8, body),
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .url = url,
            .status = @intFromEnum(response.head.status),
        }),
    };
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}
