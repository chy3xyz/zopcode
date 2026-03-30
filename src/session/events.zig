const std = @import("std");
const framework = @import("framework");

pub const TOOL_CALL_EVENT_TOPIC = "tool.call.detected";
pub const TOOL_RESULT_COMPLETED_EVENT_TOPIC = "tool.result.completed";
pub const TOOL_RESULT_FAILED_EVENT_TOPIC = "tool.result.failed";
pub const PROVIDER_RESPONSE_DELTA_TOPIC = "provider.response.delta";
pub const PROVIDER_RESPONSE_COMPLETED_TOPIC = "provider.response.completed";
pub const PROVIDER_RESPONSE_FAILED_TOPIC = "provider.response.failed";
pub const SESSION_CREATED_EVENT_TOPIC = "session.created";
pub const SESSION_UPDATED_EVENT_TOPIC = "session.updated";
pub const SESSION_MESSAGE_CREATED_EVENT_TOPIC = "session.message.created";
pub const SESSION_PART_APPENDED_EVENT_TOPIC = "session.part.appended";
pub const SESSION_STATUS_EVENT_TOPIC = "session.status";

pub const ToolCallEvent = struct {
    request_id: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    call_id: []const u8,
    tool_name: []const u8,
    input_json: []const u8,
};

pub const SessionCreatedEvent = struct {
    session_id: []const u8,
    agent_id: []const u8,
    title: []const u8,
};

pub const SessionUpdatedEvent = struct {
    session_id: []const u8,
    reason: []const u8,
};

pub const SessionMessageCreatedEvent = struct {
    session_id: []const u8,
    message_id: []const u8,
    role: []const u8,
};

pub const SessionPartAppendedEvent = struct {
    session_id: []const u8,
    message_id: []const u8,
    part_id: []const u8,
    part_kind: []const u8,
};

pub const SessionStatusEvent = struct {
    session_id: []const u8,
    status: []const u8,
    request_id: []const u8,

    pub fn clone(self: SessionStatusEvent, allocator: std.mem.Allocator) !SessionStatusEvent {
        return .{
            .session_id = try allocator.dupe(u8, self.session_id),
            .status = try allocator.dupe(u8, self.status),
            .request_id = try allocator.dupe(u8, self.request_id),
        };
    }

    pub fn deinit(self: *SessionStatusEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.status);
        allocator.free(self.request_id);
    }
};

pub const ToolResultEvent = struct {
    request_id: []const u8,
    session_id: []const u8,
    trace_id: ?[]const u8 = null,
    call_id: []const u8,
    tool_name: []const u8,
    output_text: []const u8,
    metadata_json: []const u8,
    ok: bool,
    error_code: ?[]const u8 = null,

    pub fn clone(self: ToolResultEvent, allocator: std.mem.Allocator) !ToolResultEvent {
        return .{
            .request_id = try allocator.dupe(u8, self.request_id),
            .session_id = try allocator.dupe(u8, self.session_id),
            .trace_id = if (self.trace_id) |trace_id| try allocator.dupe(u8, trace_id) else null,
            .call_id = try allocator.dupe(u8, self.call_id),
            .tool_name = try allocator.dupe(u8, self.tool_name),
            .output_text = try allocator.dupe(u8, self.output_text),
            .metadata_json = try allocator.dupe(u8, self.metadata_json),
            .ok = self.ok,
            .error_code = if (self.error_code) |error_code| try allocator.dupe(u8, error_code) else null,
        };
    }

    pub fn deinit(self: *ToolResultEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.request_id);
        allocator.free(self.session_id);
        if (self.trace_id) |trace_id| allocator.free(trace_id);
        allocator.free(self.call_id);
        allocator.free(self.tool_name);
        allocator.free(self.output_text);
        allocator.free(self.metadata_json);
        if (self.error_code) |error_code| allocator.free(error_code);
    }
};

pub const ProviderResponseEvent = struct {
    topic: []const u8,
    request_id: []const u8,
    session_id: []const u8,
    trace_id: ?[]const u8 = null,
};

pub const SessionTimelineEvent = struct {
    topic: []const u8,
    session_id: []const u8,
    message_id: ?[]const u8 = null,
    part_id: ?[]const u8 = null,
    role: ?[]const u8 = null,
    part_kind: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    title: ?[]const u8 = null,
    reason: ?[]const u8 = null,

    pub fn deinit(self: *SessionTimelineEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.topic);
        allocator.free(self.session_id);
        if (self.message_id) |message_id| allocator.free(message_id);
        if (self.part_id) |part_id| allocator.free(part_id);
        if (self.role) |role| allocator.free(role);
        if (self.part_kind) |part_kind| allocator.free(part_kind);
        if (self.agent_id) |agent_id| allocator.free(agent_id);
        if (self.title) |title| allocator.free(title);
        if (self.reason) |reason| allocator.free(reason);
    }
};

pub fn publishToolCallEvent(
    allocator: std.mem.Allocator,
    event_bus: ?framework.EventBus,
    event: ToolCallEvent,
) !void {
    const bus = event_bus orelse return;
    const payload = try encodeJsonObject(allocator, &.{
        .{ .key = "callId", .value = event.call_id },
        .{ .key = "toolName", .value = event.tool_name },
        .{ .key = "inputJson", .value = event.input_json },
        .{ .key = "requestId", .value = event.request_id },
        .{ .key = "sessionId", .value = event.session_id },
        .{ .key = "traceId", .value = event.trace_id },
    });
    defer allocator.free(payload);
    _ = try bus.publish(TOOL_CALL_EVENT_TOPIC, payload);
}

pub fn publishSessionCreatedEvent(
    allocator: std.mem.Allocator,
    event_bus: ?framework.EventBus,
    event: SessionCreatedEvent,
) !void {
    const bus = event_bus orelse return;
    const payload = try encodeJsonObject(allocator, &.{
        .{ .key = "sessionId", .value = event.session_id },
        .{ .key = "agentId", .value = event.agent_id },
        .{ .key = "title", .value = event.title },
    });
    defer allocator.free(payload);
    _ = try bus.publish(SESSION_CREATED_EVENT_TOPIC, payload);
}

pub fn publishSessionUpdatedEvent(
    allocator: std.mem.Allocator,
    event_bus: ?framework.EventBus,
    event: SessionUpdatedEvent,
) !void {
    const bus = event_bus orelse return;
    const payload = try encodeJsonObject(allocator, &.{
        .{ .key = "sessionId", .value = event.session_id },
        .{ .key = "reason", .value = event.reason },
    });
    defer allocator.free(payload);
    _ = try bus.publish(SESSION_UPDATED_EVENT_TOPIC, payload);
}

pub fn publishSessionMessageCreatedEvent(
    allocator: std.mem.Allocator,
    event_bus: ?framework.EventBus,
    event: SessionMessageCreatedEvent,
) !void {
    const bus = event_bus orelse return;
    const payload = try encodeJsonObject(allocator, &.{
        .{ .key = "sessionId", .value = event.session_id },
        .{ .key = "messageId", .value = event.message_id },
        .{ .key = "role", .value = event.role },
    });
    defer allocator.free(payload);
    _ = try bus.publish(SESSION_MESSAGE_CREATED_EVENT_TOPIC, payload);
}

pub fn publishSessionPartAppendedEvent(
    allocator: std.mem.Allocator,
    event_bus: ?framework.EventBus,
    event: SessionPartAppendedEvent,
) !void {
    const bus = event_bus orelse return;
    const payload = try encodeJsonObject(allocator, &.{
        .{ .key = "sessionId", .value = event.session_id },
        .{ .key = "messageId", .value = event.message_id },
        .{ .key = "partId", .value = event.part_id },
        .{ .key = "partKind", .value = event.part_kind },
    });
    defer allocator.free(payload);
    _ = try bus.publish(SESSION_PART_APPENDED_EVENT_TOPIC, payload);
}

pub fn publishSessionStatusEvent(
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    event: SessionStatusEvent,
) !void {
    const payload = try encodeJsonObject(allocator, &.{
        .{ .key = "sessionId", .value = event.session_id },
        .{ .key = "status", .value = event.status },
        .{ .key = "requestId", .value = event.request_id },
    });
    defer allocator.free(payload);
    _ = try event_bus.publish(SESSION_STATUS_EVENT_TOPIC, payload);
}

pub fn publishToolResultEvent(
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    event: ToolResultEvent,
) !void {
    const payload = try encodeToolResultPayload(allocator, event);
    defer allocator.free(payload);
    _ = try event_bus.publish(if (event.ok) TOOL_RESULT_COMPLETED_EVENT_TOPIC else TOOL_RESULT_FAILED_EVENT_TOPIC, payload);
}

pub fn publishProviderResponseEvent(
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    event: ProviderResponseEvent,
) !void {
    const payload = try encodeJsonObject(allocator, &.{
        .{ .key = "requestId", .value = event.request_id },
        .{ .key = "sessionId", .value = event.session_id },
        .{ .key = "traceId", .value = event.trace_id },
    });
    defer allocator.free(payload);
    _ = try event_bus.publish(event.topic, payload);
}

pub fn subscribeToolCallEvents(event_bus: framework.EventBus, after_seq: u64) !u64 {
    return event_bus.subscribe(&.{TOOL_CALL_EVENT_TOPIC}, after_seq);
}

pub fn subscribeSessionTimelineEvents(event_bus: framework.EventBus, after_seq: u64) !u64 {
    return event_bus.subscribe(&.{"session."}, after_seq);
}

pub fn subscribeToolResultEvents(event_bus: framework.EventBus, after_seq: u64) !u64 {
    return event_bus.subscribe(&.{ "tool.result." }, after_seq);
}

pub fn subscribeSessionStatusEvents(event_bus: framework.EventBus, after_seq: u64) !u64 {
    return event_bus.subscribe(&.{SESSION_STATUS_EVENT_TOPIC}, after_seq);
}

pub fn pollToolCallEvents(
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    subscription_id: u64,
    limit: usize,
) ![]ToolCallEvent {
    var batch = try event_bus.pollSubscription(allocator, subscription_id, limit);
    defer batch.deinit(allocator);

    const results = try allocator.alloc(ToolCallEvent, batch.events.len);
    errdefer allocator.free(results);

    for (batch.events, 0..) |runtime_event, index| {
        const parsed = try std.json.parseFromSlice(ToolCallEventJson, allocator, runtime_event.payload_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        results[index] = .{
            .call_id = try allocator.dupe(u8, parsed.value.callId),
            .tool_name = try allocator.dupe(u8, parsed.value.toolName),
            .input_json = try allocator.dupe(u8, parsed.value.inputJson),
            .request_id = if (parsed.value.requestId) |request_id| try allocator.dupe(u8, request_id) else null,
            .session_id = if (parsed.value.sessionId) |session_id| try allocator.dupe(u8, session_id) else null,
            .trace_id = if (parsed.value.traceId) |trace_id| try allocator.dupe(u8, trace_id) else null,
        };
    }

    return results;
}

pub fn pollSessionTimelineEvents(
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    subscription_id: u64,
    limit: usize,
) ![]SessionTimelineEvent {
    var batch = try event_bus.pollSubscription(allocator, subscription_id, limit);
    defer batch.deinit(allocator);

    const results = try allocator.alloc(SessionTimelineEvent, batch.events.len);
    errdefer allocator.free(results);

    for (batch.events, 0..) |runtime_event, index| {
        const parsed = try std.json.parseFromSlice(SessionTimelineEventJson, allocator, runtime_event.payload_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        results[index] = .{
            .topic = try allocator.dupe(u8, runtime_event.topic),
            .session_id = try allocator.dupe(u8, parsed.value.sessionId),
            .message_id = if (parsed.value.messageId) |message_id| try allocator.dupe(u8, message_id) else null,
            .part_id = if (parsed.value.partId) |part_id| try allocator.dupe(u8, part_id) else null,
            .role = if (parsed.value.role) |role| try allocator.dupe(u8, role) else null,
            .part_kind = if (parsed.value.partKind) |part_kind| try allocator.dupe(u8, part_kind) else null,
            .agent_id = if (parsed.value.agentId) |agent_id| try allocator.dupe(u8, agent_id) else null,
            .title = if (parsed.value.title) |title| try allocator.dupe(u8, title) else null,
            .reason = if (parsed.value.reason) |reason| try allocator.dupe(u8, reason) else null,
        };
    }

    return results;
}

pub fn pollToolResultEvents(
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    subscription_id: u64,
    limit: usize,
) ![]ToolResultEvent {
    var batch = try event_bus.pollSubscription(allocator, subscription_id, limit);
    defer batch.deinit(allocator);

    const results = try allocator.alloc(ToolResultEvent, batch.events.len);
    errdefer allocator.free(results);

    for (batch.events, 0..) |runtime_event, index| {
        const parsed = try std.json.parseFromSlice(ToolResultEventJson, allocator, runtime_event.payload_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        results[index] = .{
            .request_id = try allocator.dupe(u8, parsed.value.requestId),
            .session_id = try allocator.dupe(u8, parsed.value.sessionId),
            .trace_id = if (parsed.value.traceId) |trace_id| try allocator.dupe(u8, trace_id) else null,
            .call_id = try allocator.dupe(u8, parsed.value.callId),
            .tool_name = try allocator.dupe(u8, parsed.value.toolName),
            .output_text = try allocator.dupe(u8, parsed.value.outputText),
            .metadata_json = try allocator.dupe(u8, parsed.value.metadataJson),
            .ok = parsed.value.ok,
            .error_code = if (parsed.value.errorCode) |error_code| try allocator.dupe(u8, error_code) else null,
        };
    }

    return results;
}

pub fn pollSessionStatusEvents(
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    subscription_id: u64,
    limit: usize,
) ![]SessionStatusEvent {
    var batch = try event_bus.pollSubscription(allocator, subscription_id, limit);
    defer batch.deinit(allocator);

    const results = try allocator.alloc(SessionStatusEvent, batch.events.len);
    errdefer allocator.free(results);

    for (batch.events, 0..) |runtime_event, index| {
        const parsed = try std.json.parseFromSlice(SessionStatusEventJson, allocator, runtime_event.payload_json, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        results[index] = .{
            .session_id = try allocator.dupe(u8, parsed.value.sessionId),
            .status = try allocator.dupe(u8, parsed.value.status),
            .request_id = try allocator.dupe(u8, parsed.value.requestId),
        };
    }

    return results;
}

const JsonField = struct {
    key: []const u8,
    value: ?[]const u8,
};

const ToolCallEventJson = struct {
    callId: []const u8,
    toolName: []const u8,
    inputJson: []const u8,
    requestId: ?[]const u8 = null,
    sessionId: ?[]const u8 = null,
    traceId: ?[]const u8 = null,
};

const ToolResultEventJson = struct {
    requestId: []const u8,
    sessionId: []const u8,
    traceId: ?[]const u8 = null,
    callId: []const u8,
    toolName: []const u8,
    outputText: []const u8,
    metadataJson: []const u8,
    ok: bool,
    errorCode: ?[]const u8 = null,
};

const SessionTimelineEventJson = struct {
    sessionId: []const u8,
    messageId: ?[]const u8 = null,
    partId: ?[]const u8 = null,
    role: ?[]const u8 = null,
    partKind: ?[]const u8 = null,
    agentId: ?[]const u8 = null,
    title: ?[]const u8 = null,
    reason: ?[]const u8 = null,
};

const SessionStatusEventJson = struct {
    sessionId: []const u8,
    status: []const u8,
    requestId: []const u8,
};

fn encodeJsonObject(allocator: std.mem.Allocator, fields: []const JsonField) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    const writer = list.writer(allocator);
    try writer.writeByte('{');
    var first = true;
    for (fields) |field| {
        if (field.value) |value| {
            try appendJsonStringField(writer, field.key, value, &first);
        }
    }
    try writer.writeByte('}');
    return allocator.dupe(u8, list.items);
}

fn encodeToolResultPayload(allocator: std.mem.Allocator, event: ToolResultEvent) ![]u8 {
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(allocator);

    const writer = list.writer(allocator);
    try writer.writeByte('{');
    var first = true;
    try appendJsonStringField(writer, "requestId", event.request_id, &first);
    try appendJsonStringField(writer, "sessionId", event.session_id, &first);
    try appendJsonStringField(writer, "callId", event.call_id, &first);
    try appendJsonStringField(writer, "toolName", event.tool_name, &first);
    try appendJsonStringField(writer, "outputText", event.output_text, &first);
    try appendJsonStringField(writer, "metadataJson", event.metadata_json, &first);
    if (event.trace_id) |trace_id| try appendJsonStringField(writer, "traceId", trace_id, &first);
    if (event.error_code) |error_code| try appendJsonStringField(writer, "errorCode", error_code, &first);
    if (!first) try writer.writeByte(',');
    try writeJsonString(writer, "ok");
    try writer.writeByte(':');
    try writer.writeAll(if (event.ok) "true" else "false");
    try writer.writeByte('}');

    return allocator.dupe(u8, list.items);
}

fn appendJsonStringField(writer: anytype, key: []const u8, value: []const u8, first: *bool) !void {
    if (!first.*) try writer.writeByte(',');
    first.* = false;
    try writeJsonString(writer, key);
    try writer.writeByte(':');
    try writeJsonString(writer, value);
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

test "tool call events can be published and polled via event bus" {
    var bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();

    const sub = try subscribeToolCallEvents(bus.asEventBus(), 0);

    try publishToolCallEvent(std.testing.allocator, bus.asEventBus(), .{
        .request_id = "req_01",
        .session_id = "session_01",
        .call_id = "call_01",
        .tool_name = "read_file",
        .input_json = "{\"path\":\"src/main.zig\"}",
    });

    const events = try pollToolCallEvents(std.testing.allocator, bus.asEventBus(), sub, 10);
    defer {
        for (events) |event| {
            std.testing.allocator.free(event.call_id);
            std.testing.allocator.free(event.tool_name);
            std.testing.allocator.free(event.input_json);
            if (event.request_id) |request_id| std.testing.allocator.free(request_id);
            if (event.session_id) |session_id| std.testing.allocator.free(session_id);
            if (event.trace_id) |trace_id| std.testing.allocator.free(trace_id);
        }
        std.testing.allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("read_file", events[0].tool_name);
}

test "session timeline events can be published and observed" {
    var bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();

    const sub = try subscribeSessionTimelineEvents(bus.asEventBus(), 0);

    try publishSessionMessageCreatedEvent(std.testing.allocator, bus.asEventBus(), .{
        .session_id = "session_01",
        .message_id = "message_01",
        .role = "assistant",
    });
    try publishSessionPartAppendedEvent(std.testing.allocator, bus.asEventBus(), .{
        .session_id = "session_01",
        .message_id = "message_01",
        .part_id = "part_01",
        .part_kind = "tool_result",
    });

    const events = try pollSessionTimelineEvents(std.testing.allocator, bus.asEventBus(), sub, 10);
    defer {
        for (events) |*event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings(SESSION_MESSAGE_CREATED_EVENT_TOPIC, events[0].topic);
    try std.testing.expectEqualStrings("tool_result", events[1].part_kind.?);
}

test "session status events can be published and polled via event bus" {
    var bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer bus.deinit();

    const sub = try subscribeSessionStatusEvents(bus.asEventBus(), 0);
    try publishSessionStatusEvent(std.testing.allocator, bus.asEventBus(), .{
        .session_id = "session_01",
        .status = "completed",
        .request_id = "req_01",
    });

    const events = try pollSessionStatusEvents(std.testing.allocator, bus.asEventBus(), sub, 10);
    defer {
        for (events) |*event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("completed", events[0].status);
}
