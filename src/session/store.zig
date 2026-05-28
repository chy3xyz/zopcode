const std = @import("std");
const framework = @import("framework");
const schema = @import("schema.zig");
const session_model = @import("session.zig");
const message_model = @import("message.zig");
const part_model = @import("part.zig");
const session_events = @import("events.zig");

pub const SessionStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create_session: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: session_model.SessionCreateRequest) anyerror!session_model.SessionInfo,
        get_session: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: schema.SessionId) anyerror!?session_model.SessionInfo,
        list_sessions: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]session_model.SessionInfo,
        append_message: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: message_model.MessageAppendRequest) anyerror!message_model.MessageInfo,
        append_part: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: PartAppendRequest) anyerror!PartRecord,
        list_timeline: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: schema.SessionId) anyerror!TimelineRecords,
        update_message: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, message: message_model.MessageInfo) anyerror!void,
    };

    pub fn createSession(self: SessionStore, allocator: std.mem.Allocator, request: session_model.SessionCreateRequest) anyerror!session_model.SessionInfo {
        return self.vtable.create_session(self.ptr, allocator, request);
    }

    pub fn getSession(self: SessionStore, allocator: std.mem.Allocator, session_id: schema.SessionId) anyerror!?session_model.SessionInfo {
        return self.vtable.get_session(self.ptr, allocator, session_id);
    }

    pub fn listSessions(self: SessionStore, allocator: std.mem.Allocator) anyerror![]session_model.SessionInfo {
        return self.vtable.list_sessions(self.ptr, allocator);
    }

    pub fn appendMessage(self: SessionStore, allocator: std.mem.Allocator, request: message_model.MessageAppendRequest) anyerror!message_model.MessageInfo {
        return self.vtable.append_message(self.ptr, allocator, request);
    }

    pub fn appendPart(self: SessionStore, allocator: std.mem.Allocator, request: PartAppendRequest) anyerror!PartRecord {
        return self.vtable.append_part(self.ptr, allocator, request);
    }

    pub fn listTimeline(self: SessionStore, allocator: std.mem.Allocator, session_id: schema.SessionId) anyerror!TimelineRecords {
        return self.vtable.list_timeline(self.ptr, allocator, session_id);
    }

    pub fn updateMessage(self: SessionStore, allocator: std.mem.Allocator, message: message_model.MessageInfo) anyerror!void {
        return self.vtable.update_message(self.ptr, allocator, message);
    }
};

pub const PartAppendRequest = struct {
    session_id: schema.SessionId,
    message_id: schema.MessageId,
    part: part_model.MessagePart,
};

pub const PartRecord = struct {
    message_id: schema.MessageId,
    order_index: u64,
    part: part_model.MessagePart,

    pub fn clone(self: PartRecord, allocator: std.mem.Allocator) !PartRecord {
        return .{
            .message_id = try allocator.dupe(u8, self.message_id),
            .order_index = self.order_index,
            .part = try self.part.clone(allocator),
        };
    }

    pub fn deinit(self: *PartRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.message_id);
        self.part.deinit(allocator);
    }
};

pub const TimelineRecords = struct {
    messages: []message_model.MessageInfo,
    parts: []PartRecord,

    pub fn deinit(self: *TimelineRecords, allocator: std.mem.Allocator) void {
        for (self.messages) |*message| message.deinit(allocator);
        allocator.free(self.messages);

        for (self.parts) |*part| part.deinit(allocator);
        allocator.free(self.parts);
    }
};

pub const FileSessionStore = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,
    event_bus: ?framework.EventBus = null,
    logger: ?*framework.Logger = null,

    const Self = @This();

    const vtable = SessionStore.VTable{
        .create_session = createSessionErased,
        .get_session = getSessionErased,
        .list_sessions = listSessionsErased,
        .append_message = appendMessageErased,
        .append_part = appendPartErased,
        .list_timeline = listTimelineErased,
        .update_message = updateMessageErased,
    };

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8, event_bus: ?framework.EventBus, logger: ?*framework.Logger) !Self {
        _ = std.c.mkdir(@ptrCast(root_path.ptr), 0o755);
        return .{
            .allocator = allocator,
            .root_path = try allocator.dupe(u8, root_path),
            .event_bus = event_bus,
            .logger = logger,
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.root_path);
    }

    pub fn asSessionStore(self: *Self) SessionStore {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn createSession(self: *Self, allocator: std.mem.Allocator, request: session_model.SessionCreateRequest) !session_model.SessionInfo {
        var info = try session_model.initFromCreateRequest(allocator, request);
        errdefer info.deinit(allocator);

        const session_dir = try self.sessionDirPath(allocator, info.id);
        defer allocator.free(session_dir);
        _ = std.c.mkdir(@ptrCast(session_dir.ptr), 0o755);

        const session_path = try self.sessionPath(allocator, info.id);
        defer allocator.free(session_path);
        try writeJsonFile(self.allocator, session_path, sessionInfoToJson(info));

        const messages_path = try self.messagesPath(allocator, info.id);
        defer allocator.free(messages_path);
        const messages_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), messages_path, .{ .truncate = false });
        messages_file.close();

        const parts_path = try self.partsPath(allocator, info.id);
        defer allocator.free(parts_path);
        const parts_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), parts_path, .{ .truncate = false });
        parts_file.close();

        try session_events.publishSessionCreatedEvent(self.allocator, self.event_bus, .{
            .session_id = info.id,
            .agent_id = info.agent_id,
            .title = info.title,
        });
        self.logInfo("session created", &.{
            framework.LogField.string("session_id", info.id),
            framework.LogField.string("agent_id", info.agent_id),
            framework.LogField.string("store_path", self.root_path),
        });

        return info;
    }

    pub fn getSession(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) !?session_model.SessionInfo {
        const session_path = try self.sessionPath(allocator, session_id);
        defer allocator.free(session_path);

        const contents = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), session_path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(contents);

        const parsed = try std.json.parseFromSlice(SessionInfoJson, allocator, contents, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        return try sessionInfoFromJson(allocator, parsed.value);
    }

    pub fn listSessions(self: *Self, allocator: std.mem.Allocator) ![]session_model.SessionInfo {
        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.*.io(), self.root_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc(session_model.SessionInfo, 0),
            else => return err,
        };
        defer dir.close(std.Io.Threaded.global_single_threaded.*.io());

        var results: std.ArrayListUnmanaged(session_model.SessionInfo) = .empty;
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit(allocator);
        }

        var iterator = dir.iterate();
        while (try iterator.next(std.Io.Threaded.global_single_threaded.*.io())) |entry| {
            if (entry.kind != .directory) continue;

            const session_path = try std.fs.path.join(allocator, &.{ self.root_path, entry.name, session_file_name });
            defer allocator.free(session_path);

            const contents = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), session_path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer allocator.free(contents);

            const parsed = try std.json.parseFromSlice(SessionInfoJson, allocator, contents, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();

            try results.append(allocator, try sessionInfoFromJson(allocator, parsed.value));
        }

        return try results.toOwnedSlice(allocator);
    }

    pub fn appendMessage(self: *Self, allocator: std.mem.Allocator, request: message_model.MessageAppendRequest) !message_model.MessageInfo {
        var info = try message_model.initFromAppendRequest(allocator, request);
        errdefer info.deinit(allocator);

        const path = try self.messagesPath(allocator, request.session_id);
        defer allocator.free(path);
        try appendJsonLine(self.allocator, path, messageInfoToJson(info));
        try self.touchSession(allocator, request.session_id);

        try session_events.publishSessionMessageCreatedEvent(self.allocator, self.event_bus, .{
            .session_id = request.session_id,
            .message_id = info.id,
            .role = info.role.asText(),
        });
        self.logInfo("message appended", &.{
            framework.LogField.string("session_id", request.session_id),
            framework.LogField.string("message_id", info.id),
            framework.LogField.string("role", info.role.asText()),
        });

        return info;
    }

    pub fn appendPart(self: *Self, allocator: std.mem.Allocator, request: PartAppendRequest) !PartRecord {
        var record = PartRecord{
            .message_id = try allocator.dupe(u8, request.message_id),
            .order_index = try self.nextPartOrderIndex(allocator, request.session_id),
            .part = try request.part.clone(allocator),
        };
        errdefer record.deinit(allocator);

        const path = try self.partsPath(allocator, request.session_id);
        defer allocator.free(path);
        try appendJsonLine(self.allocator, path, partRecordToJson(record));
        try self.touchSession(allocator, request.session_id);

        try session_events.publishSessionPartAppendedEvent(self.allocator, self.event_bus, .{
            .session_id = request.session_id,
            .message_id = request.message_id,
            .part_id = record.part.id(),
            .part_kind = record.part.kind(),
        });
        self.logInfo("message part appended", &.{
            framework.LogField.string("session_id", request.session_id),
            framework.LogField.string("message_id", request.message_id),
            framework.LogField.string("part_id", record.part.id()),
            framework.LogField.string("part_kind", record.part.kind()),
        });

        return record;
    }

    pub fn listTimeline(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) !TimelineRecords {
        const messages_path = try self.messagesPath(allocator, session_id);
        defer allocator.free(messages_path);

        const parts_path = try self.partsPath(allocator, session_id);
        defer allocator.free(parts_path);

        return .{
            .messages = try self.readMessageRecords(allocator, messages_path),
            .parts = try self.readPartRecords(allocator, parts_path),
        };
    }

    pub fn updateMessage(self: *Self, allocator: std.mem.Allocator, updated: message_model.MessageInfo) !void {
        var timeline = try self.listTimeline(allocator, updated.session_id);
        defer timeline.deinit(allocator);

        var found = false;
        for (timeline.messages) |*message| {
            if (std.mem.eql(u8, message.id, updated.id)) {
                message.deinit(allocator);
                message.* = try updated.clone(allocator);
                found = true;
                break;
            }
        }
        if (!found) return error.MessageNotFound;

        const messages_path = try self.messagesPath(allocator, updated.session_id);
        defer allocator.free(messages_path);
        try writeMessagesFile(self.allocator, messages_path, timeline.messages);
        try self.touchSession(allocator, updated.session_id);

        try session_events.publishSessionUpdatedEvent(self.allocator, self.event_bus, .{
            .session_id = updated.session_id,
            .reason = "message_updated",
        });
        self.logInfo("message updated", &.{
            framework.LogField.string("session_id", updated.session_id),
            framework.LogField.string("message_id", updated.id),
            framework.LogField.boolean("completed", updated.completed),
            framework.LogField.string("reason", "message_updated"),
        });
    }

    fn touchSession(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) !void {
        var info = (try self.getSession(allocator, session_id)) orelse return error.SessionNotFound;
        defer info.deinit(allocator);
        info.updated_at_ms = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds();

        const session_path = try self.sessionPath(allocator, session_id);
        defer allocator.free(session_path);
        try writeJsonFile(self.allocator, session_path, sessionInfoToJson(info));

        try session_events.publishSessionUpdatedEvent(self.allocator, self.event_bus, .{
            .session_id = session_id,
            .reason = "timeline_mutation",
        });
        self.logInfo("session metadata touched", &.{
            framework.LogField.string("session_id", session_id),
            framework.LogField.string("reason", "timeline_mutation"),
        });
    }

    fn logInfo(self: *Self, message: []const u8, fields: []const framework.LogField) void {
        if (self.logger) |logger| {
            logger.child("session").child("store").info(message, fields);
        }
    }

    fn nextPartOrderIndex(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) !u64 {
        const path = try self.partsPath(allocator, session_id);
        defer allocator.free(path);

        const contents = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return 0,
            else => return err,
        };
        defer allocator.free(contents);

        var count: u64 = 0;
        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len != 0) count += 1;
        }
        return count;
    }

    fn readMessageRecords(self: *Self, allocator: std.mem.Allocator, path: []const u8) ![]message_model.MessageInfo {
        _ = self;
        const contents = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc(message_model.MessageInfo, 0),
            else => return err,
        };
        defer allocator.free(contents);

        var results: std.ArrayListUnmanaged(message_model.MessageInfo) = .empty;
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit(allocator);
        }

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            const parsed = try std.json.parseFromSlice(MessageInfoJson, allocator, line, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            try results.append(allocator, try messageInfoFromJson(allocator, parsed.value));
        }

        return try results.toOwnedSlice(allocator);
    }

    fn readPartRecords(self: *Self, allocator: std.mem.Allocator, path: []const u8) ![]PartRecord {
        _ = self;
        const contents = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc(PartRecord, 0),
            else => return err,
        };
        defer allocator.free(contents);

        var results: std.ArrayListUnmanaged(PartRecord) = .empty;
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit(allocator);
        }

        var lines = std.mem.splitScalar(u8, contents, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;

            const parsed = try std.json.parseFromSlice(PartRecordJson, allocator, line, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            try results.append(allocator, try partRecordFromJson(allocator, parsed.value));
        }

        return try results.toOwnedSlice(allocator);
    }

    fn sessionDirPath(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.root_path, session_id });
    }

    fn sessionPath(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.root_path, session_id, session_file_name });
    }

    fn messagesPath(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.root_path, session_id, messages_file_name });
    }

    fn partsPath(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.root_path, session_id, parts_file_name });
    }

    fn createSessionErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: session_model.SessionCreateRequest) anyerror!session_model.SessionInfo {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.createSession(allocator, request);
    }

    fn getSessionErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: schema.SessionId) anyerror!?session_model.SessionInfo {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.getSession(allocator, session_id);
    }

    fn listSessionsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]session_model.SessionInfo {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.listSessions(allocator);
    }

    fn appendMessageErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: message_model.MessageAppendRequest) anyerror!message_model.MessageInfo {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.appendMessage(allocator, request);
    }

    fn appendPartErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: PartAppendRequest) anyerror!PartRecord {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.appendPart(allocator, request);
    }

    fn listTimelineErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: schema.SessionId) anyerror!TimelineRecords {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.listTimeline(allocator, session_id);
    }

    fn updateMessageErased(ptr: *anyopaque, allocator: std.mem.Allocator, message: message_model.MessageInfo) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.updateMessage(allocator, message);
    }
};

const session_file_name = "session.json";
const messages_file_name = "messages.jsonl";
const parts_file_name = "parts.jsonl";
const max_file_bytes = 1024 * 1024;

const SessionInfoJson = struct {
    id: []const u8,
    title: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    parent_id: ?[]const u8 = null,
    agent_id: []const u8,
    archived: bool = false,
};

const MessageInfoJson = struct {
    id: []const u8,
    session_id: []const u8,
    role: message_model.MessageRole,
    created_at_ms: i64,
    parent_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    provider_id: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    completed: bool = false,
    error_code: ?[]const u8 = null,
};

const PartRecordJson = struct {
    message_id: []const u8,
    order_index: u64,
    kind: []const u8,
    id: []const u8,
    text: ?[]const u8 = null,
    compacted_until_message_id: ?[]const u8 = null,
    original_message_count: ?u32 = null,
    call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    input_json: ?[]const u8 = null,
    output_text: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
    child_session_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    batch_id: ?[]const u8 = null,
    success_count: ?u32 = null,
    failure_count: ?u32 = null,
    child_results_json: ?[]const u8 = null,
};

fn sessionInfoToJson(info: session_model.SessionInfo) SessionInfoJson {
    return .{
        .id = info.id,
        .title = info.title,
        .created_at_ms = info.created_at_ms,
        .updated_at_ms = info.updated_at_ms,
        .parent_id = info.parent_id,
        .agent_id = info.agent_id,
        .archived = info.archived,
    };
}

fn sessionInfoFromJson(allocator: std.mem.Allocator, value: SessionInfoJson) !session_model.SessionInfo {
    return .{
        .id = try allocator.dupe(u8, value.id),
        .title = try allocator.dupe(u8, value.title),
        .created_at_ms = value.created_at_ms,
        .updated_at_ms = value.updated_at_ms,
        .parent_id = if (value.parent_id) |parent_id| try allocator.dupe(u8, parent_id) else null,
        .agent_id = try allocator.dupe(u8, value.agent_id),
        .archived = value.archived,
    };
}

fn messageInfoToJson(info: message_model.MessageInfo) MessageInfoJson {
    return .{
        .id = info.id,
        .session_id = info.session_id,
        .role = info.role,
        .created_at_ms = info.created_at_ms,
        .parent_id = info.parent_id,
        .agent_id = info.agent_id,
        .provider_id = info.provider_id,
        .model_id = info.model_id,
        .completed = info.completed,
        .error_code = info.error_code,
    };
}

fn messageInfoFromJson(allocator: std.mem.Allocator, value: MessageInfoJson) !message_model.MessageInfo {
    return .{
        .id = try allocator.dupe(u8, value.id),
        .session_id = try allocator.dupe(u8, value.session_id),
        .role = value.role,
        .created_at_ms = value.created_at_ms,
        .parent_id = if (value.parent_id) |parent_id| try allocator.dupe(u8, parent_id) else null,
        .agent_id = if (value.agent_id) |agent_id| try allocator.dupe(u8, agent_id) else null,
        .provider_id = if (value.provider_id) |provider_id| try allocator.dupe(u8, provider_id) else null,
        .model_id = if (value.model_id) |model_id| try allocator.dupe(u8, model_id) else null,
        .completed = value.completed,
        .error_code = if (value.error_code) |error_code| try allocator.dupe(u8, error_code) else null,
    };
}

fn partRecordToJson(record: PartRecord) PartRecordJson {
    return switch (record.part) {
        .text => |part| .{ .message_id = record.message_id, .order_index = record.order_index, .kind = "text", .id = part.id, .text = part.text },
        .reasoning => |part| .{ .message_id = record.message_id, .order_index = record.order_index, .kind = "reasoning", .id = part.id, .text = part.text },
        .tool_call => |part| .{ .message_id = record.message_id, .order_index = record.order_index, .kind = "tool_call", .id = part.id, .call_id = part.call_id, .tool_name = part.tool_name, .input_json = part.input_json },
        .tool_result => |part| .{ .message_id = record.message_id, .order_index = record.order_index, .kind = "tool_result", .id = part.id, .call_id = part.call_id, .tool_name = part.tool_name, .output_text = part.output_text, .metadata_json = part.metadata_json },
        .system_reminder => |part| .{ .message_id = record.message_id, .order_index = record.order_index, .kind = "system_reminder", .id = part.id, .text = part.text },
        .compaction_summary => |part| .{
            .message_id = record.message_id,
            .order_index = record.order_index,
            .kind = "compaction_summary",
            .id = part.id,
            .compacted_until_message_id = part.compacted_until_message_id,
            .original_message_count = part.original_message_count,
            .summary = part.summary,
        },
        .subtask => |part| .{
            .message_id = record.message_id,
            .order_index = record.order_index,
            .kind = "subtask",
            .id = part.id,
            .child_session_id = part.child_session_id,
            .agent_id = part.agent_id,
            .status = part.status,
            .summary = part.summary,
        },
        .subtask_aggregate => |part| .{
            .message_id = record.message_id,
            .order_index = record.order_index,
            .kind = "subtask_aggregate",
            .id = part.id,
            .batch_id = part.batch_id,
            .summary = part.summary,
            .success_count = part.success_count,
            .failure_count = part.failure_count,
            .child_results_json = part.child_results_json,
        },
    };
}

fn partRecordFromJson(allocator: std.mem.Allocator, value: PartRecordJson) !PartRecord {
    return .{
        .message_id = try allocator.dupe(u8, value.message_id),
        .order_index = value.order_index,
        .part = if (std.mem.eql(u8, value.kind, "text"))
            .{ .text = .{ .id = try allocator.dupe(u8, value.id), .text = try allocator.dupe(u8, value.text orelse "") } }
        else if (std.mem.eql(u8, value.kind, "reasoning"))
            .{ .reasoning = .{ .id = try allocator.dupe(u8, value.id), .text = try allocator.dupe(u8, value.text orelse "") } }
        else if (std.mem.eql(u8, value.kind, "tool_call"))
            .{ .tool_call = .{ .id = try allocator.dupe(u8, value.id), .call_id = try allocator.dupe(u8, value.call_id orelse ""), .tool_name = try allocator.dupe(u8, value.tool_name orelse ""), .input_json = try allocator.dupe(u8, value.input_json orelse "") } }
        else if (std.mem.eql(u8, value.kind, "tool_result"))
            .{ .tool_result = .{ .id = try allocator.dupe(u8, value.id), .call_id = try allocator.dupe(u8, value.call_id orelse ""), .tool_name = try allocator.dupe(u8, value.tool_name orelse ""), .output_text = try allocator.dupe(u8, value.output_text orelse ""), .metadata_json = try allocator.dupe(u8, value.metadata_json orelse "{}") } }
        else if (std.mem.eql(u8, value.kind, "system_reminder"))
            .{ .system_reminder = .{ .id = try allocator.dupe(u8, value.id), .text = try allocator.dupe(u8, value.text orelse "") } }
        else if (std.mem.eql(u8, value.kind, "compaction_summary"))
            .{ .compaction_summary = .{
                .id = try allocator.dupe(u8, value.id),
                .compacted_until_message_id = try allocator.dupe(u8, value.compacted_until_message_id orelse ""),
                .original_message_count = value.original_message_count orelse 0,
                .summary = try allocator.dupe(u8, value.summary orelse ""),
            } }
        else if (std.mem.eql(u8, value.kind, "subtask"))
            .{ .subtask = .{
                .id = try allocator.dupe(u8, value.id),
                .child_session_id = try allocator.dupe(u8, value.child_session_id orelse ""),
                .agent_id = try allocator.dupe(u8, value.agent_id orelse ""),
                .status = try allocator.dupe(u8, value.status orelse ""),
                .summary = try allocator.dupe(u8, value.summary orelse ""),
            } }
        else if (std.mem.eql(u8, value.kind, "subtask_aggregate"))
            .{ .subtask_aggregate = .{
                .id = try allocator.dupe(u8, value.id),
                .batch_id = try allocator.dupe(u8, value.batch_id orelse ""),
                .summary = try allocator.dupe(u8, value.summary orelse ""),
                .success_count = value.success_count orelse 0,
                .failure_count = value.failure_count orelse 0,
                .child_results_json = try allocator.dupe(u8, value.child_results_json orelse "[]"),
            } }
        else
            return error.UnknownPartKind,
    };
}

fn appendJsonLine(allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    defer rendered.deinit(allocator);

    try rendered.print(allocator, "{f}", .{std.json.fmt(value, .{})});
    try rendered.append(allocator, '\n');

    try ensureParentDirectory(path);
    var file = try openAppendFile(path);
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeAll(rendered.items);
}

fn writeJsonFile(allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    defer rendered.deinit(allocator);

    try rendered.print(allocator, "{f}", .{std.json.fmt(value, .{})});

    try ensureParentDirectory(path);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeAll(rendered.items);
}

fn writeMessagesFile(allocator: std.mem.Allocator, path: []const u8, messages: []const message_model.MessageInfo) !void {
    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    defer rendered.deinit(allocator);

    for (messages) |message| {
        try rendered.print(allocator, "{f}", .{std.json.fmt(messageInfoToJson(message), .{})});
        try rendered.append(allocator, '\n');
    }

    try ensureParentDirectory(path);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeAll(rendered.items);
}

fn ensureParentDirectory(path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir_name| {
        _ = std.c.mkdir(@ptrCast(dir_name.ptr), 0o755);
    }
}

fn openAppendFile(path: []const u8) !std.fs.File {
    var file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.*.io(), path, .{ .mode = .read_write }) catch |err| switch (err) {
        error.FileNotFound => try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), path, .{ .read = true, .truncate = false }),
        else => return err,
    };
    try file.seekFromEnd(0);
    return file;
}

test "file session store supports create get list append and reopen" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sessions" });
    defer std.testing.allocator.free(store_path);

    var persisted_session_id: ?[]const u8 = null;
    defer if (persisted_session_id) |value| std.testing.allocator.free(value);

    {
        var store = try FileSessionStore.init(std.testing.allocator, store_path, null, null);
        defer store.deinit();

        var session_info = try store.createSession(std.testing.allocator, .{
            .title = "Store Test",
            .agent_id = "build",
        });
        defer session_info.deinit(std.testing.allocator);
        persisted_session_id = try std.testing.allocator.dupe(u8, session_info.id);

        var loaded = try store.getSession(std.testing.allocator, session_info.id);
        defer if (loaded) |*item| item.deinit(std.testing.allocator);

        try std.testing.expect(loaded != null);
        try std.testing.expectEqualStrings("Store Test", loaded.?.title);

        const listed = try store.listSessions(std.testing.allocator);
        defer {
            for (listed) |*item| item.deinit(std.testing.allocator);
            std.testing.allocator.free(listed);
        }
        try std.testing.expectEqual(@as(usize, 1), listed.len);

        var message = try store.appendMessage(std.testing.allocator, .{
            .session_id = session_info.id,
            .role = .assistant,
            .completed = false,
        });
        defer message.deinit(std.testing.allocator);

        var first_part = try part_model.text(std.testing.allocator, "alpha");
        defer first_part.deinit(std.testing.allocator);
    var second_part = try part_model.reasoning(std.testing.allocator, "beta");
    defer second_part.deinit(std.testing.allocator);
    var aggregate_part = try part_model.subtaskAggregate(std.testing.allocator, "batch_01", "all done", 1, 0, "[]");
    defer aggregate_part.deinit(std.testing.allocator);

        var stored_first = try store.appendPart(std.testing.allocator, .{
            .session_id = session_info.id,
            .message_id = message.id,
            .part = first_part,
        });
        defer stored_first.deinit(std.testing.allocator);

        var stored_second = try store.appendPart(std.testing.allocator, .{
            .session_id = session_info.id,
            .message_id = message.id,
            .part = second_part,
        });
        defer stored_second.deinit(std.testing.allocator);

        var stored_aggregate = try store.appendPart(std.testing.allocator, .{
            .session_id = session_info.id,
            .message_id = message.id,
            .part = aggregate_part,
        });
        defer stored_aggregate.deinit(std.testing.allocator);

        var timeline = try store.listTimeline(std.testing.allocator, session_info.id);
        defer timeline.deinit(std.testing.allocator);

        try std.testing.expectEqual(@as(usize, 1), timeline.messages.len);
        try std.testing.expectEqual(@as(usize, 3), timeline.parts.len);
        try std.testing.expectEqualStrings("text", timeline.parts[0].part.kind());
        try std.testing.expectEqualStrings("reasoning", timeline.parts[1].part.kind());
        try std.testing.expectEqualStrings("subtask_aggregate", timeline.parts[2].part.kind());
    }

    var reopened = try FileSessionStore.init(std.testing.allocator, store_path, null, null);
    defer reopened.deinit();

    var reopened_loaded = try reopened.getSession(std.testing.allocator, persisted_session_id.?);
    defer if (reopened_loaded) |*item| item.deinit(std.testing.allocator);
    try std.testing.expect(reopened_loaded != null);

    var reopened_timeline = try reopened.listTimeline(std.testing.allocator, persisted_session_id.?);
    defer reopened_timeline.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), reopened_timeline.parts.len);
}

test "file session store can update message completion state" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sessions" });
    defer std.testing.allocator.free(store_path);

    var store = try FileSessionStore.init(std.testing.allocator, store_path, null, null);
    defer store.deinit();

    var session_info = try store.createSession(std.testing.allocator, .{
        .title = "Update Message",
        .agent_id = "build",
    });
    defer session_info.deinit(std.testing.allocator);

    var message = try store.appendMessage(std.testing.allocator, .{
        .session_id = session_info.id,
        .role = .assistant,
        .completed = false,
    });
    defer message.deinit(std.testing.allocator);

    message.completed = true;
    try store.updateMessage(std.testing.allocator, message);

    var timeline = try store.listTimeline(std.testing.allocator, session_info.id);
    defer timeline.deinit(std.testing.allocator);

    try std.testing.expect(timeline.messages[0].completed);
}

test "file session store mutation logs include stable identity fields" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sessions" });
    defer std.testing.allocator.free(store_path);

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 32);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var store = try FileSessionStore.init(std.testing.allocator, store_path, null, &logger);
    defer store.deinit();

    var session_info = try store.createSession(std.testing.allocator, .{
        .title = "Logged Session",
        .agent_id = "build",
    });
    defer session_info.deinit(std.testing.allocator);

    var message = try store.appendMessage(std.testing.allocator, .{
        .session_id = session_info.id,
        .role = .assistant,
        .completed = false,
    });
    defer message.deinit(std.testing.allocator);

    var part = try part_model.text(std.testing.allocator, "hello");
    defer part.deinit(std.testing.allocator);

    var stored_part = try store.appendPart(std.testing.allocator, .{
        .session_id = session_info.id,
        .message_id = message.id,
        .part = part,
    });
    defer stored_part.deinit(std.testing.allocator);

    message.completed = true;
    try store.updateMessage(std.testing.allocator, message);

    try std.testing.expect(findLogRecordWithMessage(&memory_sink, "session created"));
    try std.testing.expect(findLogRecordWithMessage(&memory_sink, "message appended"));
    try std.testing.expect(findLogRecordWithMessage(&memory_sink, "message part appended"));
    try std.testing.expect(findLogRecordWithMessage(&memory_sink, "message updated"));
    try std.testing.expect(findFieldString(&memory_sink, "message appended", "message_id", message.id));
    try std.testing.expect(findFieldString(&memory_sink, "message part appended", "part_id", stored_part.part.id()));
}

fn findLogRecordWithMessage(sink: *framework.MemorySink, message: []const u8) bool {
    for (0..sink.count()) |index| {
        const record = sink.recordAt(index) orelse continue;
        if (std.mem.eql(u8, record.message, message)) return true;
    }
    return false;
}

fn findFieldString(sink: *framework.MemorySink, message: []const u8, key: []const u8, expected: []const u8) bool {
    for (0..sink.count()) |index| {
        const record = sink.recordAt(index) orelse continue;
        if (!std.mem.eql(u8, record.message, message)) continue;
        for (record.fields) |field| {
            if (std.mem.eql(u8, field.key, key) and field.value == .string and std.mem.eql(u8, field.value.string, expected)) {
                return true;
            }
        }
    }
    return false;
}
