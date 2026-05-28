const std = @import("std");
const framework = @import("framework");
const model = @import("../model.zig");
const client_model = @import("../client.zig");
const auth = @import("../auth.zig");
const session_events = @import("../../session/events.zig");
const error_model = framework.core.error_model;

const AnthropicRequestEvent = struct {
    @"type": []const u8,
    index: ?usize = null,
    content_block: ?ContentBlock = null,
    delta: ?Delta = null,
    message: ?MessageDelta = null,
};

const ContentBlock = struct {
    @"type": []const u8,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
};

const Delta = struct {
    @"type": []const u8,
    text: ?[]const u8 = null,
    partial_json: ?[]const u8 = null,
    stop_reason: ?[]const u8 = null,
};

const MessageDelta = struct {
    stop_reason: ?[]const u8 = null,
};

const ToolCallBuffer = struct {
    id: []u8,
    name: []u8,
    input_json: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *ToolCallBuffer, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.input_json.deinit(allocator);
    }
};

pub const AnthropicClient = struct {
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

    pub fn init(allocator: std.mem.Allocator, logger: ?*framework.Logger, event_bus: ?framework.EventBus, api_key_override: ?[]const u8) !Self {
        const api_key = if (api_key_override) |value|
            try allocator.dupe(u8, value)
        else
            try auth.loadAnthropicApiKey(allocator);
        const endpoint = try allocator.dupe(u8, "https://api.anthropic.com/v1/messages");
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
        if (!std.mem.eql(u8, request.model.provider_id, "anthropic")) return error.UnsupportedProvider;

        if (self.logger) |logger| {
            logger.child("provider").child("anthropic").info("anthropic request started", &.{
                framework.LogField.string("model_id", request.model.model_id),
                framework.LogField.int("message_count", @intCast(request.messages.len)),
            });
        }

        if (self.api_key == null) {
            const failed = client_model.ProviderStreamEvent{
                    .failed = .{
                    .code = error_model.code.PROVIDER_OPERATION_FAILED,
                    .message = "Anthropic API key is not configured",
                    .retryable = false,
                },
            };
            try sink.onEvent(&failed);
            return error.ProviderAuthMissing;
        }

        const body = try buildRequestBody(self.allocator, request);
        defer self.allocator.free(body);

        var http_client = std.http.Client{ .allocator = self.allocator, .io = std.Io.Threaded.global_single_threaded.*.io() };
        defer http_client.deinit();

        const uri = try std.Uri.parse(self.endpoint);
        const extra_headers = [_]std.http.Header{
            .{ .name = "x-api-key", .value = self.api_key.? },
            .{ .name = "anthropic-version", .value = "2023-06-01" },
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
            const status_message = try std.fmt.allocPrint(self.allocator, "Anthropic returned HTTP {d}", .{@intFromEnum(response.head.status)});
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
            logger.child("provider").child("anthropic").info("anthropic request completed", &.{
                framework.LogField.string("model_id", request.model.model_id),
            });
        }
    }

    fn processSseStream(self: *Self, ctx: client_model.ProviderExecutionContext, reader: *std.Io.Reader, sink: client_model.LlmEventSink) !void {
        var line_buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer line_buffer.deinit(self.allocator);

        var data_buffer: std.ArrayListUnmanaged(u8) = .empty;
        defer data_buffer.deinit(self.allocator);

        var tool_buffers = std.AutoHashMapUnmanaged(usize, ToolCallBuffer){};
        defer {
            var it = tool_buffers.iterator();
            while (it.next()) |entry| entry.value_ptr.deinit(self.allocator);
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
                const line = std.mem.trimEnd(u8, line_buffer.items, "\r");
                if (line.len == 0) {
                    try flushDataBuffer(self, ctx, &tool_buffers, &data_buffer, sink);
                } else if (std.mem.startsWith(u8, line, "data:")) {
                    const payload = std.mem.trimStart(u8, line["data:".len..], " ");
                    try data_buffer.appendSlice(self.allocator, payload);
                }
                line_buffer.clearRetainingCapacity();
            } else {
                try line_buffer.append(self.allocator, ch);
            }
        }
    }

    fn flushDataBuffer(self: *Self, ctx: client_model.ProviderExecutionContext, tool_buffers: *std.AutoHashMapUnmanaged(usize, ToolCallBuffer), data_buffer: *std.ArrayListUnmanaged(u8), sink: client_model.LlmEventSink) !void {
        if (data_buffer.items.len == 0) return;
        defer data_buffer.clearRetainingCapacity();

        if (std.mem.eql(u8, data_buffer.items, "[DONE]")) {
            const completed = client_model.ProviderStreamEvent{ .completed = .{} };
            try sink.onEvent(&completed);
            return;
        }

        const parsed = try std.json.parseFromSlice(AnthropicRequestEvent, self.allocator, data_buffer.items, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        const payload = parsed.value;

        if (std.mem.eql(u8, payload.@"type", "content_block_start")) {
            if (payload.content_block) |content_block| {
                if (std.mem.eql(u8, content_block.@"type", "tool_use")) {
                    const index = payload.index orelse return;
                    const buffer = ToolCallBuffer{
                        .id = try self.allocator.dupe(u8, content_block.id orelse ""),
                        .name = try self.allocator.dupe(u8, content_block.name orelse ""),
                    };
                    try tool_buffers.put(self.allocator, index, buffer);

                    const event = client_model.ProviderStreamEvent{
                        .tool_call_started = .{
                            .call_id = buffer.id,
                            .tool_name = buffer.name,
                        },
                    };
                    try sink.onEvent(&event);
                }
            }
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "content_block_delta")) {
            const index = payload.index orelse return;
            if (payload.delta) |delta| {
                if (std.mem.eql(u8, delta.@"type", "text_delta")) {
                    const text = delta.text orelse "";
                    const event = client_model.ProviderStreamEvent{
                        .text_delta = .{ .text = text },
                    };
                    try sink.onEvent(&event);
                    return;
                }

                if (std.mem.eql(u8, delta.@"type", "input_json_delta")) {
                    const partial = delta.partial_json orelse "";
                    if (tool_buffers.getPtr(index)) |buffer| {
                        try buffer.input_json.appendSlice(self.allocator, partial);
                        const event = client_model.ProviderStreamEvent{
                            .tool_call_delta = .{
                                .call_id = buffer.id,
                                .partial_json = partial,
                            },
                        };
                        try sink.onEvent(&event);
                    }
                    return;
                }
            }
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "content_block_stop")) {
            const index = payload.index orelse return;
            if (tool_buffers.fetchRemove(index)) |entry| {
                var buffer = entry.value;
                defer buffer.deinit(self.allocator);

                const event = client_model.ProviderStreamEvent{
                    .tool_call_completed = .{
                        .call_id = buffer.id,
                        .tool_name = buffer.name,
                        .input_json = buffer.input_json.items,
                    },
                };
                try sink.onEvent(&event);
                try session_events.publishToolCallEvent(self.allocator, ctx.event_bus, .{
                    .request_id = ctx.request_id,
                    .session_id = ctx.session_id,
                    .trace_id = ctx.trace_id,
                    .call_id = buffer.id,
                    .tool_name = buffer.name,
                    .input_json = buffer.input_json.items,
                });
            }
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "message_delta")) {
            const stop_reason = if (payload.delta) |delta| delta.stop_reason else if (payload.message) |message| message.stop_reason else null;
            const completed = client_model.ProviderStreamEvent{
                .completed = .{ .stop_reason = stop_reason },
            };
            try sink.onEvent(&completed);
            return;
        }

        if (std.mem.eql(u8, payload.@"type", "message_stop")) {
            const completed = client_model.ProviderStreamEvent{ .completed = .{} };
            try sink.onEvent(&completed);
            return;
        }
    }

    fn buildRequestBody(allocator: std.mem.Allocator, request: client_model.ProviderRequest) ![]u8 {
        var list: std.ArrayListUnmanaged(u8) = .empty;
        defer list.deinit(allocator);
    
        try list.append(allocator, '{');
        try list.print(allocator, "\"model\":\"{s}\",\"stream\":true,\"max_tokens\":{d}", .{
            request.model.model_id,
            request.max_tokens,
        });

        if (request.system_prompt) |system_prompt| {
            try list.appendSlice(allocator, ",\"system\":");
            try writeJsonString(&list, allocator, system_prompt);
        }

        try list.appendSlice(allocator, ",\"messages\":[");
        for (request.messages, 0..) |message, index| {
            if (index > 0) try list.append(allocator, ',');
            try list.appendSlice(allocator, "{\"role\":");
            try writeJsonString(&list, allocator, message.role.asText());
            try list.appendSlice(allocator, ",\"content\":");
            try writeJsonString(&list, allocator, message.content);
            try list.append(allocator, '}');
        }
        try list.append(allocator, ']');

        if (request.tools.len > 0) {
            try list.appendSlice(allocator, ",\"tools\":[");
            for (request.tools, 0..) |tool_def, index| {
                if (index > 0) try list.append(allocator, ',');
                try list.appendSlice(allocator, "{\"name\":");
                try writeJsonString(&list, allocator, tool_def.name);
                try list.appendSlice(allocator, ",\"description\":");
                try writeJsonString(&list, allocator, tool_def.description);
                try list.appendSlice(allocator, ",\"input_schema\":");
                try list.appendSlice(allocator, tool_def.input_schema_json);
                try list.append(allocator, '}');
            }
            try list.append(allocator, ']');
        }

        try list.append(allocator, '}');
        return allocator.dupe(u8, list.items);
    }

    fn writeJsonString(list: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
        try list.append(allocator, '"');
        for (value) |ch| {
            switch (ch) {
                '"' => try list.appendSlice(allocator, "\\\""),
                '\\' => try list.appendSlice(allocator, "\\\\"),
                '\n' => try list.appendSlice(allocator, "\\n"),
                '\r' => try list.appendSlice(allocator, "\\r"),
                '\t' => try list.appendSlice(allocator, "\\t"),
                else => {
                    if (ch < 32) {
                        try list.print(allocator, "\\u00{x:0>2}", .{ch});
                    } else {
                        try list.append(allocator, ch);
                    }
                },
            }
        }
        try list.append(allocator, '"');
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
    const client = try allocator.create(AnthropicClient);
    client.* = try AnthropicClient.init(allocator, ctx.logger, ctx.event_bus, ctx.api_key);
    if (ctx.base_url) |base_url| {
        client.allocator.free(client.endpoint);
        client.endpoint = try allocator.dupe(u8, base_url);
    }
    client.timeout_ms = ctx.timeout_ms;
    return client.asProviderClient();
}

test "anthropic request body includes stream and messages" {
    const messages = [_]model.ProviderMessage{
        .{ .role = .user, .content = "hello anthropic" },
    };
    const request = client_model.ProviderRequest{
        .model = .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4-5" },
        .messages = messages[0..],
        .max_tokens = 256,
    };
    const json = try AnthropicClient.buildRequestBody(std.testing.allocator, request);
    defer std.testing.allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"claude-sonnet-4-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages\"") != null);
}

test "anthropic SSE parser emits text and completed tool call events" {
    const Sink = struct {
        allocator: std.mem.Allocator,
        events: std.ArrayListUnmanaged(client_model.ProviderStreamEvent) = .empty,

        fn onEvent(ptr: *anyopaque, event: *const client_model.ProviderStreamEvent) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const copied = switch (event.*) {
                .text_delta => |value| client_model.ProviderStreamEvent{
                    .text_delta = .{ .text = try self.allocator.dupe(u8, value.text) },
                },
                .reasoning_delta => |value| client_model.ProviderStreamEvent{
                    .reasoning_delta = .{ .text = try self.allocator.dupe(u8, value.text) },
                },
                .tool_call_started => |value| client_model.ProviderStreamEvent{
                    .tool_call_started = .{
                        .call_id = try self.allocator.dupe(u8, value.call_id),
                        .tool_name = try self.allocator.dupe(u8, value.tool_name),
                    },
                },
                .tool_call_delta => |value| client_model.ProviderStreamEvent{
                    .tool_call_delta = .{
                        .call_id = try self.allocator.dupe(u8, value.call_id),
                        .partial_json = try self.allocator.dupe(u8, value.partial_json),
                    },
                },
                .tool_call_completed => |value| client_model.ProviderStreamEvent{
                    .tool_call_completed = .{
                        .call_id = try self.allocator.dupe(u8, value.call_id),
                        .tool_name = try self.allocator.dupe(u8, value.tool_name),
                        .input_json = try self.allocator.dupe(u8, value.input_json),
                    },
                },
                .completed => |value| client_model.ProviderStreamEvent{
                    .completed = .{
                        .stop_reason = if (value.stop_reason) |stop_reason| try self.allocator.dupe(u8, stop_reason) else null,
                    },
                },
                .failed => |value| client_model.ProviderStreamEvent{
                    .failed = .{
                        .code = try self.allocator.dupe(u8, value.code),
                        .message = try self.allocator.dupe(u8, value.message),
                        .retryable = value.retryable,
                    },
                },
            };
            try self.events.append(self.allocator, copied);
        }

        fn deinit(self: *@This()) void {
            for (self.events.items) |event| {
                switch (event) {
                    .text_delta => |value| self.allocator.free(value.text),
                    .reasoning_delta => |value| self.allocator.free(value.text),
                    .tool_call_started => |value| {
                        self.allocator.free(value.call_id);
                        self.allocator.free(value.tool_name);
                    },
                    .tool_call_delta => |value| {
                        self.allocator.free(value.call_id);
                        self.allocator.free(value.partial_json);
                    },
                    .tool_call_completed => |value| {
                        self.allocator.free(value.call_id);
                        self.allocator.free(value.tool_name);
                        self.allocator.free(value.input_json);
                    },
                    .completed => |value| if (value.stop_reason) |stop_reason| self.allocator.free(stop_reason),
                    .failed => |value| {
                        self.allocator.free(value.code);
                        self.allocator.free(value.message);
                    },
                }
            }
            self.events.deinit(self.allocator);
        }
    };

    var bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();

    var client = AnthropicClient{
        .allocator = std.testing.allocator,
        .logger = null,
        .event_bus = bus.asEventBus(),
        .api_key = null,
        .endpoint = try std.testing.allocator.dupe(u8, "https://api.anthropic.com/v1/messages"),
    };
    defer std.testing.allocator.free(client.endpoint);

    var sink_state = Sink{ .allocator = std.testing.allocator };
    defer sink_state.deinit();

    const sink = client_model.LlmEventSink{
        .ptr = @ptrCast(&sink_state),
        .on_event = Sink.onEvent,
    };

    const payload =
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"call_01\",\"name\":\"read_file\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"a.txt\\\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";

    var reader = std.Io.Reader.fixed(payload);
    const ctx = client_model.ProviderExecutionContext{
        .allocator = std.testing.allocator,
        .event_bus = bus.asEventBus(),
        .request_id = "req_01",
        .session_id = "session_01",
    };

    try client.processSseStream(ctx, &reader, sink);

    try std.testing.expect(sink_state.events.items.len >= 4);

    var saw_tool_start = false;
    var saw_tool_complete = false;
    var saw_text_delta = false;

    for (sink_state.events.items) |event| {
        switch (event) {
            .tool_call_started => |value| {
                try std.testing.expectEqualStrings("read_file", value.tool_name);
                saw_tool_start = true;
            },
            .tool_call_completed => |value| {
                try std.testing.expectEqualStrings("read_file", value.tool_name);
                try std.testing.expectEqualStrings("{\"path\":\"a.txt\"}", value.input_json);
                saw_tool_complete = true;
            },
            .text_delta => |value| {
                try std.testing.expectEqualStrings("done", value.text);
                saw_text_delta = true;
            },
            else => {},
        }
    }

    try std.testing.expect(saw_tool_start);
    try std.testing.expect(saw_tool_complete);
    try std.testing.expect(saw_text_delta);
    try std.testing.expectEqual(@as(usize, 1), bus.count());
}
