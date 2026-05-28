const std = @import("std");
const framework = @import("framework");
const app_context_model = @import("../app_context.zig");
const config = @import("../config/root.zig");
const provider = @import("../provider/root.zig");
const session = @import("../session/root.zig");
const aggregate = @import("aggregate.zig");
const wait = @import("wait.zig");
const types = @import("types.zig");

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    task_runner: *framework.TaskRunner,
    session_runtime: *session.SessionRuntime,
    session_store: session.SessionStore,
};

pub const OrchestrationService = struct {
    deps: Dependencies,

    const Self = @This();

    pub fn init(deps: Dependencies) Self {
        return .{ .deps = deps };
    }

    pub fn startChild(self: *Self, allocator: std.mem.Allocator, parent_session_id: []const u8, child: types.ChildRequest) !types.ChildHandle {
        var parent = (try self.deps.session_store.getSession(allocator, parent_session_id)) orelse return error.SessionNotFound;
        defer parent.deinit(allocator);

        const child_agent_id = child.agent_id orelse parent.agent_id;
        const title = child.title orelse defaultChildTitle(child.prompt);
        var child_session = try self.deps.session_runtime.createSessionWithRequest(.{
            .title = title,
            .agent_id = child_agent_id,
            .parent_id = parent_session_id,
        });
        defer child_session.deinit(self.deps.allocator);

        var prompt_message = try self.deps.session_runtime.submitPrompt(.{
            .session_id = child_session.id,
            .agent_id = child_agent_id,
            .parts = &.{.{ .text = child.prompt }},
        });
        defer prompt_message.deinit(self.deps.allocator);

        const request_id = try std.fmt.allocPrint(allocator, "child_req_{d}_{s}", .{ std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds(), child_session.id });
        errdefer allocator.free(request_id);

        const accepted = try self.deps.session_runtime.submitAgentTask(.{
            .session_id = child_session.id,
            .agent_id = child.agent_id,
            .category = child.category,
            .model = child.model,
            .request_id = request_id,
        });

        return .{
            .child_session_id = try allocator.dupe(u8, child_session.id),
            .agent_id = try allocator.dupe(u8, child_agent_id),
            .request_id = request_id,
            .task_id = try allocator.dupe(u8, accepted.task_id),
        };
    }

    pub fn waitChild(self: *Self, allocator: std.mem.Allocator, handle: types.ChildHandle, timeout_ms: u64) !types.ChildResult {
        var summary = try self.deps.task_runner.waitForCompletion(allocator, handle.task_id, timeout_ms);
        defer summary.deinit(allocator);

        var status_info = (try self.deps.session_runtime.getSessionStatus(allocator, handle.child_session_id)) orelse return error.SessionStatusMissing;
        defer status_info.deinit(allocator);

        const text_summary = try wait.latestAssistantSummary(allocator, self.deps.session_runtime, handle.child_session_id);
        errdefer allocator.free(text_summary);

        return .{
            .child_session_id = try allocator.dupe(u8, handle.child_session_id),
            .agent_id = try allocator.dupe(u8, handle.agent_id),
            .status = try allocator.dupe(u8, status_info.status.asText()),
            .request_id = try allocator.dupe(u8, handle.request_id),
            .task_id = try allocator.dupe(u8, handle.task_id),
            .summary = text_summary,
        };
    }

    pub fn recordResult(self: *Self, parent_session_id: []const u8, result: types.ChildResult) !void {
        var parent_message = try self.deps.session_store.appendMessage(self.deps.allocator, .{
            .session_id = parent_session_id,
            .role = .assistant,
            .completed = true,
        });
        defer parent_message.deinit(self.deps.allocator);

        var subtask_part = try session.subtaskPart(
            self.deps.allocator,
            result.child_session_id,
            result.agent_id,
            result.status,
            result.summary,
        );
        defer subtask_part.deinit(self.deps.allocator);

        var appended = try self.deps.session_store.appendPart(self.deps.allocator, .{
            .session_id = parent_session_id,
            .message_id = parent_message.id,
            .part = subtask_part,
        });
        appended.deinit(self.deps.allocator);
    }

    pub fn recordAggregate(self: *Self, parent_session_id: []const u8, aggregated: types.AggregatedResult) !void {
        const child_results_json = try aggregate.childResultsJson(self.deps.allocator, aggregated.items);
        defer self.deps.allocator.free(child_results_json);

        var parent_message = try self.deps.session_store.appendMessage(self.deps.allocator, .{
            .session_id = parent_session_id,
            .role = .assistant,
            .completed = true,
        });
        defer parent_message.deinit(self.deps.allocator);

        var aggregate_part = try session.subtaskAggregatePart(
            self.deps.allocator,
            aggregated.batch_id,
            aggregated.summary,
            aggregated.success_count,
            aggregated.failure_count,
            child_results_json,
        );
        defer aggregate_part.deinit(self.deps.allocator);

        var appended = try self.deps.session_store.appendPart(self.deps.allocator, .{
            .session_id = parent_session_id,
            .message_id = parent_message.id,
            .part = aggregate_part,
        });
        appended.deinit(self.deps.allocator);
    }

    pub fn delegateOne(self: *Self, allocator: std.mem.Allocator, parent_session_id: []const u8, child: types.ChildRequest, timeout_ms: u64) !types.ChildResult {
        var handle = try self.startChild(allocator, parent_session_id, child);
        defer handle.deinit(allocator);
        var result = try self.waitChild(allocator, handle, timeout_ms);
        errdefer result.deinit(allocator);
        try self.recordResult(parent_session_id, result);
        return result;
    }

    pub fn delegateBatch(self: *Self, allocator: std.mem.Allocator, batch: types.BatchRequest, timeout_ms: u64) !types.AggregatedResult {
        const handles = try allocator.alloc(types.ChildHandle, batch.children.len);
        errdefer allocator.free(handles);
        var handle_count: usize = 0;
        errdefer {
            for (handles[0..handle_count]) |*handle| handle.deinit(allocator);
        }

        for (batch.children, 0..) |child, index| {
            handles[index] = try self.startChild(allocator, batch.parent_session_id, child);
            handle_count += 1;
        }

        const results = try allocator.alloc(types.ChildResult, batch.children.len);
        errdefer allocator.free(results);
        var result_count: usize = 0;
        errdefer {
            for (results[0..result_count]) |*result| result.deinit(allocator);
        }

        for (handles, 0..) |handle, index| {
            results[index] = try self.waitChild(allocator, handle, timeout_ms);
            result_count += 1;
            try self.recordResult(batch.parent_session_id, results[index]);
        }

        for (handles) |*handle| handle.deinit(allocator);
        allocator.free(handles);

        var success_count: u32 = 0;
        var failure_count: u32 = 0;
        for (results) |result| {
            if (std.mem.eql(u8, result.status, "completed")) success_count += 1 else failure_count += 1;
        }

        const summary = try std.fmt.allocPrint(allocator, "{d} child tasks: {d} completed, {d} failed", .{
            batch.children.len,
            success_count,
            failure_count,
        });
        errdefer allocator.free(summary);

        const owned_batch_id = if (batch.batch_id) |batch_id|
            try allocator.dupe(u8, batch_id)
        else
            try std.fmt.allocPrint(allocator, "batch_{d}", .{std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds()});
        errdefer allocator.free(owned_batch_id);

        var aggregated: types.AggregatedResult = .{
            .batch_id = owned_batch_id,
            .parent_session_id = try allocator.dupe(u8, batch.parent_session_id),
            .summary = summary,
            .success_count = success_count,
            .failure_count = failure_count,
            .items = results,
        };
        errdefer aggregated.deinit(allocator);
        try self.recordAggregate(batch.parent_session_id, aggregated);
        return aggregated;
    }

    pub fn handleBatchJson(self: *Self, allocator: std.mem.Allocator, parent_session_id: []const u8, children_json: []const u8, timeout_ms: u64) ![]u8 {
        var batch = try parseBatchJson(allocator, parent_session_id, children_json);
        defer batch.deinit(allocator);

        var aggregated = try self.delegateBatch(allocator, batch, timeout_ms);
        defer aggregated.deinit(allocator);
        return aggregate.toJson(allocator, aggregated);
    }
};

pub fn registerDelegateBatchCommand(service: *OrchestrationService, framework_app: *framework.AppContext) !void {
    const child_fields = [_]framework.FieldDefinition{
        .{ .key = "prompt", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string } },
        .{ .key = "agent_id", .required = false, .value_kind = .string },
        .{ .key = "category", .required = false, .value_kind = .string },
        .{ .key = "title", .required = false, .value_kind = .string },
        .{ .key = "model", .required = false, .value_kind = .string },
    };
    const params = [_]framework.FieldDefinition{
        .{ .key = "parent_session_id", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string } },
        .{
            .key = "children",
            .required = false,
            .value_kind = .array,
            .rules = &.{.{ .array_length = .{ .min = 1 } }},
            .element_kind = .object,
            .element_fields = child_fields[0..],
        },
        .{ .key = "children_json", .required = false, .value_kind = .string, .rules = &.{ .non_empty_string } },
        .{ .key = "timeout_ms", .required = false, .value_kind = .integer },
    };

    try framework_app.registerCommand(.{
        .id = "agent.delegate_batch",
        .method = "agent.delegate_batch",
        .description = "Delegate one or more child agent tasks and aggregate their results",
        .execution_mode = .async_task,
        .params = params[0..],
        .async_handler = struct {
            fn call(ctx: *const framework.CommandContext) anyerror![]const u8 {
                const service_ptr: *OrchestrationService = @ptrCast(@alignCast(ctx.user_data.?));
                const parent_session_id = ctx.param("parent_session_id").?.value.string;
                const timeout_ms: u64 = if (ctx.param("timeout_ms")) |field|
                    @intCast(field.value.integer)
                else
                    5000;

                if (ctx.param("children")) |children_field| {
                    var batch = try parseBatchFields(ctx.allocator, parent_session_id, ctx.request.request_id, children_field.value.array);
                    defer batch.deinit(ctx.allocator);

                    var aggregated = try service_ptr.delegateBatch(ctx.allocator, batch, timeout_ms);
                    defer aggregated.deinit(ctx.allocator);
                    return aggregate.toJson(ctx.allocator, aggregated);
                }

                const children_json = ctx.param("children_json").?.value.string;
                const json_with_batch_id = try injectBatchIdIntoChildrenJson(ctx.allocator, ctx.request.request_id, children_json);
                defer ctx.allocator.free(json_with_batch_id);
                return service_ptr.handleBatchJson(ctx.allocator, parent_session_id, json_with_batch_id, timeout_ms);
            }
        }.call,
        .user_data = service,
    });
}

fn parseBatchFields(
    allocator: std.mem.Allocator,
    parent_session_id: []const u8,
    batch_id: []const u8,
    children_values: []const framework.ValidationValue,
) !types.BatchRequest {
    const children = try allocator.alloc(types.ChildRequest, children_values.len);
    errdefer allocator.free(children);

    for (children_values, 0..) |child_value, index| {
        if (child_value != .object) return error.InvalidToolInput;
        children[index] = try parseChildObject(allocator, child_value.object);
    }

    return .{
        .batch_id = try allocator.dupe(u8, batch_id),
        .parent_session_id = try allocator.dupe(u8, parent_session_id),
        .children = children,
    };
}

fn parseChildObject(allocator: std.mem.Allocator, fields: []const framework.ValidationField) !types.ChildRequest {
    const prompt_text = getObjectString(fields, "prompt") orelse return error.InvalidToolInput;
    return .{
        .prompt = try allocator.dupe(u8, prompt_text),
        .agent_id = if (getObjectString(fields, "agent_id")) |value| try allocator.dupe(u8, value) else null,
        .category = if (getObjectString(fields, "category")) |value| try allocator.dupe(u8, value) else null,
        .title = if (getObjectString(fields, "title")) |value| try allocator.dupe(u8, value) else null,
        .model = if (getObjectString(fields, "model")) |value| try parseModelRef(allocator, value) else null,
    };
}

fn getObjectString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn parseBatchJson(allocator: std.mem.Allocator, parent_session_id: []const u8, children_json: []const u8) !types.BatchRequest {
    const InputChild = struct {
        prompt: []const u8,
        agent_id: ?[]const u8 = null,
        category: ?[]const u8 = null,
        title: ?[]const u8 = null,
        model: ?[]const u8 = null,
    };
    const Parsed = struct {
        batch_id: ?[]const u8 = null,
        children: []InputChild,
    };

    const parsed = try std.json.parseFromSlice(Parsed, allocator, children_json, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    const children = try allocator.alloc(types.ChildRequest, parsed.value.children.len);
    errdefer allocator.free(children);
    for (parsed.value.children, 0..) |child, index| {
        children[index] = .{
            .prompt = try allocator.dupe(u8, child.prompt),
            .agent_id = if (child.agent_id) |value| try allocator.dupe(u8, value) else null,
            .category = if (child.category) |value| try allocator.dupe(u8, value) else null,
            .title = if (child.title) |value| try allocator.dupe(u8, value) else null,
            .model = if (child.model) |value| try parseModelRef(allocator, value) else null,
        };
    }

    return .{
        .batch_id = if (parsed.value.batch_id) |batch_id| try allocator.dupe(u8, batch_id) else null,
        .parent_session_id = try allocator.dupe(u8, parent_session_id),
        .children = children,
    };
}

fn injectBatchIdIntoChildrenJson(allocator: std.mem.Allocator, batch_id: []const u8, children_json: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, children_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidToolInput;

    const children_value = parsed.value.object.get("children") orelse return error.InvalidToolInput;

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    try buf.appendSlice(allocator, "{\"batch_id\":");
    try buf.print(allocator, "{f}", .{std.json.fmt(batch_id, .{})});
    try buf.appendSlice(allocator, ",\"children\":");
    try buf.print(allocator, "{f}", .{std.json.fmt(children_value, .{})});
    try buf.append(allocator, '}');
    return allocator.dupe(u8, buf.items);
}

fn parseModelRef(allocator: std.mem.Allocator, raw: []const u8) !provider.ModelRef {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return error.InvalidModelRef;
    if (slash == 0 or slash + 1 >= raw.len) return error.InvalidModelRef;
    return .{
        .provider_id = try allocator.dupe(u8, raw[0..slash]),
        .model_id = try allocator.dupe(u8, raw[slash + 1 ..]),
    };
}

fn defaultChildTitle(prompt_text: []const u8) []const u8 {
    return if (prompt_text.len > 48) prompt_text[0..48] else prompt_text;
}

test "single child delegation creates child session and records subtask result" {
    var fixture = try makeOrchestrationFixture(std.testing.allocator);
    defer fixture.deinit();
    MockProvider.reset();

    var parent = try fixture.app_context.sessionRuntime().createSession("Parent", "build");
    defer parent.deinit(std.testing.allocator);

    var result = try fixture.app_context.orchestrationService().delegateOne(std.testing.allocator, parent.id, .{
        .prompt = "child one",
        .agent_id = "build",
    }, 5000);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("build", result.agent_id);
    try std.testing.expectEqualStrings("completed", result.status);

    var child_session = (try fixture.app_context.sessionStore().getSession(std.testing.allocator, result.child_session_id)).?;
    defer child_session.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(parent.id, child_session.parent_id.?);

    const history = try fixture.app_context.sessionRuntime().listHistory(std.testing.allocator, parent.id);
    defer {
        for (history) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(history);
    }

    var saw_subtask = false;
    for (history) |message| {
        for (message.parts) |part| {
            if (part == .subtask) {
                saw_subtask = true;
                try std.testing.expectEqualStrings(result.child_session_id, part.subtask.child_session_id);
                try std.testing.expectEqualStrings("completed", part.subtask.status);
            }
        }
    }
    try std.testing.expect(saw_subtask);
}

test "failed child delegation still records failed subtask result" {
    var fixture = try makeOrchestrationFixture(std.testing.allocator);
    defer fixture.deinit();
    MockProvider.reset();

    var parent = try fixture.app_context.sessionRuntime().createSession("Parent", "build");
    defer parent.deinit(std.testing.allocator);

    var result = try fixture.app_context.orchestrationService().delegateOne(std.testing.allocator, parent.id, .{
        .prompt = "fail child",
        .agent_id = "build",
    }, 5000);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("failed", result.status);

    const history = try fixture.app_context.sessionRuntime().listHistory(std.testing.allocator, parent.id);
    defer {
        for (history) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(history);
    }

    var saw_failed_subtask = false;
    for (history) |message| {
        for (message.parts) |part| {
            if (part == .subtask and std.mem.eql(u8, part.subtask.status, "failed")) {
                saw_failed_subtask = true;
            }
        }
    }
    try std.testing.expect(saw_failed_subtask);
}

test "parallel fan-out aggregates multiple child results and overlaps execution" {
    var fixture = try makeOrchestrationFixture(std.testing.allocator);
    defer fixture.deinit();
    MockProvider.reset();

    var parent = try fixture.app_context.sessionRuntime().createSession("Parent", "build");
    defer parent.deinit(std.testing.allocator);

    const children = try std.testing.allocator.alloc(types.ChildRequest, 2);
    children[0] = try (types.ChildRequest{ .prompt = "child one", .agent_id = "build" }).clone(std.testing.allocator);
    children[1] = try (types.ChildRequest{ .prompt = "child two", .agent_id = "build" }).clone(std.testing.allocator);

    var batch = types.BatchRequest{
        .batch_id = try std.testing.allocator.dupe(u8, "batch_parallel_fixed"),
        .parent_session_id = try std.testing.allocator.dupe(u8, parent.id),
        .children = children,
    };
    defer batch.deinit(std.testing.allocator);

    var aggregated = try fixture.app_context.orchestrationService().delegateBatch(std.testing.allocator, batch, 5000);
    defer aggregated.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), aggregated.items.len);
    try std.testing.expect(MockProvider.maxActiveCount() >= 2);
    try std.testing.expectEqual(@as(u32, 2), aggregated.success_count);
    try std.testing.expectEqual(@as(u32, 0), aggregated.failure_count);

    const history = try fixture.app_context.sessionRuntime().listHistory(std.testing.allocator, parent.id);
    defer {
        for (history) |*message| message.deinit(std.testing.allocator);
        std.testing.allocator.free(history);
    }

    var saw_subtask = false;
    var saw_aggregate = false;
    for (history) |message| {
        for (message.parts) |part| {
            switch (part) {
                .subtask => saw_subtask = true,
                .subtask_aggregate => {
                    saw_aggregate = true;
                    try std.testing.expectEqualStrings("batch_parallel_fixed", part.subtask_aggregate.batch_id);
                    try std.testing.expectEqual(@as(u32, 2), part.subtask_aggregate.success_count);
                },
                else => {},
            }
        }
    }
    try std.testing.expect(saw_subtask);
    try std.testing.expect(saw_aggregate);
}

test "category overlay does not replace child agent identity" {
    var fixture = try makeOrchestrationFixture(std.testing.allocator);
    defer fixture.deinit();
    MockProvider.reset();

    var parent = try fixture.app_context.sessionRuntime().createSession("Parent", "build");
    defer parent.deinit(std.testing.allocator);

    var result = try fixture.app_context.orchestrationService().delegateOne(std.testing.allocator, parent.id, .{
        .prompt = "visual child",
        .agent_id = "build",
        .category = "visual",
    }, 5000);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("build", result.agent_id);
    try std.testing.expect(std.mem.indexOf(u8, MockProvider.lastSystemPrompt(), "visual detail") != null);
}

test "delegate batch command is registered as canonical async entry surface" {
    var fixture = try makeOrchestrationFixture(std.testing.allocator);
    defer fixture.deinit();
    MockProvider.reset();

    var parent = try fixture.app_context.sessionRuntime().createSession("Parent", "build");
    defer parent.deinit(std.testing.allocator);

    const dispatcher = framework.CommandDispatcher.initWithServices(
        std.testing.allocator,
        null,
        fixture.app_context.framework_app.command_registry,
        fixture.app_context.framework_app.task_runner,
    );
    const child_fields = [_]framework.ValidationField{
        .{ .key = "prompt", .value = .{ .string = "child cmd" } },
        .{ .key = "agent_id", .value = .{ .string = "build" } },
    };
    const child_items = [_]framework.ValidationValue{
        .{ .object = child_fields[0..] },
    };
    const params = [_]framework.ValidationField{
        .{ .key = "parent_session_id", .value = .{ .string = parent.id } },
        .{ .key = "children", .value = .{ .array = child_items[0..] } },
    };

    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_delegate_batch",
        .method = "agent.delegate_batch",
        .params = params[0..],
        .source = .@"test",
    }, false);

    try std.testing.expect(envelope.ok);
    try std.testing.expect(envelope.result.? == .task_accepted);

    var summary = try fixture.app_context.framework_app.task_runner.waitForCompletion(std.testing.allocator, envelope.result.?.task_accepted.task_id, 5000);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(framework.TaskState.succeeded, summary.state);
    try std.testing.expect(summary.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.result_json.?, "\"batch_id\":\"req_delegate_batch\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.result_json.?, "\"success_count\"") != null);
}

test "structured command input missing child prompt fails validation before orchestration" {
    var fixture = try makeOrchestrationFixture(std.testing.allocator);
    defer fixture.deinit();

    var parent = try fixture.app_context.sessionRuntime().createSession("Parent", "build");
    defer parent.deinit(std.testing.allocator);

    const dispatcher = framework.CommandDispatcher.initWithServices(
        std.testing.allocator,
        null,
        fixture.app_context.framework_app.command_registry,
        fixture.app_context.framework_app.task_runner,
    );
    const child_fields = [_]framework.ValidationField{
        .{ .key = "agent_id", .value = .{ .string = "build" } },
    };
    const child_items = [_]framework.ValidationValue{
        .{ .object = child_fields[0..] },
    };
    const params = [_]framework.ValidationField{
        .{ .key = "parent_session_id", .value = .{ .string = parent.id } },
        .{ .key = "children", .value = .{ .array = child_items[0..] } },
    };

    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_missing_prompt",
        .method = "agent.delegate_batch",
        .params = params[0..],
        .source = .@"test",
    }, false);

    try std.testing.expect(!envelope.ok);
    try std.testing.expectEqualStrings(framework.core.error_model.code.VALIDATION_FAILED, envelope.app_error.?.code);
}

test "structured command input wrong child field type fails validation before orchestration" {
    var fixture = try makeOrchestrationFixture(std.testing.allocator);
    defer fixture.deinit();

    var parent = try fixture.app_context.sessionRuntime().createSession("Parent", "build");
    defer parent.deinit(std.testing.allocator);

    const dispatcher = framework.CommandDispatcher.initWithServices(
        std.testing.allocator,
        null,
        fixture.app_context.framework_app.command_registry,
        fixture.app_context.framework_app.task_runner,
    );
    const child_fields = [_]framework.ValidationField{
        .{ .key = "prompt", .value = .{ .string = "child cmd" } },
        .{ .key = "agent_id", .value = .{ .integer = 1 } },
    };
    const child_items = [_]framework.ValidationValue{
        .{ .object = child_fields[0..] },
    };
    const params = [_]framework.ValidationField{
        .{ .key = "parent_session_id", .value = .{ .string = parent.id } },
        .{ .key = "children", .value = .{ .array = child_items[0..] } },
    };

    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_wrong_type",
        .method = "agent.delegate_batch",
        .params = params[0..],
        .source = .@"test",
    }, false);

    try std.testing.expect(!envelope.ok);
    try std.testing.expectEqualStrings(framework.core.error_model.code.VALIDATION_TYPE_MISMATCH, envelope.app_error.?.code);
}

const OrchestrationFixture = struct {
    tmp_dir: std.testing.TmpDir,
    root_path: []u8,
    project_dir: []u8,
    global_path: []u8,
    app_context: app_context_model.AppContext,

    fn deinit(self: *OrchestrationFixture) void {
        self.app_context.deinit();
        std.testing.allocator.free(self.global_path);
        std.testing.allocator.free(self.project_dir);
        std.testing.allocator.free(self.root_path);
        self.tmp_dir.cleanup();
    }
};

fn makeOrchestrationFixture(allocator: std.mem.Allocator) !OrchestrationFixture {
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    errdefer allocator.free(root_path);
    const project_dir = try std.fs.path.join(allocator, &.{ root_path, "workspace" });
    errdefer allocator.free(project_dir);
    _ = std.c.mkdir(@ptrCast(project_dir.ptr), 0o755);

    const config_path = try std.fs.path.join(allocator, &.{ project_dir, "zopcode.json" });
    defer allocator.free(config_path);
    const global_path = try std.fs.path.join(allocator, &.{ root_path, "missing-global.json" });
    errdefer allocator.free(global_path);

    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), config_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), 
        \\{
        \\  "agent": { "default": "build" },
        \\  "session": { "store": { "path": "sessions" } },
        \\  "tools": {
        \\    "read_file": true,
        \\    "write_file": true,
        \\    "execute_shell": true,
        \\    "list_files": true,
        \\    "search_files": true,
        \\    "fetch_url": true
        \\  }
        \\}
    );

    var app_context = try app_context_model.AppContext.initWithConfigOptions(allocator, .{
        .console_log_enabled = false,
    }, .{
        .current_dir = project_dir,
        .global_config_path = global_path,
    });

    app_context.provider_registry.entries.items[0].create_client = MockProvider.createClient;
    app_context.provider_registry.entries.items[0].info.default_model = .{
        .provider_id = "anthropic",
        .model_id = "mock-model",
    };

    var attempt = try app_context.config_runtime.writeFields(&.{
        .{ .key = config.keys.model_default, .value = .{ .string = "anthropic/mock-model" } },
    }, false);
    defer attempt.deinit();

    return .{
        .tmp_dir = tmp_dir,
        .root_path = root_path,
        .project_dir = project_dir,
        .global_path = global_path,
        .app_context = app_context,
    };
}

const MockProvider = struct {
    var mutex: std.atomic.Mutex = .unlocked;
    var active_count: usize = 0;
    var max_active: usize = 0;
    var last_system_prompt_storage: [4096]u8 = undefined;
    var last_system_prompt_len: usize = 0;

    fn reset() void {
        mutex.lock();
        defer mutex.unlock();
        active_count = 0;
        max_active = 0;
        last_system_prompt_len = 0;
    }

    fn maxActiveCount() usize {
        mutex.lock();
        defer mutex.unlock();
        return max_active;
    }

    fn lastSystemPrompt() []const u8 {
        mutex.lock();
        defer mutex.unlock();
        return last_system_prompt_storage[0..last_system_prompt_len];
    }

    fn createClient(allocator: std.mem.Allocator, ctx: provider.ProviderRegistry.ProviderCreateContext) anyerror!provider.ProviderClient {
        const client = try allocator.create(MockClient);
        client.* = .{
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
            var should_fail = false;
            for (request.messages) |message| {
                if (std.mem.indexOf(u8, message.content, "fail") != null) {
                    should_fail = true;
                    break;
                }
            }

            mutex.lock();
            active_count += 1;
            if (active_count > max_active) max_active = active_count;
            if (request.system_prompt) |system_prompt| {
                last_system_prompt_len = @min(last_system_prompt_storage.len, system_prompt.len);
                @memcpy(last_system_prompt_storage[0..last_system_prompt_len], system_prompt[0..last_system_prompt_len]);
            } else {
                last_system_prompt_len = 0;
            }
            mutex.unlock();
            defer {
                mutex.lock();
                active_count -= 1;
                mutex.unlock();
            }

            std.Thread.sleep(40 * std.time.ns_per_ms);

            if (should_fail) {
                try sink.onEvent(&.{ .failed = .{
                    .code = framework.core.error_model.code.PROVIDER_OPERATION_FAILED,
                    .message = "mock child failure",
                    .retryable = false,
                } });
                return;
            }

            const summary_text = summaryFromMessages(request.messages);
            try sink.onEvent(&.{ .text_delta = .{ .text = summary_text } });
            try sink.onEvent(&.{ .completed = .{ .stop_reason = "end_turn" } });
        }

        fn streamErased(ptr: *anyopaque, ctx: provider.ProviderExecutionContext, request: provider.ProviderRequest, sink: provider.LlmEventSink) anyerror!void {
            const self: *MockClient = @ptrCast(@alignCast(ptr));
            try self.stream(ctx, request, sink);
        }

        fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *MockClient = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }

        fn summaryFromMessages(messages: []const provider.ProviderMessage) []const u8 {
            for (messages) |message| {
                if (message.role != .user) continue;
                if (std.mem.indexOf(u8, message.content, "child one") != null) return "child-one-done";
                if (std.mem.indexOf(u8, message.content, "child two") != null) return "child-two-done";
                if (std.mem.indexOf(u8, message.content, "visual child") != null) return "visual-child-done";
                if (std.mem.indexOf(u8, message.content, "child cmd") != null) return "command-child-done";
            }
            return "child-done";
        }
    };
};
