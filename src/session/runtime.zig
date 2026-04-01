const std = @import("std");
const framework = @import("framework");
const config = @import("../config/root.zig");
const agent = @import("../agent/root.zig");
const prompt = @import("../prompt/root.zig");
const provider = @import("../provider/root.zig");
const tools = @import("../tools/root.zig");
const schema = @import("schema.zig");
const session_model = @import("session.zig");
const message_model = @import("message.zig");
const part_model = @import("part.zig");
const store_model = @import("store.zig");
const history_model = @import("history.zig");
const events = @import("events.zig");
const status_model = @import("status.zig");
const compaction_model = @import("compaction.zig");

pub const PromptPartInput = union(enum) {
    text: []const u8,
};

pub const PromptRequest = struct {
    session_id: ?schema.SessionId = null,
    title: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    model: ?provider.ModelRef = null,
    parts: []const PromptPartInput,
};

pub const RunAgentRequest = struct {
    session_id: schema.SessionId,
    agent_id: ?[]const u8 = null,
    category: ?[]const u8 = null,
    model: ?provider.ModelRef = null,
    request_id: []const u8,
    trace_id: ?[]const u8 = null,
};

pub const AgentTask = struct {
    session_id: schema.SessionId,
    agent_id: ?[]const u8 = null,
    category: ?[]const u8 = null,
    model: ?provider.ModelRef = null,
    request_id: []const u8,
    trace_id: ?[]const u8 = null,
};

pub const ToolTask = struct {
    session_id: schema.SessionId,
    message_id: schema.MessageId,
    request_id: []const u8,
    trace_id: ?[]const u8 = null,
    call_id: []const u8,
    tool_name: []const u8,
    input_json: []const u8,
};

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    task_runner: *framework.TaskRunner,
    event_bus: framework.EventBus,
    status_index: *status_model.SessionStatusIndex,
    config_runtime: *config.ConfigRuntime,
    agent_registry: *agent.AgentRegistry,
    provider_registry: *provider.ProviderRegistry,
    tool_runtime: *tools.ToolRuntime,
    session_store: store_model.SessionStore,
    history_service: history_model.HistoryService,
    compaction_policy: compaction_model.CompactionPolicy,
};

pub const SessionRuntime = struct {
    allocator: std.mem.Allocator,
    deps: Dependencies,

    const Self = @This();

    pub fn init(deps: Dependencies) Self {
        return .{
            .allocator = deps.allocator,
            .deps = deps,
        };
    }

    pub fn createSession(self: *Self, title: []const u8, agent_id: []const u8) !session_model.SessionInfo {
        return self.createSessionWithRequest(.{
            .title = title,
            .agent_id = agent_id,
        });
    }

    pub fn createSessionWithRequest(self: *Self, request: session_model.SessionCreateRequest) !session_model.SessionInfo {
        const created = try self.deps.session_store.createSession(self.allocator, request);
        try self.deps.status_index.set(self.allocator, .{
            .session_id = created.id,
            .status = .idle,
        });
        return created;
    }

    pub fn submitPrompt(self: *Self, request: PromptRequest) !history_model.MessageWithParts {
        var session_info = if (request.session_id) |session_id|
            (try self.deps.session_store.getSession(self.allocator, session_id)) orelse return error.SessionNotFound
        else
            try self.createSession(request.title orelse "Session", request.agent_id orelse "build");
        defer session_info.deinit(self.allocator);

        const message_info = try self.deps.session_store.appendMessage(self.allocator, .{
            .session_id = session_info.id,
            .role = .user,
            .agent_id = request.agent_id orelse session_info.agent_id,
            .completed = true,
        });

        const parts = try self.allocator.alloc(part_model.MessagePart, request.parts.len);
        errdefer self.allocator.free(parts);

        for (request.parts, 0..) |input, index| {
            parts[index] = switch (input) {
                .text => |value| try part_model.text(self.allocator, value),
            };
            errdefer for (parts[0 .. index + 1]) |*item| item.deinit(self.allocator);

            var appended = try self.deps.session_store.appendPart(self.allocator, .{
                .session_id = session_info.id,
                .message_id = message_info.id,
                .part = parts[index],
            });
            appended.deinit(self.allocator);
        }

        return .{
            .info = message_info,
            .parts = parts,
        };
    }

    pub fn listHistory(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) ![]history_model.MessageWithParts {
        return self.deps.history_service.list(allocator, session_id);
    }

    pub fn compactSession(self: *Self, session_id: schema.SessionId) !compaction_model.CompactionResult {
        return compaction_model.compactSession(
            self.allocator,
            self.deps.session_store,
            self.deps.history_service,
            session_id,
            self.deps.compaction_policy,
        );
    }

    pub fn forkSession(self: *Self, request: session_model.SessionForkRequest) !session_model.SessionInfo {
        var source = (try self.deps.session_store.getSession(self.allocator, request.source_session_id)) orelse return error.SessionNotFound;
        defer source.deinit(self.allocator);

        const child_title = if (request.title) |value|
            value
        else
            try std.fmt.allocPrint(self.allocator, "{s} (fork)", .{source.title});
        defer if (request.title == null) self.allocator.free(child_title);

        const child = try self.createSessionWithRequest(.{
            .title = child_title,
            .agent_id = request.agent_id orelse source.agent_id,
            .parent_id = source.id,
        });

        const history = try self.deps.history_service.list(self.allocator, request.source_session_id);
        defer {
            for (history) |*item| item.deinit(self.allocator);
            self.allocator.free(history);
        }

        var stop = false;
        for (history) |message| {
            if (stop) break;
            var copied = try self.deps.session_store.appendMessage(self.allocator, .{
                .session_id = child.id,
                .role = message.info.role,
                .parent_id = message.info.id,
                .agent_id = message.info.agent_id,
                .provider_id = message.info.provider_id,
                .model_id = message.info.model_id,
                .completed = message.info.completed,
                .error_code = message.info.error_code,
            });
            defer copied.deinit(self.allocator);

            for (message.parts) |part| {
                var appended = try self.deps.session_store.appendPart(self.allocator, .{
                    .session_id = child.id,
                    .message_id = copied.id,
                    .part = part,
                });
                appended.deinit(self.allocator);
            }

            if (request.up_to_message_id) |cursor| {
                if (std.mem.eql(u8, message.info.id, cursor)) stop = true;
            }
        }

        return child;
    }

    pub fn submitAgentTask(self: *Self, request: RunAgentRequest) !framework.TaskAccepted {
        const owned = try self.allocator.create(AgentTaskJobData);
        errdefer self.allocator.destroy(owned);
        owned.* = try AgentTaskJobData.init(self.allocator, self, request);

        const accepted = try self.deps.task_runner.submitJob("agent.run", request.request_id, .{
            .ptr = @ptrCast(owned),
            .vtable = &.{
                .run = AgentTaskJobData.run,
                .deinit = AgentTaskJobData.deinit,
            },
        });
        try self.deps.status_index.set(self.allocator, .{
            .session_id = request.session_id,
            .status = .running,
            .request_id = request.request_id,
            .task_id = accepted.task_id,
        });
        return accepted;
    }

    pub fn getSessionStatus(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) !?status_model.SessionStatusInfo {
        return self.deps.status_index.get(allocator, session_id);
    }

    pub fn listSessionStatuses(self: *Self, allocator: std.mem.Allocator) ![]status_model.SessionStatusInfo {
        return self.deps.status_index.list(allocator);
    }

    pub fn abortSession(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) !bool {
        var current = (try self.deps.status_index.get(allocator, session_id)) orelse return false;
        defer current.deinit(allocator);

        const task_id = current.task_id orelse return false;
        self.deps.task_runner.cancel(task_id) catch |err| switch (err) {
            error.TaskNotFound, error.InvalidTaskTransition => return false,
            else => return err,
        };
        try self.deps.status_index.set(allocator, .{
            .session_id = session_id,
            .status = .cancelled,
            .request_id = current.request_id,
        });
        return true;
    }

    pub fn runLoop(self: *Self, session_id: schema.SessionId) ![]u8 {
        return self.runLoopWithRequest(.{
            .session_id = session_id,
            .request_id = "agent_loop",
        });
    }

    pub fn runLoopWithRequest(self: *Self, request: RunAgentRequest) ![]u8 {
        var summary = try framework.SummaryTrace.begin(self.allocator, self.deps.logger, "SessionRuntime.RunLoop", 1000);
        defer summary.deinit();
        var method = try framework.MethodTrace.begin(self.allocator, self.deps.logger, "SessionRuntime.RunLoop", request.session_id, 1000);
        defer method.deinit();

        try self.publishStatus(request.session_id, .running, request.request_id, null);

        var latest_text: ?[]u8 = null;
        errdefer if (latest_text) |value| self.allocator.free(value);

        while (true) {
            const turn = self.runSingleTurn(request) catch |err| {
                try self.publishStatus(request.session_id, .failed, request.request_id, null);
                summary.finishError(.system);
                method.finishError(@errorName(err), null, false);
                return err;
            };

            if (latest_text) |value| self.allocator.free(value);
            latest_text = turn.final_text;

            if (!turn.needs_follow_up) {
                try self.publishStatus(request.session_id, .completed, request.request_id, null);
                summary.finishSuccess();
                method.finishSuccess(turn.final_text orelse "", false);
                break;
            }
        }

        return latest_text orelse error.AgentLoopProducedNoResult;
    }

    fn runSingleTurn(self: *Self, request: RunAgentRequest) !TurnResult {
        _ = try self.compactSession(request.session_id);
        const profile = try self.resolveProfile(request.agent_id);
        var assembled = try prompt.assemble(self.allocator, profile, null);
        defer assembled.deinit(self.allocator);

        var category_plan = if (request.category) |category_name|
            try self.resolveCategoryPlan(category_name)
        else
            null;
        defer if (category_plan) |*plan| plan.deinit(self.allocator);
        if (category_plan) |plan| {
            if (plan.prompt_append) |prompt_append| {
                const combined = try std.mem.join(self.allocator, "\n\n", &.{ assembled.system_prompt, prompt_append });
                self.allocator.free(assembled.system_prompt);
                assembled.system_prompt = combined;
            }
        }

        var model_ref = try self.resolveModel(profile, request.model, if (category_plan) |plan| plan.selected_model else null);
        defer model_ref.deinit(self.allocator);

        const client = (try self.deps.provider_registry.makeClient(model_ref.asRef())) orelse return error.ProviderClientUnavailable;
        defer client.deinit(self.allocator);

        const history = try self.deps.history_service.renderConversation(self.allocator, request.session_id);
        defer {
            for (history) |*message| message.deinit(self.allocator);
            self.allocator.free(history);
        }
        const provider_messages = try renderProviderMessages(self.allocator, history);
        defer freeProviderMessages(self.allocator, provider_messages);
        const provider_tools = try self.renderTools(profile);
        defer freeProviderTools(self.allocator, provider_tools);

        var assistant_message = try self.deps.session_store.appendMessage(self.allocator, .{
            .session_id = request.session_id,
            .role = .assistant,
            .agent_id = profile.id,
            .provider_id = model_ref.value.provider_id,
            .model_id = model_ref.value.model_id,
            .completed = false,
        });
        defer assistant_message.deinit(self.allocator);

        const after_seq = self.deps.event_bus.latestSeq();
        const tool_call_sub = try events.subscribeToolCallEvents(self.deps.event_bus, after_seq);
        defer self.deps.event_bus.unsubscribe(tool_call_sub) catch {};
        const tool_result_sub = try events.subscribeToolResultEvents(self.deps.event_bus, after_seq);
        defer self.deps.event_bus.unsubscribe(tool_result_sub) catch {};

        var step = try framework.StepTrace.begin(self.allocator, self.deps.logger, "agent/provider", "stream", 1000);
        defer step.deinit();

        var sink_state = ProviderSinkState{
            .allocator = self.allocator,
            .runtime = self,
            .session_id = request.session_id,
            .message_id = assistant_message.id,
            .request_id = request.request_id,
            .trace_id = request.trace_id,
        };
        defer sink_state.deinit();

        const sink = provider.LlmEventSink{
            .ptr = @ptrCast(&sink_state),
            .on_event = ProviderSinkState.onEvent,
        };

        try client.stream(.{
            .allocator = self.allocator,
            .logger = self.deps.logger,
            .event_bus = self.deps.event_bus,
            .request_id = request.request_id,
            .session_id = request.session_id,
            .trace_id = request.trace_id,
        }, .{
            .request_id = request.request_id,
            .session_id = request.session_id,
            .trace_id = request.trace_id,
            .model = model_ref.asRef(),
            .system_prompt = assembled.system_prompt,
            .messages = provider_messages,
            .tools = provider_tools,
            .max_tokens = 1024,
        }, sink);

        if (sink_state.failed) |_| {
            step.finish("PROVIDER_FAILED");
            return error.ProviderOperationFailed;
        }
        step.finish(null);

        const tool_calls = try events.pollToolCallEvents(self.allocator, self.deps.event_bus, tool_call_sub, 16);
        defer freeToolCallEvents(self.allocator, tool_calls);

        if (tool_calls.len == 0) {
            assistant_message.completed = true;
            try self.deps.session_store.updateMessage(self.allocator, assistant_message);
            return .{
                .needs_follow_up = false,
                .final_text = try gatherAssistantText(self.allocator, self.deps.history_service, request.session_id, assistant_message.id),
            };
        }

        try self.publishStatus(request.session_id, .waiting_tool, request.request_id, null);

        for (tool_calls) |tool_call| {
            var call_part = try part_model.toolCall(self.allocator, tool_call.call_id, tool_call.tool_name, tool_call.input_json);
            defer call_part.deinit(self.allocator);
            var appended_call = try self.deps.session_store.appendPart(self.allocator, .{
                .session_id = request.session_id,
                .message_id = assistant_message.id,
                .part = call_part,
            });
            appended_call.deinit(self.allocator);

            _ = try self.submitToolTask(.{
                .session_id = request.session_id,
                .message_id = assistant_message.id,
                .request_id = request.request_id,
                .trace_id = request.trace_id,
                .call_id = tool_call.call_id,
                .tool_name = tool_call.tool_name,
                .input_json = tool_call.input_json,
            });

            var tool_result = try waitForToolResult(self.allocator, self.deps.event_bus, tool_result_sub, tool_call.call_id);
            defer tool_result.deinit(self.allocator);

            if (!tool_result.ok) return error.ToolExecutionFailed;

            var result_part = try part_model.toolResult(
                self.allocator,
                tool_result.call_id,
                tool_result.tool_name,
                tool_result.output_text,
                tool_result.metadata_json,
            );
            defer result_part.deinit(self.allocator);
            var appended_result = try self.deps.session_store.appendPart(self.allocator, .{
                .session_id = request.session_id,
                .message_id = assistant_message.id,
                .part = result_part,
            });
            appended_result.deinit(self.allocator);
        }

        assistant_message.completed = true;
        try self.deps.session_store.updateMessage(self.allocator, assistant_message);
        return .{
            .needs_follow_up = true,
            .final_text = null,
        };
    }

    fn resolveProfile(self: *Self, requested_id: ?[]const u8) !*const agent.AgentProfile {
        if (requested_id) |agent_id| {
            return self.deps.agent_registry.get(agent_id) orelse error.AgentProfileNotFound;
        }

        var effective = try self.deps.config_runtime.effective(self.allocator);
        defer effective.deinit(self.allocator);
        return self.deps.agent_registry.get(effective.default_agent) orelse self.deps.agent_registry.defaultPrimary() orelse error.AgentProfileNotFound;
    }

    fn resolveModel(self: *Self, profile: *const agent.AgentProfile, requested: ?provider.ModelRef, category_selected: ?provider.ModelRef) !OwnedModelRef {
        if (requested) |model| return try OwnedModelRef.init(self.allocator, model.provider_id, model.model_id);
        if (category_selected) |model| return try OwnedModelRef.init(self.allocator, model.provider_id, model.model_id);
        if (profile.default_model) |model| {
            if (self.deps.provider_registry.isModelReady(model)) {
                return try OwnedModelRef.init(self.allocator, model.provider_id, model.model_id);
            }
        }

        var effective = try self.deps.config_runtime.effective(self.allocator);
        defer effective.deinit(self.allocator);
        if (effective.model.default_model) |model| {
            if (self.deps.provider_registry.isModelReady(model)) {
                return try OwnedModelRef.init(self.allocator, model.provider_id, model.model_id);
            }
        }

        const default_model = self.deps.provider_registry.defaultModel() orelse return error.ProviderModelUnavailable;
        return try OwnedModelRef.init(self.allocator, default_model.provider_id, default_model.model_id);
    }

    fn resolveCategoryPlan(self: *Self, category_name: []const u8) !agent.CategoryExecutionPlan {
        var resolver = agent.CategoryResolver.init(self.allocator, self.deps.provider_registry);
        return resolver.resolveByName(category_name);
    }

    fn renderTools(self: *Self, profile: *const agent.AgentProfile) ![]provider.ProviderToolDefinition {
        const defs = self.deps.tool_runtime.registry.list();
        var count: usize = 0;
        for (defs) |def| {
            if (toolAllowed(profile.allow_tools, def.id)) count += 1;
        }

        const rendered = try self.allocator.alloc(provider.ProviderToolDefinition, count);
        errdefer self.allocator.free(rendered);

        var index: usize = 0;
        for (defs) |def| {
            if (!toolAllowed(profile.allow_tools, def.id)) continue;
            rendered[index] = .{
                .name = try self.allocator.dupe(u8, def.id),
                .description = try self.allocator.dupe(u8, def.description),
                .input_schema_json = try self.allocator.dupe(u8, def.input_schema_json),
            };
            index += 1;
        }
        return rendered;
    }

    fn submitToolTask(self: *Self, task: ToolTask) !framework.TaskAccepted {
        const owned = try self.allocator.create(ToolTaskJobData);
        errdefer self.allocator.destroy(owned);
        owned.* = try ToolTaskJobData.init(self.allocator, self, task);

        return self.deps.task_runner.submitJob(task.tool_name, task.request_id, .{
            .ptr = @ptrCast(owned),
            .vtable = &.{
                .run = ToolTaskJobData.run,
                .deinit = ToolTaskJobData.deinit,
            },
        });
    }

    fn publishStatus(self: *Self, session_id: []const u8, status: status_model.SessionStatus, request_id: []const u8, task_id: ?[]const u8) !void {
        try self.deps.status_index.set(self.allocator, .{
            .session_id = session_id,
            .status = status,
            .request_id = request_id,
            .task_id = task_id,
        });
        try events.publishSessionStatusEvent(self.allocator, self.deps.event_bus, .{
            .session_id = session_id,
            .status = status.asText(),
            .request_id = request_id,
        });
    }
};

const TurnResult = struct {
    needs_follow_up: bool,
    final_text: ?[]u8 = null,
};

const OwnedModelRef = struct {
    allocator: std.mem.Allocator,
    value: provider.ModelRef,

    fn init(allocator: std.mem.Allocator, provider_id: []const u8, model_id: []const u8) !OwnedModelRef {
        return .{
            .allocator = allocator,
            .value = .{
                .provider_id = try allocator.dupe(u8, provider_id),
                .model_id = try allocator.dupe(u8, model_id),
            },
        };
    }

    fn asRef(self: OwnedModelRef) provider.ModelRef {
        return self.value;
    }

    fn deinit(self: *OwnedModelRef, allocator: std.mem.Allocator) void {
        allocator.free(self.value.provider_id);
        allocator.free(self.value.model_id);
    }
};

const ProviderSinkState = struct {
    allocator: std.mem.Allocator,
    runtime: *SessionRuntime,
    session_id: []const u8,
    message_id: []const u8,
    request_id: []const u8,
    trace_id: ?[]const u8,
    failed: ?provider.ProviderFailure = null,

    fn deinit(self: *ProviderSinkState) void {
        if (self.failed) |failure| {
            self.allocator.free(failure.code);
            self.allocator.free(failure.message);
        }
    }

    fn onEvent(ptr: *anyopaque, event: *const provider.ProviderStreamEvent) anyerror!void {
        const self: *ProviderSinkState = @ptrCast(@alignCast(ptr));
        switch (event.*) {
            .text_delta => |value| {
                var part = try part_model.text(self.allocator, value.text);
                defer part.deinit(self.allocator);
                var appended = try self.runtime.deps.session_store.appendPart(self.allocator, .{
                    .session_id = self.session_id,
                    .message_id = self.message_id,
                    .part = part,
                });
                appended.deinit(self.allocator);
                try publishProviderEvent(self.allocator, self.runtime.deps.event_bus, events.PROVIDER_RESPONSE_DELTA_TOPIC, self.request_id, self.session_id, self.trace_id);
            },
            .reasoning_delta => |value| {
                var part = try part_model.reasoning(self.allocator, value.text);
                defer part.deinit(self.allocator);
                var appended = try self.runtime.deps.session_store.appendPart(self.allocator, .{
                    .session_id = self.session_id,
                    .message_id = self.message_id,
                    .part = part,
                });
                appended.deinit(self.allocator);
            },
            .completed => {
                try publishProviderEvent(self.allocator, self.runtime.deps.event_bus, events.PROVIDER_RESPONSE_COMPLETED_TOPIC, self.request_id, self.session_id, self.trace_id);
            },
            .failed => |failure| {
                self.failed = .{
                    .code = try self.allocator.dupe(u8, failure.code),
                    .message = try self.allocator.dupe(u8, failure.message),
                    .retryable = failure.retryable,
                };
                try publishProviderEvent(self.allocator, self.runtime.deps.event_bus, events.PROVIDER_RESPONSE_FAILED_TOPIC, self.request_id, self.session_id, self.trace_id);
            },
            else => {},
        }
    }
};

const AgentTaskJobData = struct {
    runtime: *SessionRuntime,
    request: RunAgentRequest,

    fn init(allocator: std.mem.Allocator, runtime: *SessionRuntime, request: RunAgentRequest) !AgentTaskJobData {
        return .{
            .runtime = runtime,
            .request = .{
                .session_id = try allocator.dupe(u8, request.session_id),
                .agent_id = if (request.agent_id) |agent_id| try allocator.dupe(u8, agent_id) else null,
                .category = if (request.category) |category| try allocator.dupe(u8, category) else null,
                .model = if (request.model) |model| .{
                    .provider_id = try allocator.dupe(u8, model.provider_id),
                    .model_id = try allocator.dupe(u8, model.model_id),
                } else null,
                .request_id = try allocator.dupe(u8, request.request_id),
                .trace_id = if (request.trace_id) |trace_id| try allocator.dupe(u8, trace_id) else null,
            },
        };
    }

    fn run(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *AgentTaskJobData = @ptrCast(@alignCast(ptr));
        const final_text = try self.runtime.runLoopWithRequest(self.request);
        defer allocator.free(final_text);
        return std.fmt.allocPrint(allocator, "{{\"final_text\":\"{s}\"}}", .{final_text});
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *AgentTaskJobData = @ptrCast(@alignCast(ptr));
        allocator.free(self.request.session_id);
        if (self.request.agent_id) |agent_id| allocator.free(agent_id);
        if (self.request.category) |category| allocator.free(category);
        if (self.request.model) |model| {
            allocator.free(model.provider_id);
            allocator.free(model.model_id);
        }
        allocator.free(self.request.request_id);
        if (self.request.trace_id) |trace_id| allocator.free(trace_id);
        allocator.destroy(self);
    }
};

const ToolTaskJobData = struct {
    runtime: *SessionRuntime,
    task: ToolTask,

    fn init(allocator: std.mem.Allocator, runtime: *SessionRuntime, task: ToolTask) !ToolTaskJobData {
        return .{
            .runtime = runtime,
            .task = .{
                .session_id = try allocator.dupe(u8, task.session_id),
                .message_id = try allocator.dupe(u8, task.message_id),
                .request_id = try allocator.dupe(u8, task.request_id),
                .trace_id = if (task.trace_id) |trace_id| try allocator.dupe(u8, trace_id) else null,
                .call_id = try allocator.dupe(u8, task.call_id),
                .tool_name = try allocator.dupe(u8, task.tool_name),
                .input_json = try allocator.dupe(u8, task.input_json),
            },
        };
    }

    fn run(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *ToolTaskJobData = @ptrCast(@alignCast(ptr));

        var step = try framework.StepTrace.begin(allocator, self.runtime.deps.logger, "agent/tool", self.task.tool_name, 1000);
        defer step.deinit();

        const params = parseToolInput(allocator, self.task.input_json) catch |err| {
            try events.publishToolResultEvent(allocator, self.runtime.deps.event_bus, .{
                .request_id = self.task.request_id,
                .session_id = self.task.session_id,
                .trace_id = self.task.trace_id,
                .call_id = self.task.call_id,
                .tool_name = self.task.tool_name,
                .output_text = "",
                .metadata_json = "{}",
                .ok = false,
                .error_code = @errorName(err),
            });
            step.finish("TOOL_INPUT_INVALID");
            return err;
        };
        defer freeValidationFields(allocator, params);

        const command_ctx = framework.CommandContext{
            .allocator = allocator,
            .request = .{
                .request_id = self.task.request_id,
                .trace_id = self.task.trace_id,
                .source = .service,
                .authority = .public,
            },
            .command_id = self.task.tool_name,
            .command_method = self.task.tool_name,
            .command_description = "",
            .logger = self.runtime.deps.logger.child("runtime").child("tool").child(self.task.tool_name),
            .validated_params = params,
        };

        const definition = self.runtime.deps.tool_runtime.registry.get(self.task.tool_name) orelse return error.ToolNotFound;
        var result = self.runtime.deps.tool_runtime.executeById(&command_ctx, definition, .{
            .session_id = self.task.session_id,
            .message_id = self.task.message_id,
            .call_id = self.task.call_id,
        }) catch |err| {
            try events.publishToolResultEvent(allocator, self.runtime.deps.event_bus, .{
                .request_id = self.task.request_id,
                .session_id = self.task.session_id,
                .trace_id = self.task.trace_id,
                .call_id = self.task.call_id,
                .tool_name = self.task.tool_name,
                .output_text = "",
                .metadata_json = "{}",
                .ok = false,
                .error_code = @errorName(err),
            });
            step.finish("TOOL_FAILED");
            return err;
        };
        defer result.deinit(allocator);

        try events.publishToolResultEvent(allocator, self.runtime.deps.event_bus, .{
            .request_id = self.task.request_id,
            .session_id = self.task.session_id,
            .trace_id = self.task.trace_id,
            .call_id = self.task.call_id,
            .tool_name = self.task.tool_name,
            .output_text = result.output_text,
            .metadata_json = result.metadata_json,
            .ok = true,
        });
        step.finish(null);

        return result.toJson(allocator);
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *ToolTaskJobData = @ptrCast(@alignCast(ptr));
        allocator.free(self.task.session_id);
        allocator.free(self.task.message_id);
        allocator.free(self.task.request_id);
        if (self.task.trace_id) |trace_id| allocator.free(trace_id);
        allocator.free(self.task.call_id);
        allocator.free(self.task.tool_name);
        allocator.free(self.task.input_json);
        allocator.destroy(self);
    }
};

fn renderProviderMessages(allocator: std.mem.Allocator, messages: []const history_model.ConversationMessage) ![]provider.ProviderMessage {
    const rendered = try allocator.alloc(provider.ProviderMessage, messages.len);
    errdefer allocator.free(rendered);

    for (messages, 0..) |message, index| {
        rendered[index] = .{
            .role = if (message.role == .user) .user else .assistant,
            .content = try renderConversationMessage(allocator, message),
        };
    }

    return rendered;
}

fn renderConversationMessage(allocator: std.mem.Allocator, message: history_model.ConversationMessage) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);

    for (message.parts, 0..) |part, index| {
        if (index > 0) try writer.writeByte('\n');
        switch (part) {
            .text => |value| try writer.writeAll(value),
            .reasoning => |value| try writer.print("[reasoning]{s}", .{value}),
            .tool_call => |value| try writer.print("[tool_call {s}]{s}", .{ value.tool_name, value.input_json }),
            .tool_result => |value| try writer.print("[tool_result {s}]{s}", .{ value.tool_name, value.output_text }),
            .system_reminder => |value| try writer.print("[system]{s}", .{value}),
            .compaction_summary => |value| try writer.print("[compaction_summary {s} count={d}]{s}", .{ value.compacted_until_message_id, value.original_message_count, value.summary }),
            .subtask => |value| try writer.print("[subtask {s} {s} {s}]{s}", .{ value.child_session_id, value.agent_id, value.status, value.summary }),
            .subtask_aggregate => |value| try writer.print("[subtask_aggregate {s} {d}/{d}]{s}", .{ value.batch_id, value.success_count, value.failure_count, value.summary }),
        }
    }

    return allocator.dupe(u8, out.items);
}

fn freeProviderMessages(allocator: std.mem.Allocator, messages: []provider.ProviderMessage) void {
    for (messages) |message| allocator.free(message.content);
    allocator.free(messages);
}

fn freeProviderTools(allocator: std.mem.Allocator, items: []provider.ProviderToolDefinition) void {
    for (items) |tool_def| {
        allocator.free(tool_def.name);
        allocator.free(tool_def.description);
        allocator.free(tool_def.input_schema_json);
    }
    allocator.free(items);
}

fn toolAllowed(allowed: []const []const u8, id: []const u8) bool {
    if (allowed.len == 0) return true;
    for (allowed) |item| {
        if (std.mem.eql(u8, item, id)) return true;
        if (std.mem.endsWith(u8, item, ".*")) {
            const prefix = item[0 .. item.len - 1];
            if (std.mem.startsWith(u8, id, prefix)) return true;
        }
    }
    return false;
}

fn parseToolInput(allocator: std.mem.Allocator, json_text: []const u8) ![]framework.ValidationField {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolInput;

    var fields: std.ArrayListUnmanaged(framework.ValidationField) = .empty;
    errdefer {
        for (fields.items) |field| field.deinit(allocator);
        fields.deinit(allocator);
    }

    var iterator = parsed.value.object.iterator();
    while (iterator.next()) |entry| {
        try fields.append(allocator, .{
            .key = try allocator.dupe(u8, entry.key_ptr.*),
            .value = try framework.ConfigValueParser.parseJsonStdValue(allocator, valueKindFor(entry.value_ptr.*), entry.value_ptr.*),
        });
    }
    return fields.toOwnedSlice(allocator);
}

fn valueKindFor(value: std.json.Value) framework.ValueKind {
    return switch (value) {
        .string => .string,
        .integer => .integer,
        .bool => .boolean,
        .float => .float,
        .number_string => .float,
        .object => .object,
        .array => .array,
        .null => .string,
    };
}

fn freeValidationFields(allocator: std.mem.Allocator, fields: []framework.ValidationField) void {
    for (fields) |field| field.deinit(allocator);
    allocator.free(fields);
}

fn gatherAssistantText(
    allocator: std.mem.Allocator,
    history_service: history_model.HistoryService,
    session_id: schema.SessionId,
    message_id: schema.MessageId,
) ![]u8 {
    const history = try history_service.list(allocator, session_id);
    defer {
        for (history) |*message| message.deinit(allocator);
        allocator.free(history);
    }

    for (history) |message| {
        if (!std.mem.eql(u8, message.info.id, message_id)) continue;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        const writer = out.writer(allocator);
        for (message.parts) |part| {
            if (part == .text) try writer.writeAll(part.text.text);
        }
        return allocator.dupe(u8, out.items);
    }

    return allocator.dupe(u8, "");
}

fn publishProviderEvent(allocator: std.mem.Allocator, event_bus: framework.EventBus, topic: []const u8, request_id: []const u8, session_id: []const u8, trace_id: ?[]const u8) !void {
    try events.publishProviderResponseEvent(allocator, event_bus, .{
        .topic = topic,
        .request_id = request_id,
        .session_id = session_id,
        .trace_id = trace_id,
    });
}

fn waitForToolResult(allocator: std.mem.Allocator, event_bus: framework.EventBus, subscription_id: u64, call_id: []const u8) !events.ToolResultEvent {
    while (true) {
        const results = try events.pollToolResultEvents(allocator, event_bus, subscription_id, 8);
        defer freeToolResultEvents(allocator, results);
        for (results) |result| {
            if (std.mem.eql(u8, result.call_id, call_id)) return try result.clone(allocator);
        }
        std.Thread.sleep(5 * std.time.ns_per_ms);
    }
}

fn freeToolCallEvents(allocator: std.mem.Allocator, items: []events.ToolCallEvent) void {
    for (items) |item| {
        allocator.free(item.call_id);
        allocator.free(item.tool_name);
        allocator.free(item.input_json);
        if (item.request_id) |request_id| allocator.free(request_id);
        if (item.session_id) |session_id| allocator.free(session_id);
        if (item.trace_id) |trace_id| allocator.free(trace_id);
    }
    allocator.free(items);
}

fn freeToolResultEvents(allocator: std.mem.Allocator, items: []events.ToolResultEvent) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn registerRunAgentCommand(runtime: *SessionRuntime, framework_app: *framework.AppContext) !void {
    const params = [_]framework.FieldDefinition{
        .{ .key = "session_id", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string } },
        .{ .key = "agent_id", .required = false, .value_kind = .string },
        .{ .key = "category", .required = false, .value_kind = .string },
    };

    try framework_app.registerCommand(.{
        .id = "agent.run",
        .method = "agent.run",
        .description = "Submit an agent execution task",
        .params = params[0..],
        .handler = struct {
            fn call(ctx: *const framework.CommandContext) anyerror![]const u8 {
                const runtime_ptr: *SessionRuntime = @ptrCast(@alignCast(ctx.user_data.?));
                const session_id = ctx.param("session_id").?.value.string;
                const agent_id = if (ctx.param("agent_id")) |field| field.value.string else null;
                const category = if (ctx.param("category")) |field| field.value.string else null;
                const accepted = try runtime_ptr.submitAgentTask(.{
                    .session_id = session_id,
                    .agent_id = agent_id,
                    .category = category,
                    .request_id = ctx.request.request_id,
                    .trace_id = ctx.request.trace_id,
                });
                return std.fmt.allocPrint(ctx.allocator, "{{\"task_id\":\"{s}\",\"state\":\"{s}\"}}", .{ accepted.task_id, accepted.state });
            }
        }.call,
        .user_data = runtime,
    });
}

test "session runtime maps agent task lifecycle into framework task states" {
    var fixture = try makeRuntimeFixture();
    defer fixture.deinit();

    MockProvider.reset();

    var session_info = try fixture.runtime.createSession("Loop", "build");
    defer session_info.deinit(std.testing.allocator);
    var prompt_message = try fixture.runtime.submitPrompt(.{
        .session_id = session_info.id,
        .parts = &.{.{ .text = "hello" }},
    });
    defer prompt_message.deinit(std.testing.allocator);

    const accepted = try fixture.runtime.submitAgentTask(.{
        .session_id = session_info.id,
        .request_id = "req_agent_01",
    });
    var summary = try fixture.runner.waitForCompletion(std.testing.allocator, accepted.task_id, 5000);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(framework.TaskState.succeeded, summary.state);
    try std.testing.expect(summary.result_json != null);
}

test "session runtime completes single tool-use loop and stores final response" {
    var fixture = try makeRuntimeFixture();
    defer fixture.deinit();

    MockProvider.reset();

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.root_path, "tool-read.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("tool-payload");
    }
    defer std.fs.cwd().deleteFile(file_path) catch {};
    MockProvider.tool_path = "tool-read.txt";

    var session_info = try fixture.runtime.createSession("Loop", "build");
    defer session_info.deinit(std.testing.allocator);
    var prompt_message = try fixture.runtime.submitPrompt(.{
        .session_id = session_info.id,
        .parts = &.{.{ .text = "read the file" }},
    });
    defer prompt_message.deinit(std.testing.allocator);

    const final_text = try fixture.runtime.runLoopWithRequest(.{
        .session_id = session_info.id,
        .request_id = "req_agent_loop_01",
    });
    defer std.testing.allocator.free(final_text);

    try std.testing.expectEqualStrings("done after tool", final_text);

    const history = try fixture.runtime.listHistory(std.testing.allocator, session_info.id);
    defer {
        for (history) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(history);
    }

    var saw_tool_call = false;
    var saw_tool_result = false;
    for (history) |message| {
        for (message.parts) |part| {
            switch (part) {
                .tool_call => saw_tool_call = true,
                .tool_result => saw_tool_result = true,
                else => {},
            }
        }
    }
    try std.testing.expect(saw_tool_call);
    try std.testing.expect(saw_tool_result);
}

test "session runtime failure path ends agent task in failed state and emits summary trace" {
    var fixture = try makeRuntimeFixture();
    defer fixture.deinit();

    MockProvider.reset();
    MockProvider.fail_first = true;

    var session_info = try fixture.runtime.createSession("Loop", "build");
    defer session_info.deinit(std.testing.allocator);
    var prompt_message = try fixture.runtime.submitPrompt(.{
        .session_id = session_info.id,
        .parts = &.{.{ .text = "fail" }},
    });
    defer prompt_message.deinit(std.testing.allocator);

    const accepted = try fixture.runtime.submitAgentTask(.{
        .session_id = session_info.id,
        .request_id = "req_agent_fail_01",
    });
    var summary = try fixture.runner.waitForCompletion(std.testing.allocator, accepted.task_id, 5000);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(framework.TaskState.failed, summary.state);
    try std.testing.expect(findSummaryTrace(fixture.memory_sink, "S"));
}

test "session runtime exposes category routing to loop without changing agent identity" {
    var fixture = try makeRuntimeFixture();
    defer fixture.deinit();

    MockProvider.reset();

    var session_info = try fixture.runtime.createSession("Loop", "build");
    defer session_info.deinit(std.testing.allocator);
    var prompt_message = try fixture.runtime.submitPrompt(.{
        .session_id = session_info.id,
        .parts = &.{.{ .text = "visual task" }},
    });
    defer prompt_message.deinit(std.testing.allocator);

    const final_text = try fixture.runtime.runLoopWithRequest(.{
        .session_id = session_info.id,
        .request_id = "req_agent_category_01",
        .category = "visual",
    });
    defer std.testing.allocator.free(final_text);

    try std.testing.expectEqualStrings("done after tool", final_text);
    try std.testing.expectEqualStrings("mock", MockProvider.lastModelProvider());
    try std.testing.expect(std.mem.indexOf(u8, MockProvider.lastSystemPrompt(), "visual detail") != null);
}

test "session runtime fork copies history and preserves parent lineage" {
    var fixture = try makeRuntimeFixture();
    defer fixture.deinit();

    var source = try fixture.runtime.createSession("Source", "build");
    defer source.deinit(std.testing.allocator);

    var first = try fixture.runtime.submitPrompt(.{
        .session_id = source.id,
        .parts = &.{.{ .text = "alpha" }},
    });
    defer first.deinit(std.testing.allocator);

    var second = try fixture.runtime.submitPrompt(.{
        .session_id = source.id,
        .parts = &.{.{ .text = "beta" }},
    });
    defer second.deinit(std.testing.allocator);

    var forked = try fixture.runtime.forkSession(.{
        .source_session_id = source.id,
        .up_to_message_id = second.info.id,
    });
    defer forked.deinit(std.testing.allocator);

    try std.testing.expect(forked.parent_id != null);
    try std.testing.expectEqualStrings(source.id, forked.parent_id.?);

    const history = try fixture.runtime.listHistory(std.testing.allocator, forked.id);
    defer {
        for (history) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(history);
    }

    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expect(history[0].info.parent_id != null);
    try std.testing.expectEqualStrings(first.info.id, history[0].info.parent_id.?);
    try std.testing.expect(history[1].info.parent_id != null);
    try std.testing.expectEqualStrings(second.info.id, history[1].info.parent_id.?);
}

const RuntimeFixture = struct {
    tmp_dir: std.testing.TmpDir,
    root_path: []u8,
    memory_sink: *framework.MemorySink,
    logger: *framework.Logger,
    event_bus: *framework.MemoryEventBus,
    runner: *framework.TaskRunner,
    status_index: *status_model.SessionStatusIndex,
    session_store: *store_model.FileSessionStore,
    agent_registry: *agent.AgentRegistry,
    provider_registry: *provider.ProviderRegistry,
    tool_registry: *tools.ToolRegistry,
    tool_runtime: *tools.ToolRuntime,
    config_store: *framework.MemoryConfigStore,
    config_runtime: *config.ConfigRuntime,
    compaction_policy: *compaction_model.DisabledCompactionPolicy,
    runtime: SessionRuntime,

    fn deinit(self: *RuntimeFixture) void {
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
        self.session_store.deinit();
        std.testing.allocator.destroy(self.session_store);
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

fn makeRuntimeFixture() !RuntimeFixture {
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    errdefer std.testing.allocator.free(root_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sessions" });
    defer std.testing.allocator.free(store_path);

    const memory_sink = try std.testing.allocator.create(framework.MemorySink);
    errdefer std.testing.allocator.destroy(memory_sink);
    memory_sink.* = framework.MemorySink.init(std.testing.allocator, 256);
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

    const status_index = try std.testing.allocator.create(status_model.SessionStatusIndex);
    errdefer std.testing.allocator.destroy(status_index);
    status_index.* = status_model.SessionStatusIndex.init(std.testing.allocator);
    errdefer status_index.deinit();

    const session_store = try std.testing.allocator.create(store_model.FileSessionStore);
    errdefer std.testing.allocator.destroy(session_store);
    session_store.* = try store_model.FileSessionStore.init(std.testing.allocator, store_path, event_bus.asEventBus(), logger);
    errdefer session_store.deinit();

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
    }, MockProvider.createClient);

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
    var attempt = try config_runtime.writeFields(&.{
        .{ .key = config.keys.model_default, .value = .{ .string = "mock/mock-model" } },
    }, false);
    attempt.deinit();

    const compaction_policy = try std.testing.allocator.create(compaction_model.DisabledCompactionPolicy);
    errdefer std.testing.allocator.destroy(compaction_policy);
    compaction_policy.* = .{};

    const runtime = SessionRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = logger,
        .task_runner = runner,
        .event_bus = event_bus.asEventBus(),
        .status_index = status_index,
        .config_runtime = config_runtime,
        .agent_registry = agent_registry,
        .provider_registry = provider_registry,
        .tool_runtime = tool_runtime,
        .session_store = session_store.asSessionStore(),
        .history_service = history_model.HistoryService.init(session_store.asSessionStore()),
        .compaction_policy = compaction_policy.asPolicy(),
    });

    return .{
        .tmp_dir = tmp_dir,
        .root_path = root_path,
        .memory_sink = memory_sink,
        .logger = logger,
        .event_bus = event_bus,
        .runner = runner,
        .status_index = status_index,
        .session_store = session_store,
        .agent_registry = agent_registry,
        .provider_registry = provider_registry,
        .tool_registry = tool_registry,
        .tool_runtime = tool_runtime,
        .config_store = config_store,
        .config_runtime = config_runtime,
        .compaction_policy = compaction_policy,
        .runtime = runtime,
    };
}

const MockProvider = struct {
    pub var fail_first: bool = false;
    pub var tool_path: []const u8 = "";
    pub var call_count: usize = 0;
    var last_model_provider_storage: [64]u8 = undefined;
    var last_model_provider_len: usize = 0;
    var last_system_prompt_storage: [4096]u8 = undefined;
    var last_system_prompt_len: usize = 0;

    fn reset() void {
        fail_first = false;
        call_count = 0;
        tool_path = "";
        last_model_provider_len = 0;
        last_system_prompt_len = 0;
    }

    fn lastModelProvider() []const u8 {
        return last_model_provider_storage[0..last_model_provider_len];
    }

    fn lastSystemPrompt() []const u8 {
        return last_system_prompt_storage[0..last_system_prompt_len];
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

        fn stream(self: *MockClient, ctx: provider.ProviderExecutionContext, request: provider.ProviderRequest, sink: provider.LlmEventSink) !void {
            _ = self;
            call_count += 1;
            last_model_provider_len = @min(last_model_provider_storage.len, request.model.provider_id.len);
            @memcpy(last_model_provider_storage[0..last_model_provider_len], request.model.provider_id[0..last_model_provider_len]);
            if (request.system_prompt) |system_prompt| {
                last_system_prompt_len = @min(last_system_prompt_storage.len, system_prompt.len);
                @memcpy(last_system_prompt_storage[0..last_system_prompt_len], system_prompt[0..last_system_prompt_len]);
            } else {
                last_system_prompt_len = 0;
            }

            if (fail_first and call_count == 1) {
                const failed = provider.ProviderStreamEvent{
                    .failed = .{
                        .code = framework.core.error_model.code.PROVIDER_OPERATION_FAILED,
                        .message = "mock failure",
                        .retryable = false,
                    },
                };
                try sink.onEvent(&failed);
                return;
            }

            var saw_tool_result = false;
            for (request.messages) |message| {
                if (std.mem.indexOf(u8, message.content, "[tool_result read_file]") != null) {
                    saw_tool_result = true;
                    break;
                }
            }

            if (!saw_tool_result and tool_path.len != 0) {
                const started = provider.ProviderStreamEvent{
                    .tool_call_started = .{
                        .call_id = "call_01",
                        .tool_name = "read_file",
                    },
                };
                try sink.onEvent(&started);

                const input_json = try std.fmt.allocPrint(ctx.allocator, "{{\"path\":\"{s}\"}}", .{tool_path});
                defer ctx.allocator.free(input_json);

                try events.publishToolCallEvent(ctx.allocator, ctx.event_bus.?, .{
                    .request_id = ctx.request_id.?,
                    .session_id = ctx.session_id.?,
                    .trace_id = ctx.trace_id,
                    .call_id = "call_01",
                    .tool_name = "read_file",
                    .input_json = input_json,
                });

                const completed = provider.ProviderStreamEvent{
                    .tool_call_completed = .{
                        .call_id = "call_01",
                        .tool_name = "read_file",
                        .input_json = input_json,
                    },
                };
                try sink.onEvent(&completed);
                try sink.onEvent(&provider.ProviderStreamEvent{ .completed = .{ .stop_reason = "tool_use" } });
                return;
            }

            try sink.onEvent(&provider.ProviderStreamEvent{ .text_delta = .{ .text = "done after tool" } });
            try sink.onEvent(&provider.ProviderStreamEvent{ .completed = .{ .stop_reason = "end_turn" } });
        }

        fn streamErased(ptr: *anyopaque, ctx: provider.ProviderExecutionContext, request: provider.ProviderRequest, sink: provider.LlmEventSink) anyerror!void {
            const self: *MockClient = @ptrCast(@alignCast(ptr));
            try self.stream(ctx, request, sink);
        }

        fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *MockClient = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }
    };
};

fn findSummaryTrace(sink: *framework.MemorySink, exception_type: []const u8) bool {
    for (0..sink.count()) |index| {
        const record = sink.recordAt(index) orelse continue;
        if (!std.mem.eql(u8, record.message, "TRACE_SUMMARY")) continue;
        for (record.fields) |field| {
            if (std.mem.eql(u8, field.key, "et") and field.value == .string and std.mem.eql(u8, field.value.string, exception_type)) {
                return true;
            }
        }
    }
    return false;
}
