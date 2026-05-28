const std = @import("std");
const schema = @import("schema.zig");
const message_model = @import("message.zig");
const part_model = @import("part.zig");
const store_model = @import("store.zig");

pub const MessageWithParts = struct {
    info: message_model.MessageInfo,
    parts: []part_model.MessagePart,

    pub fn deinit(self: *MessageWithParts, allocator: std.mem.Allocator) void {
        self.info.deinit(allocator);
        for (self.parts) |*part| part.deinit(allocator);
        allocator.free(self.parts);
    }
};

pub const ConversationPart = union(enum) {
    text: []const u8,
    reasoning: []const u8,
    tool_call: ToolCallView,
    tool_result: ToolResultView,
    system_reminder: []const u8,
    compaction_summary: CompactionSummaryView,
    subtask: SubtaskView,
    subtask_aggregate: SubtaskAggregateView,

    pub fn deinit(self: *ConversationPart, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |value| allocator.free(value),
            .reasoning => |value| allocator.free(value),
            .tool_call => |*value| value.deinit(allocator),
            .tool_result => |*value| value.deinit(allocator),
            .system_reminder => |value| allocator.free(value),
            .compaction_summary => |*value| value.deinit(allocator),
            .subtask => |*value| value.deinit(allocator),
            .subtask_aggregate => |*value| value.deinit(allocator),
        }
    }
};

pub const CompactionSummaryView = struct {
    compacted_until_message_id: []const u8,
    original_message_count: u32,
    summary: []const u8,

    pub fn deinit(self: *CompactionSummaryView, allocator: std.mem.Allocator) void {
        allocator.free(self.compacted_until_message_id);
        allocator.free(self.summary);
    }
};

pub const ToolCallView = struct {
    call_id: []const u8,
    tool_name: []const u8,
    input_json: []const u8,

    pub fn deinit(self: *ToolCallView, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.tool_name);
        allocator.free(self.input_json);
    }
};

pub const ToolResultView = struct {
    call_id: []const u8,
    tool_name: []const u8,
    output_text: []const u8,
    metadata_json: []const u8,

    pub fn deinit(self: *ToolResultView, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        allocator.free(self.tool_name);
        allocator.free(self.output_text);
        allocator.free(self.metadata_json);
    }
};

pub const SubtaskView = struct {
    child_session_id: []const u8,
    agent_id: []const u8,
    status: []const u8,
    summary: []const u8,

    pub fn deinit(self: *SubtaskView, allocator: std.mem.Allocator) void {
        allocator.free(self.child_session_id);
        allocator.free(self.agent_id);
        allocator.free(self.status);
        allocator.free(self.summary);
    }
};

pub const SubtaskAggregateView = struct {
    batch_id: []const u8,
    summary: []const u8,
    success_count: u32,
    failure_count: u32,
    child_results_json: []const u8,

    pub fn deinit(self: *SubtaskAggregateView, allocator: std.mem.Allocator) void {
        allocator.free(self.batch_id);
        allocator.free(self.summary);
        allocator.free(self.child_results_json);
    }
};

pub const ConversationMessage = struct {
    role: message_model.MessageRole,
    message_id: schema.MessageId,
    parts: []ConversationPart,

    pub fn deinit(self: *ConversationMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.message_id);
        for (self.parts) |*part| part.deinit(allocator);
        allocator.free(self.parts);
    }
};

pub const HistoryService = struct {
    store: store_model.SessionStore,

    pub fn init(store: store_model.SessionStore) HistoryService {
        return .{ .store = store };
    }

    pub fn list(self: HistoryService, allocator: std.mem.Allocator, session_id: schema.SessionId) ![]MessageWithParts {
        var timeline = try self.store.listTimeline(allocator, session_id);
        defer timeline.deinit(allocator);

        const hydrated = try allocator.alloc(MessageWithParts, timeline.messages.len);
        errdefer allocator.free(hydrated);

        for (timeline.messages, 0..) |message, index| {
            var count: usize = 0;
            for (timeline.parts) |part_record| {
                if (std.mem.eql(u8, part_record.message_id, message.id)) {
                    count += 1;
                }
            }

            hydrated[index] = .{
                .info = try message.clone(allocator),
                .parts = try allocator.alloc(part_model.MessagePart, count),
            };
            errdefer hydrated[index].deinit(allocator);

            var write_index: usize = 0;
            for (timeline.parts) |part_record| {
                if (!std.mem.eql(u8, part_record.message_id, message.id)) continue;
                hydrated[index].parts[write_index] = try part_record.part.clone(allocator);
                write_index += 1;
            }
        }

        return hydrated;
    }

    pub fn renderConversation(
        self: HistoryService,
        allocator: std.mem.Allocator,
        session_id: schema.SessionId,
    ) ![]ConversationMessage {
        const hydrated = try self.list(allocator, session_id);
        defer {
            for (hydrated) |*item| item.deinit(allocator);
            allocator.free(hydrated);
        }

        const window = latestCompactionWindow(hydrated);
        var included_count: usize = 0;
        if (window.summary_index) |_| {
            included_count = 1;
            for (hydrated, 0..) |_, index| {
                if (shouldIncludeTailAfterCompaction(window, index)) included_count += 1;
            }
        } else {
            for (hydrated, 0..) |_, index| {
                if (shouldIncludeMessage(window, index)) included_count += 1;
            }
        }

        const rendered = try allocator.alloc(ConversationMessage, included_count);
        errdefer allocator.free(rendered);

        var out_index: usize = 0;
        if (window.summary_index) |summary_index| {
            rendered[out_index] = .{
                .role = hydrated[summary_index].info.role,
                .message_id = try allocator.dupe(u8, hydrated[summary_index].info.id),
                .parts = try allocator.alloc(ConversationPart, hydrated[summary_index].parts.len),
            };
            errdefer rendered[out_index].deinit(allocator);
            for (hydrated[summary_index].parts, 0..) |part, part_index| {
                rendered[out_index].parts[part_index] = try renderConversationPart(allocator, part);
            }
            out_index += 1;
        }

        for (hydrated, 0..) |message, index| {
            if (window.summary_index != null) {
                if (!shouldIncludeTailAfterCompaction(window, index)) continue;
            } else if (!shouldIncludeMessage(window, index)) {
                continue;
            }
            rendered[out_index] = .{
                .role = message.info.role,
                .message_id = try allocator.dupe(u8, message.info.id),
                .parts = try allocator.alloc(ConversationPart, message.parts.len),
            };
            errdefer rendered[out_index].deinit(allocator);

            for (message.parts, 0..) |part, part_index| {
                rendered[out_index].parts[part_index] = try renderConversationPart(allocator, part);
            }
            out_index += 1;
        }

        return rendered;
    }
};

const CompactionWindow = struct {
    summary_index: ?usize = null,
    cutoff_index: ?usize = null,
};

fn latestCompactionWindow(messages: []const MessageWithParts) CompactionWindow {
    var latest_summary_index: ?usize = null;
    var cutoff_message_id: ?[]const u8 = null;
    for (messages, 0..) |message, index| {
        for (message.parts) |part| {
            if (part == .compaction_summary) {
                latest_summary_index = index;
                cutoff_message_id = part.compaction_summary.compacted_until_message_id;
            }
        }
    }
    if (latest_summary_index == null or cutoff_message_id == null) return .{};

    var cutoff_index: ?usize = null;
    for (messages, 0..) |message, index| {
        if (std.mem.eql(u8, message.info.id, cutoff_message_id.?)) {
            cutoff_index = index;
            break;
        }
    }
    return .{
        .summary_index = latest_summary_index,
        .cutoff_index = cutoff_index,
    };
}

fn shouldIncludeMessage(window: CompactionWindow, index: usize) bool {
    if (window.summary_index == null or window.cutoff_index == null) return true;
    if (index == window.summary_index.?) return true;
    return index > window.cutoff_index.?;
}

fn shouldIncludeTailAfterCompaction(window: CompactionWindow, index: usize) bool {
    if (window.summary_index == null or window.cutoff_index == null) return false;
    if (index == window.summary_index.?) return false;
    return index > window.cutoff_index.?;
}

fn renderConversationPart(allocator: std.mem.Allocator, part: part_model.MessagePart) !ConversationPart {
    return switch (part) {
        .text => |value| .{ .text = try allocator.dupe(u8, value.text) },
        .reasoning => |value| .{ .reasoning = try allocator.dupe(u8, value.text) },
        .tool_call => |value| .{ .tool_call = .{
            .call_id = try allocator.dupe(u8, value.call_id),
            .tool_name = try allocator.dupe(u8, value.tool_name),
            .input_json = try allocator.dupe(u8, value.input_json),
        } },
        .tool_result => |value| .{ .tool_result = .{
            .call_id = try allocator.dupe(u8, value.call_id),
            .tool_name = try allocator.dupe(u8, value.tool_name),
            .output_text = try allocator.dupe(u8, value.output_text),
            .metadata_json = try allocator.dupe(u8, value.metadata_json),
        } },
        .system_reminder => |value| .{ .system_reminder = try allocator.dupe(u8, value.text) },
        .compaction_summary => |value| .{ .compaction_summary = .{
            .compacted_until_message_id = try allocator.dupe(u8, value.compacted_until_message_id),
            .original_message_count = value.original_message_count,
            .summary = try allocator.dupe(u8, value.summary),
        } },
        .subtask => |value| .{ .subtask = .{
            .child_session_id = try allocator.dupe(u8, value.child_session_id),
            .agent_id = try allocator.dupe(u8, value.agent_id),
            .status = try allocator.dupe(u8, value.status),
            .summary = try allocator.dupe(u8, value.summary),
        } },
        .subtask_aggregate => |value| .{ .subtask_aggregate = .{
            .batch_id = try allocator.dupe(u8, value.batch_id),
            .summary = try allocator.dupe(u8, value.summary),
            .success_count = value.success_count,
            .failure_count = value.failure_count,
            .child_results_json = try allocator.dupe(u8, value.child_results_json),
        } },
    };
}

test "history service hydrates timeline and preserves structured render output" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try std.testing.allocator.dupe(u8, ".");
    defer std.testing.allocator.free(root_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sessions" });
    defer std.testing.allocator.free(store_path);

    var store = try store_model.FileSessionStore.init(std.testing.allocator, store_path, null, null);
    defer store.deinit();

    var session = try store.createSession(std.testing.allocator, .{
        .title = "History",
        .agent_id = "build",
    });
    defer session.deinit(std.testing.allocator);

    var message = try store.appendMessage(std.testing.allocator, .{
        .session_id = session.id,
        .role = .assistant,
        .completed = true,
    });
    defer message.deinit(std.testing.allocator);

    var text_part = try part_model.text(std.testing.allocator, "hello");
    defer text_part.deinit(std.testing.allocator);
    var tool_part = try part_model.toolCall(std.testing.allocator, "call_01", "read_file", "{\"path\":\"src/main.zig\"}");
    defer tool_part.deinit(std.testing.allocator);
    var aggregate_part = try part_model.subtaskAggregate(std.testing.allocator, "batch_01", "all done", 1, 0, "[]");
    defer aggregate_part.deinit(std.testing.allocator);

    var stored_text = try store.appendPart(std.testing.allocator, .{
        .session_id = session.id,
        .message_id = message.id,
        .part = text_part,
    });
    defer stored_text.deinit(std.testing.allocator);

    var stored_tool = try store.appendPart(std.testing.allocator, .{
        .session_id = session.id,
        .message_id = message.id,
        .part = tool_part,
    });
    defer stored_tool.deinit(std.testing.allocator);

    var stored_aggregate = try store.appendPart(std.testing.allocator, .{
        .session_id = session.id,
        .message_id = message.id,
        .part = aggregate_part,
    });
    defer stored_aggregate.deinit(std.testing.allocator);

    const history = HistoryService.init(store.asSessionStore());
    const hydrated = try history.list(std.testing.allocator, session.id);
    defer {
        for (hydrated) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(hydrated);
    }

    try std.testing.expectEqual(@as(usize, 1), hydrated.len);
    try std.testing.expectEqual(@as(usize, 3), hydrated[0].parts.len);

    const rendered = try history.renderConversation(std.testing.allocator, session.id);
    defer {
        for (rendered) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(rendered);
    }

    try std.testing.expectEqual(@as(usize, 1), rendered.len);
    try std.testing.expectEqual(@as(usize, 3), rendered[0].parts.len);
    try std.testing.expectEqualStrings("read_file", rendered[0].parts[1].tool_call.tool_name);
    try std.testing.expectEqualStrings("batch_01", rendered[0].parts[2].subtask_aggregate.batch_id);
}
