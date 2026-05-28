const std = @import("std");
const framework = @import("framework");
const rules = @import("rules.zig");
const types = @import("types.zig");

pub const PERMISSION_ASKED_EVENT_TOPIC = "permission.asked";
pub const PERMISSION_REPLIED_EVENT_TOPIC = "permission.replied";

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    rules: []const types.PermissionRule,
};

pub const PermissionRuntime = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    rules: []types.PermissionRule,
    next_id: u64 = 1,
    mutex: std.atomic.Mutex = .unlocked,
    condition: std.Io.Condition = .init,
    pending: std.ArrayListUnmanaged(*PendingEntry) = .empty,

    const Self = @This();

    const PendingEntry = struct {
        request: types.PermissionRequest,
        reply: ?types.PermissionReply = null,

        fn deinit(self: *PendingEntry, allocator: std.mem.Allocator) void {
            self.request.deinit(allocator);
        }
    };

    pub fn init(deps: Dependencies) !*Self {
        const self = try deps.allocator.create(Self);
        errdefer deps.allocator.destroy(self);
        self.* = .{
            .allocator = deps.allocator,
            .logger = deps.logger,
            .event_bus = deps.event_bus,
            .rules = try cloneRules(deps.allocator, deps.rules),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        for (self.rules) |*rule| rule.deinit(self.allocator);
        self.allocator.free(self.rules);
        for (self.pending.items) |entry| {
            entry.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.pending.deinit(self.allocator);
    }

    pub fn authorize(self: *Self, input: types.PermissionAskInput) !void {
        var should_ask = false;
        for (input.patterns) |pattern| {
            const action = rules.evaluate(input.permission, pattern, self.rules);
            switch (action) {
                .allow => {},
                .deny => return error.PermissionDenied,
                .ask => should_ask = true,
            }
        }
        if (!should_ask) return;

        var request = try self.createPending(input);
        defer request.deinit(self.allocator);
        const decision = try self.waitForReply(request.id, request.session_id);
        if (decision == .reject) return error.PermissionRejected;
    }

    pub fn createPending(self: *Self, input: types.PermissionAskInput) !types.PermissionRequest {
        var request = try self.makeRequest(input);
        errdefer request.deinit(self.allocator);

        const entry = try self.allocator.create(PendingEntry);
        errdefer self.allocator.destroy(entry);
        entry.* = .{
            .request = try request.clone(self.allocator),
        };
        errdefer entry.deinit(self.allocator);

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        try self.pending.append(self.allocator, entry);
        self.mutex.unlock();

        try publishAskedEvent(self.allocator, self.event_bus, entry.request);
        self.logger.child("permission").info("permission asked", &.{
            framework.LogField.string("permission", entry.request.permission),
            framework.LogField.string("request_id", entry.request.id),
        });

        return request;
    }

    pub fn list(self: *Self, allocator: std.mem.Allocator) ![]types.PermissionRequest {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const items = try allocator.alloc(types.PermissionRequest, self.pending.items.len);
        errdefer allocator.free(items);
        for (self.pending.items, 0..) |entry, index| {
            items[index] = try entry.request.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return items;
    }

    pub fn reply(self: *Self, request_id: []const u8, decision: types.PermissionReply) !bool {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        for (self.pending.items) |entry| {
            if (!std.mem.eql(u8, entry.request.id, request_id)) continue;
            entry.reply = decision;
            self.condition.broadcast(std.Io.Threaded.global_single_threaded.*.io());
            return true;
        }
        return false;
    }

    pub fn waitForReply(self: *Self, request_id: []const u8, session_id: ?[]const u8) !types.PermissionReply {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        while (true) {
            if (findPendingLocked(self, request_id)) |entry| {
                if (entry.reply) |decision| {
                    removePendingLocked(self, request_id);
                    self.condition.broadcast(std.Io.Threaded.global_single_threaded.*.io());
                    try publishRepliedEvent(self.allocator, self.event_bus, request_id, decision, session_id);
                    entry.deinit(self.allocator);
                    self.allocator.destroy(entry);
                    return decision;
                }
            } else {
                return error.PermissionRequestMissing;
            }
            self.condition.wait(&self.mutex);
        }
    }

    fn makeRequest(self: *Self, input: types.PermissionAskInput) !types.PermissionRequest {
        const id = try std.fmt.allocPrint(self.allocator, "permission_{d}", .{self.nextRequestId()});
        return .{
            .id = id,
            .session_id = if (input.session_id) |value| try self.allocator.dupe(u8, value) else null,
            .request_id = if (input.request_id) |value| try self.allocator.dupe(u8, value) else null,
            .message_id = if (input.message_id) |value| try self.allocator.dupe(u8, value) else null,
            .call_id = if (input.call_id) |value| try self.allocator.dupe(u8, value) else null,
            .tool_name = if (input.tool_name) |value| try self.allocator.dupe(u8, value) else null,
            .permission = try self.allocator.dupe(u8, input.permission),
            .patterns = try types.cloneStringSlice(self.allocator, input.patterns),
            .metadata_json = try self.allocator.dupe(u8, input.metadata_json),
        };
    }

    fn nextRequestId(self: *Self) u64 {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        const value = self.next_id;
        self.next_id += 1;
        return value;
    }
};

fn cloneRules(allocator: std.mem.Allocator, input: []const types.PermissionRule) ![]types.PermissionRule {
    const cloned = try allocator.alloc(types.PermissionRule, input.len);
    errdefer allocator.free(cloned);
    for (input, 0..) |item, index| {
        cloned[index] = try item.clone(allocator);
    }
    return cloned;
}

fn removePendingLocked(self: *PermissionRuntime, request_id: []const u8) void {
    for (self.pending.items, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.request.id, request_id)) continue;
        _ = self.pending.orderedRemove(index);
        return;
    }
}

fn findPendingLocked(self: *PermissionRuntime, request_id: []const u8) ?*PermissionRuntime.PendingEntry {
    for (self.pending.items) |entry| {
        if (std.mem.eql(u8, entry.request.id, request_id)) return entry;
    }
    return null;
}

fn publishAskedEvent(allocator: std.mem.Allocator, event_bus: framework.EventBus, request: types.PermissionRequest) !void {
    const payload = try encodeJsonAlloc(allocator, .{
        .id = request.id,
        .session_id = request.session_id,
        .request_id = request.request_id,
        .message_id = request.message_id,
        .call_id = request.call_id,
        .tool_name = request.tool_name,
        .permission = request.permission,
        .patterns = request.patterns,
        .metadata_json = request.metadata_json,
    });
    defer allocator.free(payload);
    _ = try event_bus.publish(PERMISSION_ASKED_EVENT_TOPIC, payload);
}

fn publishRepliedEvent(
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    request_id: []const u8,
    reply: types.PermissionReply,
    session_id: ?[]const u8,
) !void {
    const payload = try encodeJsonAlloc(allocator, .{
        .request_id = request_id,
        .reply = reply.asText(),
        .session_id = session_id,
    });
    defer allocator.free(payload);
    _ = try event_bus.publish(PERMISSION_REPLIED_EVENT_TOPIC, payload);
}

fn encodeJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.print("{f}", .{std.json.fmt(value, .{})});
    return allocator.dupe(u8, out.items);
}

test "permission runtime allow deny ask-once and reject flows" {
    if (std.process.getEnvVarOwned(std.testing.allocator, "SKIP_PERMISSION_RUNTIME_TEST")) |value| {
        std.testing.allocator.free(value);
        return error.SkipZigTest;
    } else |_| {}
    var memory_sink = framework.MemorySink.init(std.testing.allocator, 64);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    const configured_rules = [_]types.PermissionRule{
        .{ .permission = "read", .pattern = "*", .action = .allow },
        .{ .permission = "edit", .pattern = "*", .action = .ask },
        .{ .permission = "edit", .pattern = "*.md", .action = .deny },
    };

    const runtime = try PermissionRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
        .rules = configured_rules[0..],
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    try runtime.authorize(.{
        .permission = "read",
        .patterns = @constCast(&[_][]const u8{"README.md"}),
    });

    try std.testing.expectError(error.PermissionDenied, runtime.authorize(.{
        .permission = "edit",
        .patterns = @constCast(&[_][]const u8{"README.md"}),
    }));

    var pending_request = try runtime.createPending(.{
        .session_id = "session_01",
        .permission = "edit",
        .patterns = @constCast(&[_][]const u8{"src/main.zig"}),
    });
    defer pending_request.deinit(std.testing.allocator);

    const pending = try runtime.list(std.testing.allocator);
    defer {
        for (pending) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(pending);
    }
    try std.testing.expect(try runtime.reply(pending[0].id, .once));
    try std.testing.expectEqual(types.PermissionReply.once, try runtime.waitForReply(pending[0].id, pending[0].session_id));

    var reject_request = try runtime.createPending(.{
        .session_id = "session_01",
        .permission = "edit",
        .patterns = @constCast(&[_][]const u8{"src/other.zig"}),
    });
    defer reject_request.deinit(std.testing.allocator);

    const pending_reject = try runtime.list(std.testing.allocator);
    defer {
        for (pending_reject) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(pending_reject);
    }
    try std.testing.expect(try runtime.reply(pending_reject[0].id, .reject));
    try std.testing.expectEqual(types.PermissionReply.reject, try runtime.waitForReply(pending_reject[0].id, pending_reject[0].session_id));
}
