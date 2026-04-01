const std = @import("std");
const framework = @import("framework");
const model = @import("../model.zig");
const client_model = @import("../client.zig");
const auth = @import("../auth.zig");
const session_events = @import("../../session/events.zig");
const error_model = framework.core.error_model;

const OpenAIEvent = struct {
    @"type": []const u8,
    delta: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    item_id: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
    item: ?OutputItem = null,
    @"error": ?ErrorPayload = null,
    response: ?ResponsePayload = null,
};

const OutputItem = struct {
    @"type": []const u8,
    call_id: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    arguments: ?[]const u8 = null,
};

const ErrorPayload = struct {
    code: ?[]const u8 = null,
    message: ?[]const u8 = null,
};

const ResponsePayload = struct {
    status: ?[]const u8 = null,
};

const ToolCallBuffer = struct {
    call_id: []u8,
    tool_name: []u8,
    input_json: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *ToolCallBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.tool_name);
        self.input_json.deinit(allocator);
    }
};

pub const OpenAIClient = struct {
    allocator: std.mem.Allocator,
    logger: ?*framework.Logger,
    event_bus: ?framework.EventBus,
    api_key: ?[]u8,
    endpoint: []u8,
    timeout_ms: ?u32 = null,

    const Self = @This();

    const vtable = client_model.ProviderClient.VTable{
        .stream = streamErased,
        .deinit = deinitErased,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        logger: ?*framework.Logger,
        event_bus: ?framework.EventBus,
        api_key_override: ?[]const u8,
    ) !Self {
        const api_key = if (api_key_override) |value|
            try allocator.dupe(u8, value)
        else
            try auth.loadOpenAIApiKey(allocator);
        const endpoint = try allocator.dupe(u8, "https://api.openai.com/v1/responses");
        return .{
            .allocator = allocator,
            .logger = logger,
            .event_bus = event_bus,
            .api_key = api_key,
            .endpoint = endpoint,
        };
    }

    pub fn asProviderClient(self: *Self) client_model.ProviderClient {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.api_key) |key| self.allocator.free(key);
        self.allocator.free(self.endpoint);
    }

    pub fn stream(self: *Self, ctx: client_model.ProviderExecutionContext, request: client_model.ProviderRequest, sink: client_model.LlmEventSink) !void {
        if (!std.mem.eql(u8, request.model.provider_id, "openai")) return error.UnsupportedProvider;

        if (self.logger) |logger| {
            logger.child("provider").child("openai").info("openai request started", &.{
                framework.LogField.string("model_id", request.model.model_id),
                framework.LogField.int("message_count", @intCast(request.messages.len)),
            });
        }

        if (self.api_key == null) {
            const failed = client_model.ProviderStreamEvent{
                .failed = .{
                    .code = error_model.code.PROVIDER_OPERATION_FAILED,
                    .message = "OpenAI API key is not configured",
                    .retryable = false,
                },
            };
            try sink.onEvent(&failed);
            return error.ProviderAuthMissing;
        }

        const body = try buildRequestBody(self.allocator, request);
        defer self.allocator.free(body);

        var http_client = std.http.Client{ .allocator = self.allocator };
        defer http_client.deinit();

        const uri = try std.Uri.parse(self.endpoint);
        const auth_header = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{self.api_key.?});
        defer self.allocator.free(auth_header);
        const extra_headers = [_]std.http.Header{
            .{ .name = "authorization", .value = auth_header },
        };

        var req = try http_client.request(.POST, uri, .{
            .keep_alive = false,
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .user_agent = .{ .override = "zig-opencode/0.1.0" },
            },
            .extra_headers = extra_headers[0..],
        });
        defer req.deinit();

        req.transfer_encoding = .{ .content_length = body.len };
        var send_buffer: [4096]u8 = undefined;
        var body_writer = try req.sendBodyUnflushed(send_buffer[0..]);
        try body_writer.writer.writeAll(body);
        try body_writer.end();
        try req.connection.?.flush();

        var redirect_buffer: [4096]u8 = undefined;
        var response = try req.receiveHead(redirect_buffer[0..]);

        if (response.head.status != .ok) {
            const status_message = try std.fmt.allocPrint(self.allocator, "OpenAI returned HTTP {d}", .{@intFromEnum(response.head.status)});
            defer self.allocator.free(status_message);

            const failed = client_model.ProviderStreamEvent{
                .failed = .{
                    .code = error_model.code.PROVIDER_OPERATION_FAILED,
                    .message = status_message,
                    .retryable = @intFromEnum(response.head.status) >= 500,
                },
            };
            try sink.onEvent(&failed);
            return error.ProviderOperationFailed;
        }

        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(transfer_buffer[0..]);
        try processSseStream(self, ctx, reader, sink);

        if (self.logger) |logger| {
            logger.child("provider").child("openai").info("openai request completed", &.{
                framework.LogField.string("model_id", request.model.model_id),
            });
        }
    }

    fn processSseStream(self: *Self, ctx: client_model.ProviderExecutionContext, reader: *std.Io.Reader, sink: client_model.LlmEventSink) !void {
        var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer line_buffer.deinit(self.allocator);

        var data_buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer data_buffer.deinit(self.allocator);

        var tool_buffers = std.StringHashMapUnmanaged(ToolCallBuffer){};
        defer {
            var it = tool_buffers.iterator();
            while (it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                entry.value_ptr.deinit(self.allocator);
            }
            tool_buffers.deinit(self.allocator);
        }

        while (true) {
            const ch = reader.*.takeByte() catch |err| switch (err) {
                error.EndOfStream => {
                    try flushDataBuffer(self, ctx, &tool_buffers, &data_buffer, sink);
                    break;
                },
                else => return err,
            };
            if (ch == '\n') {
                const line = std.mem.trimRight(u8, line_buffer.items, "\r");
                if (line.len == 0) {
                    try flushDataBuffer(self, ctx, &tool_buffers, &data_buffer, sink);
                } else if (std.mem.startsWith(u8, line, "data:")) {
                    const payload = std.mem.trimLeft(u8, line["data:".len..], " ");
                    try data_buffer.appendSlice(self.allocator, payload);
                }
                line_buffer.clearRetainingCapacity();
            } else {
                try line_buffer.append(self.allocator, ch);
            }
        }
    }

    fn flushDataBuffer(
        self: *Self,
        ctx: client_model.ProviderExecutionContext,
        tool_buffers: *std.StringHashMapUnmanaged(ToolCallBuffer),
        data_buffer: *std.ArrayListUnmanaged(u8),
        sink: client_model.LlmEventSink,
    ) !void {
        if (data_buffer.items.len == 0) return;
        defer data_buffer.clearRetainingCapacity();

        if (std.mem.eql(u8, data_buffer.items, "[DONE]")) {
            const completed = client_model.ProviderStreamEvent{ .completed = .{} };
            try sink.onEvent(&completed);
            return;
        }

        const parsed = try std.json.parseFromSlice(OpenAIEvent, self.allocator, data_buffer.items, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const payload = parsed.value;

        if (std.mem.eql(u8, payload.@"type", "response.output_text.delta")) {
            try sink.onEvent(&client_model.ProviderStreamEvent{
                .text_delta = .{ .text = payload.delta orelse "" },
            });
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "response.reasoning.delta") or std.mem.eql(u8, payload.@"type", "response.reasoning_summary_text.delta")) {
            try sink.onEvent(&client_model.ProviderStreamEvent{
                .reasoning_delta = .{ .text = payload.delta orelse "" },
            });
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "response.output_item.added")) {
            if (payload.item) |item| {
                if (std.mem.eql(u8, item.@"type", "function_call")) {
                    const call_id = item.call_id orelse item.id orelse return;
                    const key = try self.allocator.dupe(u8, call_id);
                    errdefer self.allocator.free(key);

                    var buffer = ToolCallBuffer{
                        .call_id = try self.allocator.dupe(u8, call_id),
                        .tool_name = try self.allocator.dupe(u8, item.name orelse ""),
                    };
                    errdefer buffer.deinit(self.allocator);

                    if (item.arguments) |arguments| {
                        try buffer.input_json.appendSlice(self.allocator, arguments);
                    }
                    try tool_buffers.put(self.allocator, key, buffer);

                    try sink.onEvent(&client_model.ProviderStreamEvent{
                        .tool_call_started = .{
                            .call_id = buffer.call_id,
                            .tool_name = buffer.tool_name,
                        },
                    });
                }
            }
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "response.function_call_arguments.delta")) {
            const call_id = payload.call_id orelse payload.item_id orelse return;
            if (tool_buffers.getPtr(call_id)) |buffer| {
                const partial = payload.delta orelse "";
                try buffer.input_json.appendSlice(self.allocator, partial);
                try sink.onEvent(&client_model.ProviderStreamEvent{
                    .tool_call_delta = .{
                        .call_id = buffer.call_id,
                        .partial_json = partial,
                    },
                });
            }
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "response.function_call_arguments.done")) {
            const call_id = payload.call_id orelse payload.item_id orelse return;
            if (tool_buffers.fetchRemove(call_id)) |entry| {
                self.allocator.free(entry.key);
                var buffer = entry.value;
                defer buffer.deinit(self.allocator);

                if (buffer.input_json.items.len == 0) {
                    if (payload.arguments) |arguments| {
                        try buffer.input_json.appendSlice(self.allocator, arguments);
                    }
                }

                try sink.onEvent(&client_model.ProviderStreamEvent{
                    .tool_call_completed = .{
                        .call_id = buffer.call_id,
                        .tool_name = buffer.tool_name,
                        .input_json = buffer.input_json.items,
                    },
                });
                try session_events.publishToolCallEvent(self.allocator, ctx.event_bus, .{
                    .request_id = ctx.request_id,
                    .session_id = ctx.session_id,
                    .trace_id = ctx.trace_id,
                    .call_id = buffer.call_id,
                    .tool_name = buffer.tool_name,
                    .input_json = buffer.input_json.items,
                });
            }
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "response.completed")) {
            try sink.onEvent(&client_model.ProviderStreamEvent{
                .completed = .{
                    .stop_reason = if (payload.response) |response| response.status else "completed",
                },
            });
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "response.failed") or std.mem.eql(u8, payload.@"type", "error")) {
            try sink.onEvent(&client_model.ProviderStreamEvent{
                .failed = .{
                    .code = if (payload.@"error") |err_payload| err_payload.code orelse error_model.code.PROVIDER_OPERATION_FAILED else error_model.code.PROVIDER_OPERATION_FAILED,
                    .message = if (payload.@"error") |err_payload| err_payload.message orelse "OpenAI response failed" else "OpenAI response failed",
                    .retryable = false,
                },
            });
            return;
        }
    }

    fn buildRequestBody(allocator: std.mem.Allocator, request: client_model.ProviderRequest) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(allocator);
        const writer = list.writer(allocator);

        try writer.writeByte('{');
        try writer.print("\"model\":\"{s}\",\"stream\":true,\"max_output_tokens\":{d}", .{
            request.model.model_id,
            request.max_tokens,
        });

        if (request.system_prompt) |system_prompt| {
            try writer.writeAll(",\"instructions\":");
            try writeJsonString(writer, system_prompt);
        }

        try writer.writeAll(",\"input\":[");
        for (request.messages, 0..) |message, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"role\":");
            try writeJsonString(writer, message.role.asText());
            try writer.writeAll(",\"content\":[{\"type\":\"input_text\",\"text\":");
            try writeJsonString(writer, message.content);
            try writer.writeAll("}]}");
        }
        try writer.writeByte(']');

        if (request.tools.len > 0) {
            try writer.writeAll(",\"tools\":[");
            for (request.tools, 0..) |tool_def, index| {
                if (index > 0) try writer.writeByte(',');
                try writer.writeAll("{\"type\":\"function\",\"name\":");
                try writeJsonString(writer, tool_def.name);
                try writer.writeAll(",\"description\":");
                try writeJsonString(writer, tool_def.description);
                try writer.writeAll(",\"parameters\":");
                try writer.writeAll(tool_def.input_schema_json);
                try writer.writeByte('}');
            }
            try writer.writeByte(']');
        }

        try writer.writeByte('}');
        return allocator.dupe(u8, list.items);
    }

    fn writeJsonString(writer: anytype, value: []const u8) !void {
        try writer.writeByte('"');
        for (value) |ch| {
            switch (ch) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => {
                    if (ch < 32) {
                        try writer.print("\\u00{x:0>2}", .{ch});
                    } else {
                        try writer.writeByte(ch);
                    }
                },
            }
        }
        try writer.writeByte('"');
    }

    fn streamErased(ptr: *anyopaque, ctx: client_model.ProviderExecutionContext, request: client_model.ProviderRequest, sink: client_model.LlmEventSink) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.stream(ctx, request, sink);
    }

    fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
        allocator.destroy(self);
    }
};

pub fn createClient(allocator: std.mem.Allocator, ctx: @import("../registry.zig").ProviderRegistry.ProviderCreateContext) !client_model.ProviderClient {
    const client = try allocator.create(OpenAIClient);
    client.* = try OpenAIClient.init(allocator, ctx.logger, ctx.event_bus, ctx.api_key);
    if (ctx.base_url) |base_url| {
        client.allocator.free(client.endpoint);
        client.endpoint = try allocator.dupe(u8, base_url);
    }
    client.timeout_ms = ctx.timeout_ms;
    return client.asProviderClient();
}

test "openai request body includes stream input and tools" {
    const messages = [_]model.ProviderMessage{
        .{ .role = .user, .content = "hello openai" },
    };
    const tools = [_]model.ProviderToolDefinition{
        .{ .name = "read_file", .description = "Read a file", .input_schema_json = "{\"type\":\"object\"}" },
    };
    const request = client_model.ProviderRequest{
        .model = .{ .provider_id = "openai", .model_id = "gpt-5" },
        .system_prompt = "You are helpful",
        .messages = messages[0..],
        .tools = tools[0..],
        .max_tokens = 256,
    };
    const json = try OpenAIClient.buildRequestBody(std.testing.allocator, request);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"gpt-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"instructions\":\"You are helpful\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"type\":\"function\"") != null);
}

test "openai SSE parser emits text and tool call events" {
    const Sink = struct {
        allocator: std.mem.Allocator,
        saw_tool_start: bool = false,
        saw_tool_complete: bool = false,
        saw_text_delta: bool = false,

        fn onEvent(ptr: *anyopaque, event: *const client_model.ProviderStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (event.*) {
                .tool_call_started => |value| {
                    self.saw_tool_start = true;
                    try std.testing.expectEqualStrings("read_file", value.tool_name);
                },
                .tool_call_completed => |value| {
                    self.saw_tool_complete = true;
                    try std.testing.expectEqualStrings("read_file", value.tool_name);
                    try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", value.input_json);
                },
                .text_delta => |value| {
                    self.saw_text_delta = true;
                    try std.testing.expectEqualStrings("done", value.text);
                },
                else => {},
            }
        }
    };

    var bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();

    var client = OpenAIClient{
        .allocator = std.testing.allocator,
        .logger = null,
        .event_bus = bus.asEventBus(),
        .api_key = null,
        .endpoint = try std.testing.allocator.dupe(u8, "https://api.openai.com/v1/responses"),
    };
    defer std.testing.allocator.free(client.endpoint);
    var sink_state = Sink{ .allocator = std.testing.allocator };

    const sink = client_model.LlmEventSink{
        .ptr = @ptrCast(&sink_state),
        .on_event = Sink.onEvent,
    };

    const payload =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"call_id\":\"call_01\",\"name\":\"read_file\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"call_id\":\"call_01\",\"delta\":\"{\\\"path\\\":\\\"a.txt\\\"\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"call_id\":\"call_01\",\"delta\":\"}\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"call_id\":\"call_01\"}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"done\"}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";

    var reader = std.Io.Reader.fixed(payload);
    try client.processSseStream(.{
        .allocator = std.testing.allocator,
        .event_bus = bus.asEventBus(),
        .request_id = "req_01",
        .session_id = "session_01",
    }, &reader, sink);

    try std.testing.expect(sink_state.saw_tool_start);
    try std.testing.expect(sink_state.saw_tool_complete);
    try std.testing.expect(sink_state.saw_text_delta);
    try std.testing.expectEqual(@as(usize, 1), bus.count());
}

test "openai SSE parser maps error payloads into provider failure" {
    const Sink = struct {
        saw_failure: bool = false,

        fn onEvent(ptr: *anyopaque, event: *const client_model.ProviderStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            switch (event.*) {
                .failed => |value| {
                    self.saw_failure = true;
                    try std.testing.expectEqualStrings("rate_limit_exceeded", value.code);
                    try std.testing.expectEqualStrings("too many requests", value.message);
                },
                else => {},
            }
        }
    };

    var client = OpenAIClient{
        .allocator = std.testing.allocator,
        .logger = null,
        .event_bus = null,
        .api_key = null,
        .endpoint = try std.testing.allocator.dupe(u8, "https://api.openai.com/v1/responses"),
    };
    defer std.testing.allocator.free(client.endpoint);
    var sink_state = Sink{};

    const sink = client_model.LlmEventSink{
        .ptr = @ptrCast(&sink_state),
        .on_event = Sink.onEvent,
    };

    const payload = "data: {\"type\":\"error\",\"error\":{\"code\":\"rate_limit_exceeded\",\"message\":\"too many requests\"}}\n\n";
    var reader = std.Io.Reader.fixed(payload);
    try client.processSseStream(.{ .allocator = std.testing.allocator }, &reader, sink);

    try std.testing.expect(sink_state.saw_failure);
}

test "openai create client respects configured base url" {
    const client = try createClient(std.testing.allocator, .{
        .base_url = "https://proxy.example.com/v1/responses",
    });
    defer client.deinit(std.testing.allocator);

    const typed: *OpenAIClient = @ptrCast(@alignCast(client.ptr));
    try std.testing.expectEqualStrings("https://proxy.example.com/v1/responses", typed.endpoint);
}
