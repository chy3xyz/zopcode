const std = @import("std");
const framework = @import("framework");
const types = @import("types.zig");

pub const QUESTION_ASKED_EVENT_TOPIC = "question.asked";
pub const QUESTION_REPLIED_EVENT_TOPIC = "question.replied";
pub const QUESTION_REJECTED_EVENT_TOPIC = "question.rejected";

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
};

pub const QuestionRuntime = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    next_id: u64 = 1,
    mutex: std.Io.Mutex = undefined,
    condition: std.Io.Condition = .init,
    pending: std.ArrayListUnmanaged(*PendingEntry) = .empty,

    const Self = @This();

    const PendingEntry = struct {
        request: types.QuestionRequest,
        answers: ?[]types.QuestionAnswer = null,
        rejected: bool = false,

        fn deinit(self: *PendingEntry, allocator: std.mem.Allocator) void {
            self.request.deinit(allocator);
            if (self.answers) |answers| types.freeAnswers(allocator, answers);
        }
    };

    pub fn init(deps: Dependencies) !*Self {
        const self = try deps.allocator.create(Self);
        self.* = .{
            .allocator = deps.allocator,
            .logger = deps.logger,
            .event_bus = deps.event_bus,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.*.io());
        for (self.pending.items) |entry| {
            entry.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.pending.deinit(self.allocator);
    }

    pub fn ask(self: *Self, input: types.QuestionAskInput) ![]types.QuestionAnswer {
        var request = try self.createPending(input);
        defer request.deinit(self.allocator);
        return self.waitForAnswer(request.id, request.session_id);
    }

    pub fn createPending(self: *Self, input: types.QuestionAskInput) !types.QuestionRequest {
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
        self.mutex.unlock(std.Io.Threaded.global_single_threaded.*.io());

        try publishAskedEvent(self.allocator, self.event_bus, entry.request);
        self.logger.child("question").info("question asked", &.{
            framework.LogField.string("request_id", entry.request.id),
            framework.LogField.int("question_count", @intCast(entry.request.questions.len)),
        });

        return request;
    }

    pub fn list(self: *Self, allocator: std.mem.Allocator) ![]types.QuestionRequest {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.*.io());
        const items = try allocator.alloc(types.QuestionRequest, self.pending.items.len);
        errdefer allocator.free(items);
        for (self.pending.items, 0..) |entry, index| {
            items[index] = try entry.request.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return items;
    }

    pub fn reply(self: *Self, request_id: []const u8, answers: []const types.QuestionAnswer) !bool {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.*.io());
        for (self.pending.items) |entry| {
            if (!std.mem.eql(u8, entry.request.id, request_id)) continue;
            const cloned = try self.allocator.alloc(types.QuestionAnswer, answers.len);
            errdefer self.allocator.free(cloned);
            for (answers, 0..) |answer, index| {
                cloned[index] = try answer.clone(self.allocator);
            }
            entry.answers = cloned;
            self.condition.broadcast(std.Io.Threaded.global_single_threaded.*.io());
            return true;
        }
        return false;
    }

    pub fn reject(self: *Self, request_id: []const u8) !bool {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.*.io());
        for (self.pending.items) |entry| {
            if (!std.mem.eql(u8, entry.request.id, request_id)) continue;
            entry.rejected = true;
            self.condition.broadcast(std.Io.Threaded.global_single_threaded.*.io());
            return true;
        }
        return false;
    }

    pub fn waitForAnswer(self: *Self, request_id: []const u8, session_id: []const u8) ![]types.QuestionAnswer {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.*.io());
        while (true) {
            if (findPendingLocked(self, request_id)) |entry| {
                if (entry.rejected) {
                    removePendingLocked(self, request_id);
                    self.condition.broadcast(std.Io.Threaded.global_single_threaded.*.io());
                    try publishRejectedEvent(self.allocator, self.event_bus, request_id, session_id);
                    entry.deinit(self.allocator);
                    self.allocator.destroy(entry);
                    return error.QuestionRejected;
                }
                if (entry.answers) |answers| {
                    const cloned = try self.allocator.alloc(types.QuestionAnswer, answers.len);
                    errdefer self.allocator.free(cloned);
                    for (answers, 0..) |answer, index| {
                        cloned[index] = try answer.clone(self.allocator);
                    }
                    removePendingLocked(self, request_id);
                    self.condition.broadcast(std.Io.Threaded.global_single_threaded.*.io());
                    try publishRepliedEvent(self.allocator, self.event_bus, request_id, session_id, answers);
                    entry.deinit(self.allocator);
                    self.allocator.destroy(entry);
                    return cloned;
                }
            } else {
                return error.QuestionRequestMissing;
            }
            try self.condition.wait(std.Io.Threaded.global_single_threaded.*.io(), &self.mutex);
        }
    }

    fn makeRequest(self: *Self, input: types.QuestionAskInput) !types.QuestionRequest {
        const id = try std.fmt.allocPrint(self.allocator, "question_{d}", .{self.nextRequestId()});
        const questions = try self.allocator.alloc(types.QuestionInfo, input.questions.len);
        errdefer self.allocator.free(questions);
        for (input.questions, 0..) |item, index| {
            questions[index] = try item.clone(self.allocator);
        }
        return .{
            .id = id,
            .session_id = try self.allocator.dupe(u8, input.session_id),
            .message_id = if (input.message_id) |value| try self.allocator.dupe(u8, value) else null,
            .call_id = if (input.call_id) |value| try self.allocator.dupe(u8, value) else null,
            .questions = questions,
        };
    }

    fn nextRequestId(self: *Self) u64 {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.*.io());
        const value = self.next_id;
        self.next_id += 1;
        return value;
    }
};

fn removePendingLocked(self: *QuestionRuntime, request_id: []const u8) void {
    for (self.pending.items, 0..) |entry, index| {
        if (!std.mem.eql(u8, entry.request.id, request_id)) continue;
        _ = self.pending.orderedRemove(index);
        return;
    }
}

fn findPendingLocked(self: *QuestionRuntime, request_id: []const u8) ?*QuestionRuntime.PendingEntry {
    for (self.pending.items) |entry| {
        if (std.mem.eql(u8, entry.request.id, request_id)) return entry;
    }
    return null;
}

fn publishAskedEvent(allocator: std.mem.Allocator, event_bus: framework.EventBus, request: types.QuestionRequest) !void {
    const payload = try encodeJsonAlloc(allocator, .{
        .id = request.id,
        .session_id = request.session_id,
        .message_id = request.message_id,
        .call_id = request.call_id,
        .questions = request.questions,
    });
    defer allocator.free(payload);
    _ = try event_bus.publish(QUESTION_ASKED_EVENT_TOPIC, payload);
}

fn publishRepliedEvent(
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    request_id: []const u8,
    session_id: []const u8,
    answers: []const types.QuestionAnswer,
) !void {
    const payload = try encodeJsonAlloc(allocator, .{
        .request_id = request_id,
        .session_id = session_id,
        .answers = answers,
    });
    defer allocator.free(payload);
    _ = try event_bus.publish(QUESTION_REPLIED_EVENT_TOPIC, payload);
}

fn publishRejectedEvent(allocator: std.mem.Allocator, event_bus: framework.EventBus, request_id: []const u8, session_id: []const u8) !void {
    const payload = try encodeJsonAlloc(allocator, .{
        .request_id = request_id,
        .session_id = session_id,
    });
    defer allocator.free(payload);
    _ = try event_bus.publish(QUESTION_REJECTED_EVENT_TOPIC, payload);
}

fn encodeJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "{f}", .{std.json.fmt(value, .{})});
    return allocator.dupe(u8, out.items);
}

test "question runtime answered and rejected flows" {
    if (std.process.getEnvVarOwned(std.testing.allocator, "SKIP_QUESTION_RUNTIME_TEST")) |value| {
        std.testing.allocator.free(value);
        return error.SkipZigTest;
    } else |_| {}
    var memory_sink = framework.MemorySink.init(std.testing.allocator, 64);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    const runtime = try QuestionRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    const options = [_]types.QuestionOption{
        .{ .label = "A", .description = "alpha" },
        .{ .label = "B", .description = "beta" },
    };
    const question_def = [_]types.QuestionInfo{
        .{
            .header = "Mode",
            .question = "Choose one",
            .options = @constCast(options[0..]),
        },
    };

    var pending_request = try runtime.createPending(.{
        .session_id = "session_01",
        .questions = @constCast(question_def[0..]),
    });
    defer pending_request.deinit(std.testing.allocator);

    const pending = try runtime.list(std.testing.allocator);
    defer {
        for (pending) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(pending);
    }

    var answers = [_]types.QuestionAnswer{
        .{ .selections = try types.cloneStringSlice(std.testing.allocator, @constCast(&[_][]const u8{"A"})) },
    };
    defer answers[0].deinit(std.testing.allocator);
    try std.testing.expect(try runtime.reply(pending[0].id, answers[0..]));
    const answered = try runtime.waitForAnswer(pending[0].id, pending[0].session_id);
    defer types.freeAnswers(std.testing.allocator, answered);
    try std.testing.expectEqual(@as(usize, 1), answered.len);
    try std.testing.expectEqualStrings("A", answered[0].selections[0]);

    var reject_request = try runtime.createPending(.{
        .session_id = "session_01",
        .questions = @constCast(question_def[0..]),
    });
    defer reject_request.deinit(std.testing.allocator);

    const pending_reject = try runtime.list(std.testing.allocator);
    defer {
        for (pending_reject) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(pending_reject);
    }
    try std.testing.expect(try runtime.reject(pending_reject[0].id));
    try std.testing.expectError(error.QuestionRejected, runtime.waitForAnswer(pending_reject[0].id, pending_reject[0].session_id));
}
