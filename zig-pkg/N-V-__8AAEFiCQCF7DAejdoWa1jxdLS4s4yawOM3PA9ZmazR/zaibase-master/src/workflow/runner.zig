const std = @import("std");
const builtin = @import("builtin");
const app = @import("../app/root.zig");
const core = @import("../core/root.zig");
const effects = @import("../effects/root.zig");
const framework = @import("../root.zig");
const runtime = @import("../runtime/root.zig");
const definition = @import("definition.zig");
const state = @import("state.zig");
const step_types = @import("step_types.zig");

pub const WorkflowRunner = struct {
    allocator: std.mem.Allocator,
    dispatcher: app.CommandDispatcher,
    effects: *effects.EffectsRuntime,
    logger: ?*core.logging.Logger = null,
    event_bus: ?runtime.EventBus = null,
    task_runner: ?*runtime.TaskRunner = null,

    pub fn init(
        allocator: std.mem.Allocator,
        dispatcher: app.CommandDispatcher,
        effects_runtime: *effects.EffectsRuntime,
        logger: ?*core.logging.Logger,
        event_bus: ?runtime.EventBus,
        task_runner: ?*runtime.TaskRunner,
    ) WorkflowRunner {
        return .{
            .allocator = allocator,
            .dispatcher = dispatcher,
            .effects = effects_runtime,
            .logger = logger,
            .event_bus = event_bus,
            .task_runner = task_runner,
        };
    }

    pub fn run(self: *WorkflowRunner, workflow: definition.WorkflowDefinition) !state.WorkflowRunResult {
        var method_trace: ?framework.MethodTrace = null;
        var summary_trace: ?framework.SummaryTrace = null;
        if (self.logger) |logger| {
            method_trace = try framework.MethodTrace.begin(
                self.allocator,
                logger,
                "WorkflowRunner.run",
                workflow.id,
                500,
            );
            summary_trace = try framework.SummaryTrace.begin(
                self.allocator,
                logger,
                "WorkflowRunner.run",
                500,
            );
        }
        defer {
            if (method_trace) |*trace| trace.deinit();
            if (summary_trace) |*trace| trace.deinit();
        }

        try self.emitEvent("workflow.started", workflow.id, null);
        self.logInfo("workflow started", workflow.id, &.{
            framework.LogField.int("step_count", @intCast(workflow.steps.len)),
        });
        var result: state.WorkflowRunResult = .{
            .status = .running,
            .completed_steps = 0,
        };
        errdefer {
            result.status = .failed;
            if (method_trace) |*trace| trace.finishError("WorkflowRunFailed", null, false);
            if (summary_trace) |*trace| trace.finishError(.system);
        }

        for (workflow.steps) |step| {
            switch (step) {
                .command => |command_step| {
                    const output = try self.executeCommand(command_step);
                    if (result.last_output_json) |value| self.allocator.free(value);
                    result.last_output_json = output;
                },
                .shell => |shell_step| {
                    const output = try self.executeShell(shell_step);
                    if (result.last_output_json) |value| self.allocator.free(value);
                    result.last_output_json = output;
                },
                .emit_event => |event_step| {
                    _ = try (self.event_bus orelse return error.EventBusNotConfigured).publish(event_step.topic, event_step.payload_json);
                },
                .retry => |retry_step| {
                    const output = try self.executeRetry(retry_step);
                    if (result.last_output_json) |value| self.allocator.free(value);
                    result.last_output_json = output;
                },
            }
            result.completed_steps += 1;
        }

        result.status = .succeeded;
        try self.emitEvent("workflow.completed", workflow.id, null);
        self.logInfo("workflow completed", workflow.id, &.{
            framework.LogField.int("completed_steps", @intCast(result.completed_steps)),
        });
        if (method_trace) |*trace| trace.finishSuccess(result.last_output_json orelse "", false);
        if (summary_trace) |*trace| trace.finishSuccess();
        return result;
    }

    pub fn submit(self: *WorkflowRunner, workflow: definition.WorkflowDefinition) !framework.TaskAccepted {
        const runner = self.task_runner orelse return error.TaskRunnerNotConfigured;
        const job = try self.allocator.create(WorkflowJobData);
        errdefer self.allocator.destroy(job);
        job.* = try WorkflowJobData.init(self.allocator, self, workflow);

        return runner.submitJob("workflow.run", workflow.id, .{
            .ptr = @ptrCast(job),
            .vtable = &.{
                .run = WorkflowJobData.run,
                .deinit = WorkflowJobData.deinit,
            },
        });
    }

    fn executeCommand(self: *WorkflowRunner, step: step_types.CommandStep) ![]u8 {
        var envelope = try self.dispatcher.dispatch(.{
            .request_id = "workflow_command_step",
            .method = step.method,
            .params = step.params,
            .source = .@"test",
            .authority = .public,
        }, false);
        defer if (envelope.result) |*result| {
            switch (result.*) {
                .success_json => |json| self.allocator.free(json),
                else => {},
            }
        };

        if (!envelope.ok) {
            return error.WorkflowStepFailed;
        }
        return switch (envelope.result.?) {
            .success_json => |json| try self.allocator.dupe(u8, json),
            else => error.WorkflowStepFailed,
        };
    }

    fn executeShell(self: *WorkflowRunner, step: step_types.ShellStep) ![]u8 {
        var result = try self.effects.process_runner.run(self.allocator, .{
            .argv = step.argv,
            .cwd = step.cwd,
        });
        defer result.deinit(self.allocator);
        if (result.exit_code != 0) return error.WorkflowStepFailed;
        return try self.allocator.dupe(u8, result.stdout);
    }

    fn executeRetry(self: *WorkflowRunner, step: step_types.RetryStep) ![]u8 {
        var last_err: anyerror = error.WorkflowRetryExhausted;
        var attempt: usize = 0;
        while (attempt < step.attempts) : (attempt += 1) {
            const output = switch (step.target) {
                .command => |command_step| self.executeCommand(command_step),
                .shell => |shell_step| self.executeShell(shell_step),
            } catch |err| {
                last_err = err;
                if (step.delay_ms > 0) self.effects.clock.sleepMs(step.delay_ms);
                continue;
            };
            return output;
        }
        return last_err;
    }

    fn emitEvent(self: *WorkflowRunner, topic: []const u8, workflow_id: []const u8, error_code: ?[]const u8) !void {
        const bus = self.event_bus orelse return;
        const payload = if (error_code) |code|
            try std.fmt.allocPrint(self.allocator, "{{\"workflow_id\":\"{s}\",\"error_code\":\"{s}\"}}", .{ workflow_id, code })
        else
            try std.fmt.allocPrint(self.allocator, "{{\"workflow_id\":\"{s}\"}}", .{workflow_id});
        defer self.allocator.free(payload);
        _ = try bus.publish(topic, payload);
    }

    fn logInfo(self: *WorkflowRunner, message: []const u8, workflow_id: []const u8, fields: []const framework.LogField) void {
        const logger = self.logger orelse return;
        logger.child("workflow").child("runner").withField(framework.LogField.string("workflow_id", workflow_id)).info(message, fields);
    }
};

const WorkflowJobData = struct {
    runner: *WorkflowRunner,
    workflow_id: []u8,
    description: []u8,
    steps: []step_types.WorkflowStep,

    fn init(allocator: std.mem.Allocator, runner: *WorkflowRunner, workflow: definition.WorkflowDefinition) !WorkflowJobData {
        const steps = try allocator.alloc(step_types.WorkflowStep, workflow.steps.len);
        errdefer allocator.free(steps);
        @memcpy(steps, workflow.steps);

        return .{
            .runner = runner,
            .workflow_id = try allocator.dupe(u8, workflow.id),
            .description = try allocator.dupe(u8, workflow.description),
            .steps = steps,
        };
    }

    fn run(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *WorkflowJobData = @ptrCast(@alignCast(ptr));
        var result = try self.runner.run(.{
            .id = self.workflow_id,
            .description = self.description,
            .steps = self.steps,
        });
        defer result.deinit(allocator);

        return std.fmt.allocPrint(allocator, "{{\"status\":{f},\"completed_steps\":{d}}}", .{
            std.json.fmt(result.status.asText(), .{}),
            result.completed_steps,
        });
    }

    fn deinit(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *WorkflowJobData = @ptrCast(@alignCast(ptr));
        allocator.free(self.workflow_id);
        allocator.free(self.description);
        allocator.free(self.steps);
        allocator.destroy(self);
    }
};

test "workflow runner executes sequential steps successfully" {
    const Demo = struct {
        fn call(_: *const app.CommandContext) anyerror![]const u8 {
            return std.testing.allocator.dupe(u8, "{\"ok\":true}");
        }
    };

    var app_context = try runtime.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();
    try app_context.command_registry.register(.{
        .id = "demo.workflow",
        .method = "demo.workflow",
        .handler = Demo.call,
    });

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var runner = WorkflowRunner.init(
        std.testing.allocator,
        app_context.makeDispatcher(),
        &effects_runtime,
        app_context.logger,
        app_context.eventBus(),
        app_context.task_runner,
    );

    const steps = [_]step_types.WorkflowStep{
        .{ .command = .{ .method = "demo.workflow" } },
        .{ .emit_event = .{ .topic = "demo.event", .payload_json = "{\"phase\":\"done\"}" } },
    };
    var result = try runner.run(.{
        .id = "workflow.demo",
        .steps = steps[0..],
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(state.WorkflowStatus.succeeded, result.status);
    try std.testing.expectEqual(@as(usize, 2), result.completed_steps);
    try std.testing.expectEqualStrings("{\"ok\":true}", result.last_output_json.?);
}

test "workflow runner retries and succeeds" {
    const Demo = struct {
        var attempts: usize = 0;
        fn call(_: *const app.CommandContext) anyerror![]const u8 {
            attempts += 1;
            if (attempts < 2) return error.AccessDenied;
            return std.testing.allocator.dupe(u8, "{\"retry\":true}");
        }
    };

    var app_context = try runtime.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();
    try app_context.command_registry.register(.{
        .id = "demo.retry",
        .method = "demo.retry",
        .handler = Demo.call,
    });

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var runner = WorkflowRunner.init(
        std.testing.allocator,
        app_context.makeDispatcher(),
        &effects_runtime,
        app_context.logger,
        app_context.eventBus(),
        app_context.task_runner,
    );

    const steps = [_]step_types.WorkflowStep{
        .{ .retry = .{
            .attempts = 3,
            .target = .{ .command = .{ .method = "demo.retry" } },
        } },
    };
    var result = try runner.run(.{
        .id = "workflow.retry",
        .steps = steps[0..],
    });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(state.WorkflowStatus.succeeded, result.status);
    try std.testing.expectEqualStrings("{\"retry\":true}", result.last_output_json.?);
}

test "workflow runner retry fails after budget" {
    const command = switch (builtin.os.tag) {
        .windows => "exit /B 9",
        else => "exit 9",
    };

    var app_context = try runtime.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var runner = WorkflowRunner.init(
        std.testing.allocator,
        app_context.makeDispatcher(),
        &effects_runtime,
        app_context.logger,
        app_context.eventBus(),
        app_context.task_runner,
    );

    const shell_args = switch (builtin.os.tag) {
        .windows => &[_][]const u8{ "cmd.exe", "/C", command },
        else => &[_][]const u8{ "sh", "-c", command },
    };

    const steps = [_]step_types.WorkflowStep{
        .{ .retry = .{
            .attempts = 2,
            .target = .{ .shell = .{ .argv = shell_args[0..] } },
        } },
    };

    try std.testing.expectError(error.WorkflowStepFailed, runner.run(.{
        .id = "workflow.retry.fail",
        .steps = steps[0..],
    }));
}

test "workflow runner can submit async workflow task" {
    const Demo = struct {
        fn call(_: *const app.CommandContext) anyerror![]const u8 {
            return std.testing.allocator.dupe(u8, "{\"submitted\":true}");
        }
    };

    var app_context = try runtime.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();
    try app_context.command_registry.register(.{
        .id = "demo.async",
        .method = "demo.async",
        .handler = Demo.call,
    });

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var runner = WorkflowRunner.init(
        std.testing.allocator,
        app_context.makeDispatcher(),
        &effects_runtime,
        app_context.logger,
        app_context.eventBus(),
        app_context.task_runner,
    );

    const steps = [_]step_types.WorkflowStep{
        .{ .command = .{ .method = "demo.async" } },
    };
    const accepted = try runner.submit(.{
        .id = "workflow.async",
        .steps = steps[0..],
    });

    try std.testing.expectEqualStrings("queued", accepted.state);
    var summary = try app_context.task_runner.waitForCompletion(std.testing.allocator, accepted.task_id, 2000);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expect(summary.state.isTerminal());
    try std.testing.expectEqual(runtime.TaskState.succeeded, summary.state);
}


