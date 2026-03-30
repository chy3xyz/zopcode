const std = @import("std");
const schema = @import("schema.zig");

pub const TextPart = struct {
    id: schema.PartId,
    text: []const u8,
};

pub const ReasoningPart = struct {
    id: schema.PartId,
    text: []const u8,
};

pub const ToolCallPart = struct {
    id: schema.PartId,
    call_id: []const u8,
    tool_name: []const u8,
    input_json: []const u8,
};

pub const ToolResultPart = struct {
    id: schema.PartId,
    call_id: []const u8,
    tool_name: []const u8,
    output_text: []const u8,
    metadata_json: []const u8 = "{}",
};

pub const SystemReminderPart = struct {
    id: schema.PartId,
    text: []const u8,
};

pub const CompactionSummaryPart = struct {
    id: schema.PartId,
    compacted_until_message_id: []const u8,
    original_message_count: u32,
    summary: []const u8,
};

pub const SubtaskPart = struct {
    id: schema.PartId,
    child_session_id: []const u8,
    agent_id: []const u8,
    status: []const u8,
    summary: []const u8,
};

pub const SubtaskAggregatePart = struct {
    id: schema.PartId,
    batch_id: []const u8,
    summary: []const u8,
    success_count: u32,
    failure_count: u32,
    child_results_json: []const u8,
};

pub const MessagePart = union(enum) {
    text: TextPart,
    reasoning: ReasoningPart,
    tool_call: ToolCallPart,
    tool_result: ToolResultPart,
    system_reminder: SystemReminderPart,
    compaction_summary: CompactionSummaryPart,
    subtask: SubtaskPart,
    subtask_aggregate: SubtaskAggregatePart,

    pub fn clone(self: MessagePart, allocator: std.mem.Allocator) !MessagePart {
        return switch (self) {
            .text => |value| .{ .text = .{
                .id = try allocator.dupe(u8, value.id),
                .text = try allocator.dupe(u8, value.text),
            } },
            .reasoning => |value| .{ .reasoning = .{
                .id = try allocator.dupe(u8, value.id),
                .text = try allocator.dupe(u8, value.text),
            } },
            .tool_call => |value| .{ .tool_call = .{
                .id = try allocator.dupe(u8, value.id),
                .call_id = try allocator.dupe(u8, value.call_id),
                .tool_name = try allocator.dupe(u8, value.tool_name),
                .input_json = try allocator.dupe(u8, value.input_json),
            } },
            .tool_result => |value| .{ .tool_result = .{
                .id = try allocator.dupe(u8, value.id),
                .call_id = try allocator.dupe(u8, value.call_id),
                .tool_name = try allocator.dupe(u8, value.tool_name),
                .output_text = try allocator.dupe(u8, value.output_text),
                .metadata_json = try allocator.dupe(u8, value.metadata_json),
            } },
            .system_reminder => |value| .{ .system_reminder = .{
                .id = try allocator.dupe(u8, value.id),
                .text = try allocator.dupe(u8, value.text),
            } },
            .compaction_summary => |value| .{ .compaction_summary = .{
                .id = try allocator.dupe(u8, value.id),
                .compacted_until_message_id = try allocator.dupe(u8, value.compacted_until_message_id),
                .original_message_count = value.original_message_count,
                .summary = try allocator.dupe(u8, value.summary),
            } },
            .subtask => |value| .{ .subtask = .{
                .id = try allocator.dupe(u8, value.id),
                .child_session_id = try allocator.dupe(u8, value.child_session_id),
                .agent_id = try allocator.dupe(u8, value.agent_id),
                .status = try allocator.dupe(u8, value.status),
                .summary = try allocator.dupe(u8, value.summary),
            } },
            .subtask_aggregate => |value| .{ .subtask_aggregate = .{
                .id = try allocator.dupe(u8, value.id),
                .batch_id = try allocator.dupe(u8, value.batch_id),
                .summary = try allocator.dupe(u8, value.summary),
                .success_count = value.success_count,
                .failure_count = value.failure_count,
                .child_results_json = try allocator.dupe(u8, value.child_results_json),
            } },
        };
    }

    pub fn deinit(self: *MessagePart, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |value| {
                allocator.free(value.id);
                allocator.free(value.text);
            },
            .reasoning => |value| {
                allocator.free(value.id);
                allocator.free(value.text);
            },
            .tool_call => |value| {
                allocator.free(value.id);
                allocator.free(value.call_id);
                allocator.free(value.tool_name);
                allocator.free(value.input_json);
            },
            .tool_result => |value| {
                allocator.free(value.id);
                allocator.free(value.call_id);
                allocator.free(value.tool_name);
                allocator.free(value.output_text);
                allocator.free(value.metadata_json);
            },
            .system_reminder => |value| {
                allocator.free(value.id);
                allocator.free(value.text);
            },
            .compaction_summary => |value| {
                allocator.free(value.id);
                allocator.free(value.compacted_until_message_id);
                allocator.free(value.summary);
            },
            .subtask => |value| {
                allocator.free(value.id);
                allocator.free(value.child_session_id);
                allocator.free(value.agent_id);
                allocator.free(value.status);
                allocator.free(value.summary);
            },
            .subtask_aggregate => |value| {
                allocator.free(value.id);
                allocator.free(value.batch_id);
                allocator.free(value.summary);
                allocator.free(value.child_results_json);
            },
        }
    }

    pub fn id(self: MessagePart) schema.PartId {
        return switch (self) {
            .text => |value| value.id,
            .reasoning => |value| value.id,
            .tool_call => |value| value.id,
            .tool_result => |value| value.id,
            .system_reminder => |value| value.id,
            .compaction_summary => |value| value.id,
            .subtask => |value| value.id,
            .subtask_aggregate => |value| value.id,
        };
    }

    pub fn kind(self: MessagePart) []const u8 {
        return switch (self) {
            .text => "text",
            .reasoning => "reasoning",
            .tool_call => "tool_call",
            .tool_result => "tool_result",
            .system_reminder => "system_reminder",
            .compaction_summary => "compaction_summary",
            .subtask => "subtask",
            .subtask_aggregate => "subtask_aggregate",
        };
    }
};

pub fn text(allocator: std.mem.Allocator, value: []const u8) !MessagePart {
    return .{ .text = .{
        .id = try schema.nextPartId(allocator),
        .text = try allocator.dupe(u8, value),
    } };
}

pub fn reasoning(allocator: std.mem.Allocator, value: []const u8) !MessagePart {
    return .{ .reasoning = .{
        .id = try schema.nextPartId(allocator),
        .text = try allocator.dupe(u8, value),
    } };
}

pub fn toolCall(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    tool_name: []const u8,
    input_json: []const u8,
) !MessagePart {
    return .{ .tool_call = .{
        .id = try schema.nextPartId(allocator),
        .call_id = try allocator.dupe(u8, call_id),
        .tool_name = try allocator.dupe(u8, tool_name),
        .input_json = try allocator.dupe(u8, input_json),
    } };
}

pub fn toolResult(
    allocator: std.mem.Allocator,
    call_id: []const u8,
    tool_name: []const u8,
    output_text: []const u8,
    metadata_json: []const u8,
) !MessagePart {
    return .{ .tool_result = .{
        .id = try schema.nextPartId(allocator),
        .call_id = try allocator.dupe(u8, call_id),
        .tool_name = try allocator.dupe(u8, tool_name),
        .output_text = try allocator.dupe(u8, output_text),
        .metadata_json = try allocator.dupe(u8, metadata_json),
    } };
}

pub fn compactionSummary(
    allocator: std.mem.Allocator,
    compacted_until_message_id: []const u8,
    original_message_count: u32,
    summary: []const u8,
) !MessagePart {
    return .{ .compaction_summary = .{
        .id = try schema.nextPartId(allocator),
        .compacted_until_message_id = try allocator.dupe(u8, compacted_until_message_id),
        .original_message_count = original_message_count,
        .summary = try allocator.dupe(u8, summary),
    } };
}

pub fn subtask(
    allocator: std.mem.Allocator,
    child_session_id: []const u8,
    agent_id: []const u8,
    status: []const u8,
    summary: []const u8,
) !MessagePart {
    return .{ .subtask = .{
        .id = try schema.nextPartId(allocator),
        .child_session_id = try allocator.dupe(u8, child_session_id),
        .agent_id = try allocator.dupe(u8, agent_id),
        .status = try allocator.dupe(u8, status),
        .summary = try allocator.dupe(u8, summary),
    } };
}

pub fn subtaskAggregate(
    allocator: std.mem.Allocator,
    batch_id: []const u8,
    summary: []const u8,
    success_count: u32,
    failure_count: u32,
    child_results_json: []const u8,
) !MessagePart {
    return .{ .subtask_aggregate = .{
        .id = try schema.nextPartId(allocator),
        .batch_id = try allocator.dupe(u8, batch_id),
        .summary = try allocator.dupe(u8, summary),
        .success_count = success_count,
        .failure_count = failure_count,
        .child_results_json = try allocator.dupe(u8, child_results_json),
    } };
}

test "message part reports stable kind and id" {
    var item = try text(std.testing.allocator, "hello");
    defer item.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("text", item.kind());
    try std.testing.expect(std.mem.startsWith(u8, item.id(), "part_"));
}
