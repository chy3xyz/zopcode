const std = @import("std");
const framework = @import("framework");
const agent = @import("../agent/root.zig");
const provider = @import("../provider/root.zig");
const session = @import("../session/root.zig");
const state_store_model = @import("state_store.zig");
const types = @import("types.zig");

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    agent_registry: *agent.AgentRegistry,
    session_runtime: *session.SessionRuntime,
    session_store: session.SessionStore,
    history_service: session.HistoryService,
    state_store: state_store_model.LoopStateStore,
};

pub const LoopService = struct {
    allocator: std.mem.Allocator,
    deps: Dependencies,
    loops: std.ArrayListUnmanaged(types.LoopState) = .empty,
    mutex: std.Thread.Mutex = .{},
    subscription_id: ?u64 = null,
    watcher_thread: ?std.Thread = null,
    shutdown_requested: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const Self = @This();

    pub fn init(deps: Dependencies) Self {
        return .{
            .allocator = deps.allocator,
            .deps = deps,
        };
    }

    pub fn start(self: *Self) !void {
        if (self.watcher_thread != null) return;
        self.subscription_id = try session.subscribeSessionStatusEvents(self.deps.event_bus, self.deps.event_bus.latestSeq());
        try self.loadPersistedActiveStates();
        self.shutdown_requested.store(false, .release);
        self.watcher_thread = try std.Thread.spawn(.{}, watcherMain, .{self});
    }

    pub fn deinit(self: *Self) void {
        self.shutdown_requested.store(true, .release);
        if (self.watcher_thread) |thread| {
            thread.join();
            self.watcher_thread = null;
        }
        if (self.subscription_id) |subscription_id| {
            self.deps.event_bus.unsubscribe(subscription_id) catch {};
            self.subscription_id = null;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.loops.items) |*state| state.deinit(self.allocator);
        self.loops.deinit(self.allocator);
    }

    pub fn startLoop(self: *Self, request: types.LoopStartRequest) !types.LoopState {
        var session_info = (try self.deps.session_store.getSession(self.allocator, request.session_id)) orelse return error.SessionNotFound;
        defer session_info.deinit(self.allocator);

        if (request.ultrawork) {
            _ = self.deps.agent_registry.get(request.oracle_profile_id orelse "oracle") orelse return error.OracleProfileNotFound;
        }

        {
            self.mutex.lock();
            defer self.mutex.unlock();
            for (self.loops.items) |state| {
                if (!state.active) continue;
                if (std.mem.eql(u8, state.current_session_id, request.session_id) or std.mem.eql(u8, state.root_session_id, request.session_id)) {
                    return error.LoopAlreadyActiveForSession;
                }
            }
        }

        const now = std.time.milliTimestamp();
        const loop_id = try std.fmt.allocPrint(self.allocator, "loop_{d}", .{now});
        errdefer self.allocator.free(loop_id);

        const completion_signal = try self.allocator.dupe(u8, request.completion_signal orelse "DONE");
        errdefer self.allocator.free(completion_signal);
        const verification_signal = try self.allocator.dupe(u8, request.verification_signal orelse "VERIFIED");
        errdefer self.allocator.free(verification_signal);
        const oracle_profile_id = try self.allocator.dupe(u8, request.oracle_profile_id orelse "oracle");
        errdefer self.allocator.free(oracle_profile_id);
        const continuation_prompt = if (request.continuation_prompt) |value|
            try self.allocator.dupe(u8, value)
        else
            try std.fmt.allocPrint(self.allocator, "Continue the task. Emit {s} only when the task is truly complete.", .{completion_signal});
        errdefer self.allocator.free(continuation_prompt);

        var state = types.LoopState{
            .loop_id = loop_id,
            .root_session_id = try self.allocator.dupe(u8, session_info.id),
            .current_session_id = try self.allocator.dupe(u8, session_info.id),
            .agent_id = if (request.agent_id) |value| try self.allocator.dupe(u8, value) else try self.allocator.dupe(u8, session_info.agent_id),
            .category = if (request.category) |value| try self.allocator.dupe(u8, value) else null,
            .model = if (request.model) |value| try value.clone(self.allocator) else null,
            .continuation_prompt = continuation_prompt,
            .completion_signal = completion_signal,
            .strategy = request.strategy,
            .iteration = 0,
            .max_iterations = request.max_iterations,
            .active = true,
            .phase = .running,
            .ultrawork = request.ultrawork,
            .verification_pending = false,
            .verification_signal = verification_signal,
            .oracle_profile_id = oracle_profile_id,
            .started_at_ms = now,
            .updated_at_ms = now,
        };
        defer state.deinit(self.allocator);

        try self.persistAndTrack(state);
        self.logInfo("loop started", &.{
            framework.LogField.string("loop_id", state.loop_id),
            framework.LogField.string("session_id", state.current_session_id),
            framework.LogField.string("strategy", state.strategy.asText()),
            framework.LogField.boolean("ultrawork", state.ultrawork),
        });

        if (request.kickoff) try self.maybeKickoff(&state);
        return try state.clone(self.allocator);
    }

    pub fn cancelLoop(self: *Self, loop_id: []const u8) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.loops.items) |*state| {
            if (!std.mem.eql(u8, state.loop_id, loop_id)) continue;
            state.active = false;
            state.phase = .cancelled;
            state.verification_pending = false;
            state.touch();
            try self.deps.state_store.put(self.allocator, state.*);
            self.logInfo("loop cancelled", &.{framework.LogField.string("loop_id", loop_id)});
            return true;
        }
        return false;
    }

    pub fn getLoop(self: *Self, allocator: std.mem.Allocator, loop_id: []const u8) !?types.LoopState {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.loops.items) |state| {
            if (std.mem.eql(u8, state.loop_id, loop_id)) return try state.clone(allocator);
        }
        return null;
    }

    pub fn listActive(self: *Self, allocator: std.mem.Allocator) ![]types.LoopState {
        self.mutex.lock();
        defer self.mutex.unlock();

        var results: std.ArrayListUnmanaged(types.LoopState) = .empty;
        errdefer {
            for (results.items) |*state| state.deinit(allocator);
            results.deinit(allocator);
        }

        for (self.loops.items) |state| {
            if (!state.active) continue;
            try results.append(allocator, try state.clone(allocator));
        }
        return try results.toOwnedSlice(allocator);
    }

    fn loadPersistedActiveStates(self: *Self) !void {
        const active = try self.deps.state_store.listActive(self.allocator);
        defer {
            for (active) |*state| state.deinit(self.allocator);
            self.allocator.free(active);
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.loops.items) |*state| state.deinit(self.allocator);
        self.loops.clearRetainingCapacity();

        for (active) |state| {
            try self.loops.append(self.allocator, try state.clone(self.allocator));
        }
    }

    fn watcherMain(self: *Self) void {
        while (!self.shutdown_requested.load(.acquire)) {
            self.pollSessionEvents() catch |err| {
                self.logError("loop watcher poll failed", err, &.{});
                std.Thread.sleep(10 * std.time.ns_per_ms);
            };
        }
    }

    fn pollSessionEvents(self: *Self) !void {
        const subscription_id = self.subscription_id orelse return;
        const events_batch = try session.pollSessionStatusEvents(self.allocator, self.deps.event_bus, subscription_id, 16);
        defer {
            for (events_batch) |*event| event.deinit(self.allocator);
            self.allocator.free(events_batch);
        }

        if (events_batch.len == 0) {
            std.Thread.sleep(10 * std.time.ns_per_ms);
            return;
        }

        for (events_batch) |event| {
            try self.handleSessionStatusEvent(event);
        }
    }

    fn handleSessionStatusEvent(self: *Self, event: session.SessionStatusEvent) !void {
        const snapshot = try self.findMatchingLoops(event.session_id);
        defer {
            for (snapshot) |*state| state.deinit(self.allocator);
            self.allocator.free(snapshot);
        }

        for (snapshot) |state| {
            if (state.verification_pending and state.verification_session_id != null and std.mem.eql(u8, state.verification_session_id.?, event.session_id)) {
                try self.handleVerificationStatus(state, event);
            } else if (std.mem.eql(u8, state.current_session_id, event.session_id)) {
                try self.handleWorkStatus(state, event);
            }
        }
    }

    fn handleWorkStatus(self: *Self, state: types.LoopState, event: session.SessionStatusEvent) !void {
        const status = session.SessionStatus.fromText(event.status) orelse return;
        switch (status) {
            .running, .waiting_tool => return,
            .cancelled => return self.markTerminal(state.loop_id, .cancelled),
            .failed => return self.markTerminal(state.loop_id, .failed),
            .completed, .idle => {},
        }

        const assistant_text = try self.latestAssistantText(state.current_session_id);
        defer self.allocator.free(assistant_text);

        if (containsSignal(assistant_text, state.completion_signal)) {
            if (state.ultrawork) {
                try self.enterVerificationPending(state, assistant_text);
            } else {
                try self.markTerminal(state.loop_id, .completed);
            }
            return;
        }

        try self.continueLoop(state, null);
    }

    fn handleVerificationStatus(self: *Self, state: types.LoopState, event: session.SessionStatusEvent) !void {
        const status = session.SessionStatus.fromText(event.status) orelse return;
        switch (status) {
            .running, .waiting_tool => return,
            .cancelled, .failed => return self.restartAfterVerificationFailure(state, "verification task failed"),
            .completed, .idle => {},
        }

        const verification_session_id = state.verification_session_id orelse return;
        const verification_text = try self.latestAssistantText(verification_session_id);
        defer self.allocator.free(verification_text);

        if (containsSignal(verification_text, state.verification_signal)) {
            try self.markTerminal(state.loop_id, .completed);
            return;
        }

        try self.restartAfterVerificationFailure(state, verification_text);
    }

    fn continueLoop(self: *Self, original: types.LoopState, feedback: ?[]const u8) !void {
        var state = try original.clone(self.allocator);
        defer state.deinit(self.allocator);

        if (state.max_iterations) |limit| {
            if (state.iteration >= limit) {
                try self.markTerminal(state.loop_id, .failed);
                return;
            }
        }

        state.iteration += 1;
        state.phase = .running;
        state.active = true;
        state.verification_pending = false;
        if (state.verification_session_id) |value| {
            self.allocator.free(value);
            state.verification_session_id = null;
        }
        if (state.verification_attempt_id) |value| {
            self.allocator.free(value);
            state.verification_attempt_id = null;
        }
        state.touch();

        switch (state.strategy) {
            .continue_same_session => try self.submitContinuationSameSession(&state, feedback),
            .reset_new_session => try self.submitContinuationResetSession(&state, feedback),
        }

        try self.persistAndTrack(state);
        self.logInfo("loop continued", &.{
            framework.LogField.string("loop_id", state.loop_id),
            framework.LogField.string("session_id", state.current_session_id),
            framework.LogField.int("iteration", state.iteration),
            framework.LogField.string("strategy", state.strategy.asText()),
        });
    }

    fn enterVerificationPending(self: *Self, original: types.LoopState, work_summary: []const u8) !void {
        var state = try original.clone(self.allocator);
        defer state.deinit(self.allocator);

        const verification_attempt_id = try std.fmt.allocPrint(self.allocator, "{s}_verify_{d}", .{ state.loop_id, state.iteration });
        errdefer self.allocator.free(verification_attempt_id);

        var verification_session = try self.deps.session_runtime.createSessionWithRequest(.{
            .title = "Oracle Verification",
            .agent_id = state.oracle_profile_id,
            .parent_id = state.current_session_id,
        });
        defer verification_session.deinit(self.allocator);

        const verification_prompt = try buildVerificationPrompt(
            self.allocator,
            state.loop_id,
            state.completion_signal,
            state.verification_signal,
            work_summary,
        );
        defer self.allocator.free(verification_prompt);

        var prompt_message = try self.deps.session_runtime.submitPrompt(.{
            .session_id = verification_session.id,
            .agent_id = state.oracle_profile_id,
            .parts = &.{.{ .text = verification_prompt }},
        });
        defer prompt_message.deinit(self.allocator);

        const request_id = try std.fmt.allocPrint(self.allocator, "{s}_verify_req_{d}", .{ state.loop_id, state.iteration });
        defer self.allocator.free(request_id);
        _ = try self.deps.session_runtime.submitAgentTask(.{
            .session_id = verification_session.id,
            .agent_id = state.oracle_profile_id,
            .request_id = request_id,
        });

        state.phase = .verification_pending;
        state.verification_pending = true;
        if (state.verification_session_id) |value| self.allocator.free(value);
        state.verification_session_id = try self.allocator.dupe(u8, verification_session.id);
        if (state.verification_attempt_id) |value| self.allocator.free(value);
        state.verification_attempt_id = verification_attempt_id;
        state.touch();

        try self.persistAndTrack(state);
        self.logInfo("loop entered verification pending", &.{
            framework.LogField.string("loop_id", state.loop_id),
            framework.LogField.string("verification_session_id", state.verification_session_id.?),
        });
    }

    fn restartAfterVerificationFailure(self: *Self, original: types.LoopState, feedback: []const u8) !void {
        try self.continueLoop(original, feedback);
    }

    fn submitContinuationSameSession(self: *Self, state: *types.LoopState, feedback: ?[]const u8) !void {
        const prompt_text = try buildContinuationPrompt(self.allocator, state.*, feedback);
        defer self.allocator.free(prompt_text);

        var prompt_message = try self.deps.session_runtime.submitPrompt(.{
            .session_id = state.current_session_id,
            .agent_id = state.agent_id,
            .parts = &.{.{ .text = prompt_text }},
        });
        defer prompt_message.deinit(self.allocator);

        const request_id = try std.fmt.allocPrint(self.allocator, "{s}_iter_{d}", .{ state.loop_id, state.iteration });
        defer self.allocator.free(request_id);
        _ = try self.deps.session_runtime.submitAgentTask(.{
            .session_id = state.current_session_id,
            .agent_id = state.agent_id,
            .category = state.category,
            .model = state.model,
            .request_id = request_id,
        });
    }

    fn submitContinuationResetSession(self: *Self, state: *types.LoopState, feedback: ?[]const u8) !void {
        const previous_session_id = try self.allocator.dupe(u8, state.current_session_id);
        defer self.allocator.free(previous_session_id);

        const previous_context = try self.latestAssistantText(previous_session_id);
        defer self.allocator.free(previous_context);

        const title = try std.fmt.allocPrint(self.allocator, "Loop Reset {d}", .{state.iteration});
        defer self.allocator.free(title);

        var next_session = try self.deps.session_runtime.createSessionWithRequest(.{
            .title = title,
            .agent_id = state.agent_id orelse "build",
            .parent_id = previous_session_id,
        });
        defer next_session.deinit(self.allocator);

        const prompt_text = try buildResetPrompt(self.allocator, state.*, previous_context, feedback);
        defer self.allocator.free(prompt_text);

        var prompt_message = try self.deps.session_runtime.submitPrompt(.{
            .session_id = next_session.id,
            .agent_id = state.agent_id,
            .parts = &.{.{ .text = prompt_text }},
        });
        defer prompt_message.deinit(self.allocator);

        const request_id = try std.fmt.allocPrint(self.allocator, "{s}_iter_{d}", .{ state.loop_id, state.iteration });
        defer self.allocator.free(request_id);
        _ = try self.deps.session_runtime.submitAgentTask(.{
            .session_id = next_session.id,
            .agent_id = state.agent_id,
            .category = state.category,
            .model = state.model,
            .request_id = request_id,
        });

        self.allocator.free(state.current_session_id);
        state.current_session_id = try self.allocator.dupe(u8, next_session.id);
    }

    fn maybeKickoff(self: *Self, state: *types.LoopState) !void {
        var status = try self.deps.session_runtime.getSessionStatus(self.allocator, state.current_session_id);
        defer if (status) |*value| value.deinit(self.allocator);

        if (status) |value| {
            switch (value.status) {
                .running, .waiting_tool => return,
                else => {},
            }
        }

        const request_id = try std.fmt.allocPrint(self.allocator, "{s}_iter_0", .{state.loop_id});
        defer self.allocator.free(request_id);
        _ = try self.deps.session_runtime.submitAgentTask(.{
            .session_id = state.current_session_id,
            .agent_id = state.agent_id,
            .category = state.category,
            .model = state.model,
            .request_id = request_id,
        });
    }

    fn latestAssistantText(self: *Self, session_id: []const u8) ![]u8 {
        const history = try self.deps.history_service.list(self.allocator, session_id);
        defer {
            for (history) |*message| message.deinit(self.allocator);
            self.allocator.free(history);
        }

        var idx = history.len;
        while (idx > 0) {
            idx -= 1;
            const message = history[idx];
            if (message.info.role != .assistant) continue;

            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(self.allocator);
            const writer = out.writer(self.allocator);
            for (message.parts) |part| {
                switch (part) {
                    .text => |value| try writer.writeAll(value.text),
                    .reasoning => |value| try writer.writeAll(value.text),
                    else => {},
                }
            }
            return self.allocator.dupe(u8, out.items);
        }

        return self.allocator.dupe(u8, "");
    }

    fn markTerminal(self: *Self, loop_id: []const u8, phase: types.LoopPhase) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.loops.items) |*state| {
            if (!std.mem.eql(u8, state.loop_id, loop_id)) continue;
            state.active = false;
            state.phase = phase;
            state.verification_pending = false;
            if (state.verification_session_id) |value| {
                self.allocator.free(value);
                state.verification_session_id = null;
            }
            state.touch();
            try self.deps.state_store.put(self.allocator, state.*);
            self.logInfo("loop finished", &.{
                framework.LogField.string("loop_id", state.loop_id),
                framework.LogField.string("phase", phase.asText()),
            });
            return;
        }
    }

    fn persistAndTrack(self: *Self, state: types.LoopState) !void {
        try self.deps.state_store.put(self.allocator, state);
        self.mutex.lock();
        defer self.mutex.unlock();

        for (self.loops.items) |*existing| {
            if (!std.mem.eql(u8, existing.loop_id, state.loop_id)) continue;
            existing.deinit(self.allocator);
            existing.* = try state.clone(self.allocator);
            return;
        }
        try self.loops.append(self.allocator, try state.clone(self.allocator));
    }

    fn findMatchingLoops(self: *Self, session_id: []const u8) ![]types.LoopState {
        self.mutex.lock();
        defer self.mutex.unlock();

        var results: std.ArrayListUnmanaged(types.LoopState) = .empty;
        errdefer {
            for (results.items) |*state| state.deinit(self.allocator);
            results.deinit(self.allocator);
        }

        for (self.loops.items) |state| {
            if (!state.active) continue;
            if (std.mem.eql(u8, state.current_session_id, session_id) or
                (state.verification_session_id != null and std.mem.eql(u8, state.verification_session_id.?, session_id)))
            {
                try results.append(self.allocator, try state.clone(self.allocator));
            }
        }

        return try results.toOwnedSlice(self.allocator);
    }

    fn logInfo(self: *Self, message: []const u8, fields: []const framework.LogField) void {
        self.deps.logger.child("loop").info(message, fields);
    }

    fn logError(self: *Self, message: []const u8, err: anyerror, extra_fields: []const framework.LogField) void {
        var fields_buffer: [8]framework.LogField = undefined;
        var count: usize = 0;
        for (extra_fields) |field| {
            fields_buffer[count] = field;
            count += 1;
        }
        fields_buffer[count] = framework.LogField.string("error", @errorName(err));
        count += 1;
        self.deps.logger.child("loop").@"error"(message, fields_buffer[0..count]);
    }
};

fn containsSignal(text: []const u8, signal: []const u8) bool {
    var tokens = std.mem.tokenizeAny(u8, text, " \t\r\n");
    while (tokens.next()) |token| {
        const trimmed = std.mem.trim(u8, token, "[](){}<>,.:;!?\"'");
        if (std.mem.eql(u8, trimmed, signal)) return true;
    }
    return std.mem.eql(u8, std.mem.trim(u8, text, " \t\r\n[](){}<>,.:;!?\"'"), signal);
}

fn buildContinuationPrompt(allocator: std.mem.Allocator, state: types.LoopState, feedback: ?[]const u8) ![]u8 {
    if (feedback) |value| {
        return std.fmt.allocPrint(
            allocator,
            "{s}\n\nVerification feedback:\n{s}\n\nEmit {s} only when the task is truly complete.",
            .{ state.continuation_prompt, value, state.completion_signal },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{s}\n\nEmit {s} only when the task is truly complete.",
        .{ state.continuation_prompt, state.completion_signal },
    );
}

fn buildResetPrompt(allocator: std.mem.Allocator, state: types.LoopState, previous_context: []const u8, feedback: ?[]const u8) ![]u8 {
    if (feedback) |value| {
        return std.fmt.allocPrint(
            allocator,
            "Prior session context:\n{s}\n\n{s}\n\nVerification feedback:\n{s}\n\nEmit {s} only when the task is truly complete.",
            .{ previous_context, state.continuation_prompt, value, state.completion_signal },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "Prior session context:\n{s}\n\n{s}\n\nEmit {s} only when the task is truly complete.",
        .{ previous_context, state.continuation_prompt, state.completion_signal },
    );
}

fn buildVerificationPrompt(
    allocator: std.mem.Allocator,
    loop_id: []const u8,
    completion_signal: []const u8,
    verification_signal: []const u8,
    work_summary: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "Oracle verification for loop {s}.\n\nThe worker claimed completion with signal {s}.\n\nWork summary:\n{s}\n\nReply with {s} only if the work is truly complete. Otherwise explain what remains without using {s}.",
        .{ loop_id, completion_signal, work_summary, verification_signal, verification_signal },
    );
}

test "loop service can start and cancel a tracked loop" {
    var fixture = try makeLoopFixture();
    defer fixture.deinit();

    var session_info = try fixture.runtime.createSession("Loop", "build");
    defer session_info.deinit(std.testing.allocator);
    var prompt_message = try fixture.runtime.submitPrompt(.{
        .session_id = session_info.id,
        .parts = &.{.{ .text = "do work" }},
    });
    defer prompt_message.deinit(std.testing.allocator);

    var loop_state = try fixture.service.startLoop(.{
        .session_id = session_info.id,
        .continuation_prompt = "continue",
        .kickoff = false,
    });
    defer loop_state.deinit(std.testing.allocator);

    var loaded = (try fixture.service.getLoop(std.testing.allocator, loop_state.loop_id)).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(loaded.active);

    try std.testing.expect(try fixture.service.cancelLoop(loop_state.loop_id));
    var cancelled = (try fixture.service.getLoop(std.testing.allocator, loop_state.loop_id)).?;
    defer cancelled.deinit(std.testing.allocator);
    try std.testing.expect(!cancelled.active);
    try std.testing.expectEqual(types.LoopPhase.cancelled, cancelled.phase);
}

test "loop service continues incomplete session in same session" {
    var fixture = try makeLoopFixture();
    defer fixture.deinit();

    MockLoopProvider.reset();
    MockLoopProvider.work_mode = .incomplete_then_done;

    var session_info = try fixture.runtime.createSession("Loop", "build");
    defer session_info.deinit(std.testing.allocator);
    var prompt_message = try fixture.runtime.submitPrompt(.{
        .session_id = session_info.id,
        .parts = &.{.{ .text = "do work" }},
    });
    defer prompt_message.deinit(std.testing.allocator);

    var loop_state = try fixture.service.startLoop(.{
        .session_id = session_info.id,
        .continuation_prompt = "keep going",
        .completion_signal = "DONE",
    });
    defer loop_state.deinit(std.testing.allocator);

    try waitForLoopPhase(fixture.service, loop_state.loop_id, .completed, 5000);

    var loaded = (try fixture.service.getLoop(std.testing.allocator, loop_state.loop_id)).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(session_info.id, loaded.current_session_id);
    try std.testing.expectEqual(@as(u32, 1), loaded.iteration);
    try std.testing.expectEqual(@as(usize, 2), MockLoopProvider.work_call_count);
}

test "loop service reset strategy creates a child session for continuation" {
    var fixture = try makeLoopFixture();
    defer fixture.deinit();

    MockLoopProvider.reset();
    MockLoopProvider.work_mode = .incomplete_then_done;

    var session_info = try fixture.runtime.createSession("Loop", "build");
    defer session_info.deinit(std.testing.allocator);
    var prompt_message = try fixture.runtime.submitPrompt(.{
        .session_id = session_info.id,
        .parts = &.{.{ .text = "do reset work" }},
    });
    defer prompt_message.deinit(std.testing.allocator);

    var loop_state = try fixture.service.startLoop(.{
        .session_id = session_info.id,
        .continuation_prompt = "continue in reset mode",
        .strategy = .reset_new_session,
    });
    defer loop_state.deinit(std.testing.allocator);

    try waitForLoopPhase(fixture.service, loop_state.loop_id, .completed, 5000);

    var loaded = (try fixture.service.getLoop(std.testing.allocator, loop_state.loop_id)).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expect(!std.mem.eql(u8, session_info.id, loaded.current_session_id));

    const sessions = try fixture.session_store.listSessions(std.testing.allocator);
    defer {
        for (sessions) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(sessions);
    }
    try std.testing.expectEqual(@as(usize, 2), sessions.len);

    var found_child = false;
    for (sessions) |item| {
        if (item.parent_id) |parent_id| {
            if (std.mem.eql(u8, parent_id, session_info.id)) found_child = true;
        }
    }
    try std.testing.expect(found_child);
}

test "ultrawork enters verification pending and completes after oracle verification" {
    var fixture = try makeLoopFixture();
    defer fixture.deinit();

    MockLoopProvider.reset();
    MockLoopProvider.work_mode = .always_done;
    MockLoopProvider.verification_mode = .verified_first;

    var session_info = try fixture.runtime.createSession("Ultrawork", "build");
    defer session_info.deinit(std.testing.allocator);
    var prompt_message = try fixture.runtime.submitPrompt(.{
        .session_id = session_info.id,
        .parts = &.{.{ .text = "finish and verify" }},
    });
    defer prompt_message.deinit(std.testing.allocator);

    var loop_state = try fixture.service.startLoop(.{
        .session_id = session_info.id,
        .ultrawork = true,
        .completion_signal = "DONE",
        .verification_signal = "VERIFIED",
    });
    defer loop_state.deinit(std.testing.allocator);

    try waitForLoopPhase(fixture.service, loop_state.loop_id, .verification_pending, 5000);
    try waitForLoopPhase(fixture.service, loop_state.loop_id, .completed, 5000);

    var loaded = (try fixture.service.getLoop(std.testing.allocator, loop_state.loop_id)).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), MockLoopProvider.work_call_count);
    try std.testing.expectEqual(@as(usize, 1), MockLoopProvider.verify_call_count);
    try std.testing.expect(!loaded.active);
}

test "ultrawork failed verification restarts the work loop" {
    var fixture = try makeLoopFixture();
    defer fixture.deinit();

    MockLoopProvider.reset();
    MockLoopProvider.work_mode = .always_done;
    MockLoopProvider.verification_mode = .fail_then_verified;

    var session_info = try fixture.runtime.createSession("Ultrawork", "build");
    defer session_info.deinit(std.testing.allocator);
    var prompt_message = try fixture.runtime.submitPrompt(.{
        .session_id = session_info.id,
        .parts = &.{.{ .text = "finish and verify" }},
    });
    defer prompt_message.deinit(std.testing.allocator);

    var loop_state = try fixture.service.startLoop(.{
        .session_id = session_info.id,
        .ultrawork = true,
        .completion_signal = "DONE",
        .verification_signal = "VERIFIED",
    });
    defer loop_state.deinit(std.testing.allocator);

    try waitForLoopPhase(fixture.service, loop_state.loop_id, .completed, 5000);

    var loaded = (try fixture.service.getLoop(std.testing.allocator, loop_state.loop_id)).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), loaded.iteration);
    try std.testing.expectEqual(@as(usize, 2), MockLoopProvider.work_call_count);
    try std.testing.expectEqual(@as(usize, 2), MockLoopProvider.verify_call_count);
}

fn waitForLoopPhase(service: *LoopService, loop_id: []const u8, expected: types.LoopPhase, timeout_ms: u64) !void {
    const start = std.time.milliTimestamp();
    while (@as(u64, @intCast(std.time.milliTimestamp() - start)) < timeout_ms) {
        var loaded = try service.getLoop(std.testing.allocator, loop_id);
        defer if (loaded) |*state| state.deinit(std.testing.allocator);
        if (loaded) |state| {
            if (state.phase == expected) return;
        }
        std.Thread.sleep(10 * std.time.ns_per_ms);
    }
    return error.LoopPhaseTimeout;
}

const LoopFixture = struct {
    tmp_dir: std.testing.TmpDir,
    root_path: []u8,
    memory_sink: *framework.MemorySink,
    logger: *framework.Logger,
    event_bus: *framework.MemoryEventBus,
    runner: *framework.TaskRunner,
    status_index: *session.SessionStatusIndex,
    session_store_impl: *session.FileSessionStore,
    session_store: session.SessionStore,
    agent_registry: *agent.AgentRegistry,
    provider_registry: *provider.ProviderRegistry,
    tool_registry: *(@import("../tools/root.zig").ToolRegistry),
    tool_runtime: *(@import("../tools/root.zig").ToolRuntime),
    config_store: *framework.MemoryConfigStore,
    config_runtime: *(@import("../config/root.zig").ConfigRuntime),
    compaction_policy: *session.DisabledCompactionPolicy,
    runtime: *session.SessionRuntime,
    loop_store: *state_store_model.FileLoopStateStore,
    service: *LoopService,

    fn deinit(self: *LoopFixture) void {
        self.service.deinit();
        std.testing.allocator.destroy(self.service);
        self.loop_store.deinit();
        std.testing.allocator.destroy(self.loop_store);
        std.testing.allocator.destroy(self.runtime);
        self.config_runtime.deinit();
        std.testing.allocator.destroy(self.config_runtime);
        self.config_store.deinit();
        std.testing.allocator.destroy(self.config_store);
        std.testing.allocator.destroy(self.compaction_policy);
        self.tool_runtime.deinit();
        std.testing.allocator.destroy(self.tool_runtime);
        self.tool_registry.deinit();
        std.testing.allocator.destroy(self.tool_registry);
        self.provider_registry.deinit();
        std.testing.allocator.destroy(self.provider_registry);
        self.agent_registry.deinit();
        std.testing.allocator.destroy(self.agent_registry);
        self.session_store_impl.deinit();
        std.testing.allocator.destroy(self.session_store_impl);
        self.runner.deinit();
        std.testing.allocator.destroy(self.runner);
        self.status_index.deinit();
        std.testing.allocator.destroy(self.status_index);
        self.event_bus.deinit();
        std.testing.allocator.destroy(self.event_bus);
        self.logger.deinit();
        std.testing.allocator.destroy(self.logger);
        self.memory_sink.deinit();
        std.testing.allocator.destroy(self.memory_sink);
        std.testing.allocator.free(self.root_path);
        self.tmp_dir.cleanup();
    }
};

fn makeLoopFixture() !LoopFixture {
    const config = @import("../config/root.zig");
    const tools = @import("../tools/root.zig");

    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    errdefer std.testing.allocator.free(root_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sessions" });
    defer std.testing.allocator.free(store_path);
    const loop_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, "_loops" });
    defer std.testing.allocator.free(loop_path);

    const memory_sink = try std.testing.allocator.create(framework.MemorySink);
    errdefer std.testing.allocator.destroy(memory_sink);
    memory_sink.* = framework.MemorySink.init(std.testing.allocator, 512);
    errdefer memory_sink.deinit();

    const logger = try std.testing.allocator.create(framework.Logger);
    errdefer std.testing.allocator.destroy(logger);
    logger.* = framework.Logger.init(memory_sink.asLogSink(), .trace);
    errdefer logger.deinit();

    const event_bus = try std.testing.allocator.create(framework.MemoryEventBus);
    errdefer std.testing.allocator.destroy(event_bus);
    event_bus.* = framework.MemoryEventBus.init(std.testing.allocator);
    errdefer event_bus.deinit();

    const runner = try std.testing.allocator.create(framework.TaskRunner);
    errdefer std.testing.allocator.destroy(runner);
    runner.* = framework.TaskRunner.init(std.testing.allocator);
    errdefer runner.deinit();

    const status_index = try std.testing.allocator.create(session.SessionStatusIndex);
    errdefer std.testing.allocator.destroy(status_index);
    status_index.* = session.SessionStatusIndex.init(std.testing.allocator);
    errdefer status_index.deinit();

    const session_store_impl = try std.testing.allocator.create(session.FileSessionStore);
    errdefer std.testing.allocator.destroy(session_store_impl);
    session_store_impl.* = try session.FileSessionStore.init(std.testing.allocator, store_path, event_bus.asEventBus(), logger);
    errdefer session_store_impl.deinit();
    const session_store = session_store_impl.asSessionStore();

    const agent_registry = try std.testing.allocator.create(agent.AgentRegistry);
    errdefer std.testing.allocator.destroy(agent_registry);
    agent_registry.* = agent.AgentRegistry.init(std.testing.allocator);
    errdefer agent_registry.deinit();
    try agent.registerBuiltins(agent_registry);

    const provider_registry = try std.testing.allocator.create(provider.ProviderRegistry);
    errdefer std.testing.allocator.destroy(provider_registry);
    provider_registry.* = provider.ProviderRegistry.init(std.testing.allocator, logger, event_bus.asEventBus());
    errdefer provider_registry.deinit();
    try provider_registry.registerProvider(.{
        .id = "mock",
        .display_name = "Mock",
        .default_model = .{ .provider_id = "mock", .model_id = "mock-model" },
    }, MockLoopProvider.createClient);

    const tool_registry = try std.testing.allocator.create(tools.ToolRegistry);
    errdefer std.testing.allocator.destroy(tool_registry);
    tool_registry.* = tools.ToolRegistry.init(std.testing.allocator);
    errdefer tool_registry.deinit();

    const tool_runtime = try std.testing.allocator.create(tools.ToolRuntime);
    errdefer std.testing.allocator.destroy(tool_runtime);
    tool_runtime.* = try tools.ToolRuntime.init(std.testing.allocator, tool_registry, logger, runner, event_bus.asEventBus(), root_path);
    errdefer tool_runtime.deinit();

    const config_store = try std.testing.allocator.create(framework.MemoryConfigStore);
    errdefer std.testing.allocator.destroy(config_store);
    config_store.* = framework.MemoryConfigStore.init(std.testing.allocator);
    errdefer config_store.deinit();

    const config_runtime = try std.testing.allocator.create(config.ConfigRuntime);
    errdefer std.testing.allocator.destroy(config_runtime);
    config_runtime.* = try config.ConfigRuntime.init(std.testing.allocator, .{
        .store = config_store.asConfigStore(),
    }, .{});
    errdefer config_runtime.deinit();
    try config_runtime.load();
    var write_attempt = try config_runtime.writeFields(&.{
        .{ .key = config.keys.model_default, .value = .{ .string = "mock/mock-model" } },
    }, false);
    write_attempt.deinit();

    const compaction_policy = try std.testing.allocator.create(session.DisabledCompactionPolicy);
    errdefer std.testing.allocator.destroy(compaction_policy);
    compaction_policy.* = .{};

    const runtime = try std.testing.allocator.create(session.SessionRuntime);
    errdefer std.testing.allocator.destroy(runtime);
    runtime.* = session.SessionRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = logger,
        .task_runner = runner,
        .event_bus = event_bus.asEventBus(),
        .status_index = status_index,
        .config_runtime = config_runtime,
        .agent_registry = agent_registry,
        .provider_registry = provider_registry,
        .tool_runtime = tool_runtime,
        .session_store = session_store,
        .history_service = session.HistoryService.init(session_store),
        .compaction_policy = compaction_policy.asPolicy(),
    });

    const loop_store = try std.testing.allocator.create(state_store_model.FileLoopStateStore);
    errdefer std.testing.allocator.destroy(loop_store);
    loop_store.* = try state_store_model.FileLoopStateStore.init(std.testing.allocator, loop_path);
    errdefer loop_store.deinit();

    const service = try std.testing.allocator.create(LoopService);
    errdefer std.testing.allocator.destroy(service);
    service.* = LoopService.init(.{
        .allocator = std.testing.allocator,
        .logger = logger,
        .event_bus = event_bus.asEventBus(),
        .agent_registry = agent_registry,
        .session_runtime = runtime,
        .session_store = session_store,
        .history_service = session.HistoryService.init(session_store),
        .state_store = loop_store.asLoopStateStore(),
    });
    errdefer service.deinit();
    try service.start();

    return .{
        .tmp_dir = tmp_dir,
        .root_path = root_path,
        .memory_sink = memory_sink,
        .logger = logger,
        .event_bus = event_bus,
        .runner = runner,
        .status_index = status_index,
        .session_store_impl = session_store_impl,
        .session_store = session_store,
        .agent_registry = agent_registry,
        .provider_registry = provider_registry,
        .tool_registry = tool_registry,
        .tool_runtime = tool_runtime,
        .config_store = config_store,
        .config_runtime = config_runtime,
        .compaction_policy = compaction_policy,
        .runtime = runtime,
        .loop_store = loop_store,
        .service = service,
    };
}

const MockLoopProvider = struct {
    const WorkMode = enum {
        incomplete_then_done,
        always_done,
    };

    const VerificationMode = enum {
        verified_first,
        fail_then_verified,
    };

    pub var work_mode: WorkMode = .incomplete_then_done;
    pub var verification_mode: VerificationMode = .verified_first;
    pub var work_call_count: usize = 0;
    pub var verify_call_count: usize = 0;

    fn reset() void {
        work_mode = .incomplete_then_done;
        verification_mode = .verified_first;
        work_call_count = 0;
        verify_call_count = 0;
    }

    fn createClient(allocator: std.mem.Allocator, ctx: provider.ProviderRegistry.ProviderCreateContext) anyerror!provider.ProviderClient {
        const client = try allocator.create(MockClient);
        client.* = .{
            .allocator = allocator,
            .logger = ctx.logger,
            .event_bus = ctx.event_bus,
        };
        return client.asProviderClient();
    }

    const MockClient = struct {
        allocator: std.mem.Allocator,
        logger: ?*framework.Logger,
        event_bus: ?framework.EventBus,

        const vtable = provider.ProviderClient.VTable{
            .stream = streamErased,
            .deinit = deinitErased,
        };

        fn asProviderClient(self: *MockClient) provider.ProviderClient {
            return .{
                .ptr = @ptrCast(self),
                .vtable = &vtable,
            };
        }

        fn stream(self: *MockClient, _: provider.ProviderExecutionContext, request: provider.ProviderRequest, sink: provider.LlmEventSink) !void {
            _ = self;
            const is_oracle = if (request.system_prompt) |prompt_text|
                std.mem.indexOf(u8, prompt_text, "oracle verification") != null
            else
                false;

            const text_value = if (is_oracle) blk: {
                verify_call_count += 1;
                break :blk switch (verification_mode) {
                    .verified_first => "VERIFIED",
                    .fail_then_verified => if (verify_call_count == 1) "REJECTED" else "VERIFIED",
                };
            } else blk: {
                work_call_count += 1;
                break :blk switch (work_mode) {
                    .incomplete_then_done => if (work_call_count == 1) "still working" else "DONE",
                    .always_done => "DONE",
                };
            };

            try sink.onEvent(&provider.ProviderStreamEvent{ .text_delta = .{ .text = text_value } });
            try sink.onEvent(&provider.ProviderStreamEvent{ .completed = .{ .stop_reason = "end_turn" } });
        }

        fn streamErased(ptr: *anyopaque, ctx: provider.ProviderExecutionContext, request: provider.ProviderRequest, sink: provider.LlmEventSink) anyerror!void {
            const self: *MockClient = @ptrCast(@alignCast(ptr));
            return self.stream(ctx, request, sink);
        }

        fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *MockClient = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }
    };
};
