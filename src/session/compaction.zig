const std = @import("std");
const history_model = @import("history.zig");
const message_model = @import("message.zig");
const part_model = @import("part.zig");
const schema = @import("schema.zig");
const store_model = @import("store.zig");

pub const CompactionCheckRequest = struct {
    session_id: ?schema.SessionId = null,
    message_count: usize = 0,
};

pub const CompactionCheck = struct {
    required: bool = false,
    reason: []const u8,

    pub fn clone(self: CompactionCheck, allocator: std.mem.Allocator) !CompactionCheck {
        return .{
            .required = self.required,
            .reason = try allocator.dupe(u8, self.reason),
        };
    }

    pub fn deinit(self: *CompactionCheck, allocator: std.mem.Allocator) void {
        allocator.free(self.reason);
    }
};

pub const CompactionResult = struct {
    compacted: bool,
    summary_message_id: ?schema.MessageId = null,

    pub fn deinit(self: *CompactionResult, allocator: std.mem.Allocator) void {
        if (self.summary_message_id) |value| allocator.free(value);
    }
};

pub const CompactionPolicy = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        check: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: CompactionCheckRequest) anyerror!CompactionCheck,
        preserve_recent_messages: *const fn (ptr: *anyopaque) usize,
    };

    pub fn check(self: CompactionPolicy, allocator: std.mem.Allocator, request: CompactionCheckRequest) anyerror!CompactionCheck {
        return self.vtable.check(self.ptr, allocator, request);
    }

    pub fn preserveRecentMessages(self: CompactionPolicy) usize {
        return self.vtable.preserve_recent_messages(self.ptr);
    }
};

pub const DisabledCompactionPolicy = struct {
    const Self = @This();

    const vtable = CompactionPolicy.VTable{
        .check = checkErased,
        .preserve_recent_messages = preserveRecentMessagesErased,
    };

    pub fn asPolicy(self: *Self) CompactionPolicy {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn check(_: *Self, allocator: std.mem.Allocator, _: CompactionCheckRequest) !CompactionCheck {
        return .{
            .required = false,
            .reason = try allocator.dupe(u8, "disabled"),
        };
    }

    pub fn preserveRecentMessages(_: *Self) usize {
        return 0;
    }

    fn checkErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: CompactionCheckRequest) anyerror!CompactionCheck {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.check(allocator, request);
    }

    fn preserveRecentMessagesErased(ptr: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.preserveRecentMessages();
    }
};

pub const MessageCountCompactionPolicy = struct {
    threshold: usize,
    preserve_recent_messages: usize,

    const Self = @This();

    const vtable = CompactionPolicy.VTable{
        .check = checkErased,
        .preserve_recent_messages = preserveRecentMessagesErased,
    };

    pub fn asPolicy(self: *Self) CompactionPolicy {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn check(self: *Self, allocator: std.mem.Allocator, request: CompactionCheckRequest) !CompactionCheck {
        if (request.message_count > self.threshold) {
            return .{
                .required = true,
                .reason = try std.fmt.allocPrint(allocator, "message_count>{d}", .{self.threshold}),
            };
        }
        return .{
            .required = false,
            .reason = try allocator.dupe(u8, "below_threshold"),
        };
    }

    pub fn preserveRecentMessages(self: *Self) usize {
        return self.preserve_recent_messages;
    }

    fn checkErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: CompactionCheckRequest) anyerror!CompactionCheck {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.check(allocator, request);
    }

    fn preserveRecentMessagesErased(ptr: *anyopaque) usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.preserveRecentMessages();
    }
};

pub fn compactSession(
    allocator: std.mem.Allocator,
    store: store_model.SessionStore,
    history_service: history_model.HistoryService,
    session_id: schema.SessionId,
    policy: CompactionPolicy,
) !CompactionResult {
    const history = try history_service.list(allocator, session_id);
    defer {
        for (history) |*item| item.deinit(allocator);
        allocator.free(history);
    }

    const start_index = latestSummaryIndex(history);
    const active_count = history.len - start_index;
    var check = try policy.check(allocator, .{
        .session_id = session_id,
        .message_count = active_count,
    });
    defer check.deinit(allocator);
    if (!check.required) return .{ .compacted = false };

    const preserve = policy.preserveRecentMessages();
    if (active_count <= preserve or active_count <= 1) return .{ .compacted = false };

    const summary_end_index = history.len - preserve - 1;
    if (summary_end_index < start_index) return .{ .compacted = false };

    const summary_text = try buildSummaryText(allocator, history[start_index .. summary_end_index + 1]);
    defer allocator.free(summary_text);

    const cutoff_message_id = history[summary_end_index].info.id;
    var message = try store.appendMessage(allocator, .{
        .session_id = session_id,
        .role = .assistant,
        .agent_id = "system",
        .completed = true,
    });
    defer message.deinit(allocator);
    errdefer message.deinit(allocator);

    var part = try part_model.compactionSummary(
        allocator,
        cutoff_message_id,
        @intCast(summary_end_index + 1 - start_index),
        summary_text,
    );
    defer part.deinit(allocator);
    var appended = try store.appendPart(allocator, .{
        .session_id = session_id,
        .message_id = message.id,
        .part = part,
    });
    appended.deinit(allocator);

    return .{
        .compacted = true,
        .summary_message_id = try allocator.dupe(u8, message.id),
    };
}

fn latestSummaryIndex(history: []const history_model.MessageWithParts) usize {
    var latest: ?usize = null;
    for (history, 0..) |message, index| {
        for (message.parts) |part| {
            if (part == .compaction_summary) latest = index + 1;
        }
    }
    return latest orelse 0;
}

fn buildSummaryText(allocator: std.mem.Allocator, items: []const history_model.MessageWithParts) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    {
        const msg = try std.fmt.allocPrint(allocator, "Compacted {d} earlier message(s):", .{items.len});
        defer allocator.free(msg);
        try out.appendSlice(allocator, msg);
    }
    for (items) |message| {
        try out.appendSlice(allocator, "\n- ");
        try out.appendSlice(allocator, message.info.role.asText());
        try out.appendSlice(allocator, ": ");
        var wrote_any = false;
        for (message.parts) |part| {
            switch (part) {
                .text => |value| {
                    try writeTruncated(&out, allocator, value.text, 120);
                    wrote_any = true;
                },
                .reasoning => |value| {
                    try writeTruncated(&out, allocator, value.text, 120);
                    wrote_any = true;
                },
                .tool_call => |value| {
                    {
                        const msg = try std.fmt.allocPrint(allocator, "[tool_call {s}]", .{value.tool_name});
                        defer allocator.free(msg);
                        try out.appendSlice(allocator, msg);
                    }
                    wrote_any = true;
                },
                .tool_result => |value| {
                    {
                        const msg = try std.fmt.allocPrint(allocator, "[tool_result {s}]", .{value.tool_name});
                        defer allocator.free(msg);
                        try out.appendSlice(allocator, msg);
                    }
                    wrote_any = true;
                },
                .system_reminder => |value| {
                    try writeTruncated(&out, allocator, value.text, 120);
                    wrote_any = true;
                },
                .compaction_summary => |value| {
                    try writeTruncated(&out, allocator, value.summary, 120);
                    wrote_any = true;
                },
                .subtask => |value| {
                    try writeTruncated(&out, allocator, value.summary, 120);
                    wrote_any = true;
                },
                .subtask_aggregate => |value| {
                    try writeTruncated(&out, allocator, value.summary, 120);
                    wrote_any = true;
                },
            }
            if (wrote_any) break;
        }
        if (!wrote_any) try out.appendSlice(allocator, "(no content)");
    }

    return allocator.dupe(u8, out.items);
}

fn writeTruncated(out: anytype, allocator: std.mem.Allocator, text: []const u8, max_len: usize) !void {
    const slice = if (text.len > max_len) text[0..max_len] else text;
    try out.appendSlice(allocator, slice);
    if (text.len > max_len) try out.appendSlice(allocator, "...");
}

test "disabled compaction policy does not require compaction" {
    var policy = DisabledCompactionPolicy{};
    var check = try policy.asPolicy().check(std.testing.allocator, .{
        .session_id = "session_01",
        .message_count = 12,
    });
    defer check.deinit(std.testing.allocator);

    try std.testing.expect(!check.required);
    try std.testing.expectEqualStrings("disabled", check.reason);
}

test "long history compacts into summary and render path preserves tail context" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sessions" });
    defer std.testing.allocator.free(store_path);

    var store = try store_model.FileSessionStore.init(std.testing.allocator, store_path, null, null);
    defer store.deinit();
    const history = history_model.HistoryService.init(store.asSessionStore());

    var session = try store.createSession(std.testing.allocator, .{
        .title = "Compaction",
        .agent_id = "build",
    });
    defer session.deinit(std.testing.allocator);

    for (0..5) |index| {
        var message = try store.appendMessage(std.testing.allocator, .{
            .session_id = session.id,
            .role = if (index % 2 == 0) .user else .assistant,
            .completed = true,
        });
        defer message.deinit(std.testing.allocator);
        const text_value = try std.fmt.allocPrint(std.testing.allocator, "message-{d}", .{index});
        defer std.testing.allocator.free(text_value);
        var part = try part_model.text(std.testing.allocator, text_value);
        defer part.deinit(std.testing.allocator);
        var appended = try store.appendPart(std.testing.allocator, .{
            .session_id = session.id,
            .message_id = message.id,
            .part = part,
        });
        appended.deinit(std.testing.allocator);
    }

    var policy = MessageCountCompactionPolicy{ .threshold = 3, .preserve_recent_messages = 2 };
    var result = try compactSession(std.testing.allocator, store.asSessionStore(), history, session.id, policy.asPolicy());
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.compacted);

    const rendered = try history.renderConversation(std.testing.allocator, session.id);
    defer {
        for (rendered) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(rendered);
    }
    try std.testing.expectEqual(@as(usize, 3), rendered.len);
    try std.testing.expect(rendered[0].parts[0] == .compaction_summary);
}
