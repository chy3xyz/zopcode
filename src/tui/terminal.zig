const std = @import("std");
const framework = @import("framework");
const zig_opencode = @import("../root.zig");
const model = @import("model.zig");
const render = @import("render.zig");

pub const TerminalOptions = struct {
    max_event_lines: usize = 16,
};

pub const TerminalApp = struct {
    allocator: std.mem.Allocator,
    client: *zig_opencode.Client,
    view_model: model.TerminalViewModel,
    subscription: zig_opencode.client.EventSubscription,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, client: *zig_opencode.Client, options: TerminalOptions) !Self {
        var self = Self{
            .allocator = allocator,
            .client = client,
            .view_model = try model.TerminalViewModel.init(allocator, options.max_event_lines),
            .subscription = try client.subscribeEvents(0),
        };
        try self.refreshDashboard();
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.subscription.deinit(self.allocator);
        self.view_model.deinit();
    }

    pub fn attachSession(self: *Self, session_id: []const u8) !void {
        var session_info = (try self.client.getSession(session_id)) orelse return error.SessionNotFound;
        defer session_info.deinit(self.allocator);

        try self.view_model.setSession(session_info.session_id);
        try self.view_model.setAgent(session_info.agent_id);
        try self.view_model.appendEventLine("attached session");
        try self.refreshDashboard();
    }

    pub fn submitPrompt(self: *Self, text: []const u8) !zig_opencode.server.AcceptedResponse {
        const session_id = try self.ensureActiveSession(text);
        const accepted = try self.client.submitPrompt(session_id, .{ .text = text });
        try self.view_model.setStatus("running");
        try self.view_model.appendEventLine("submitted prompt");
        return accepted;
    }

    pub fn pumpEvents(self: *Self, limit: usize) !usize {
        const events = try self.subscription.poll(self.allocator, limit);
        defer zig_opencode.client.transport.freeEventDtos(self.allocator, events);

        for (events) |event| {
            try self.applyEvent(event.topic, event.payload_json);
        }
        return events.len;
    }

    pub fn renderTo(self: *Self, stdout: std.Io.File, io: std.Io) !void {
        const summary = try render.renderSummary(self.allocator, &self.view_model);
        defer self.allocator.free(summary);
        try stdout.writeStreamingAll(io, summary);
        try stdout.writeStreamingAll(io, "\n");

        const sidebar = try render.renderSidebar(self.allocator, &self.view_model);
        defer self.allocator.free(sidebar);
        if (sidebar.len > 0) {
            try stdout.writeStreamingAll(io, sidebar);
            try stdout.writeStreamingAll(io, "\n");
        }

        const panel = try render.renderPanel(self.allocator, &self.view_model);
        defer self.allocator.free(panel);
        if (panel.len > 0) {
            try stdout.writeStreamingAll(io, panel);
            try stdout.writeStreamingAll(io, "\n");
        }

        if (self.view_model.event_lines.items.len > 0) {
            const stream = try render.renderEventStream(self.allocator, &self.view_model);
            defer self.allocator.free(stream);
            if (stream.len > 0) {
                try stdout.writeStreamingAll(io, stream);
                try stdout.writeStreamingAll(io, "\n");
            }
        }

        if (self.view_model.latest_response) |_| {
            const response = try render.renderLatestResponse(self.allocator, &self.view_model);
            defer self.allocator.free(response);
            if (response.len > 0) {
                try stdout.writeStreamingAll(io, response);
                try stdout.writeStreamingAll(io, "\n");
            }
        }
    }

    pub fn runInteractive(self: *Self) !void { _ = self; }

    fn ensureActiveSession(self: *Self, text: []const u8) ![]const u8 {
        if (self.view_model.active_session_id) |session_id| return session_id;

        const title = if (text.len > 32) text[0..32] else text;
        var created = try self.client.createSession(.{ .title = title });
        defer created.deinit(self.allocator);

        try self.view_model.setSession(created.session_id);
        try self.view_model.setAgent(created.agent_id);
        try self.view_model.appendEventLine("created session");
        return self.view_model.active_session_id.?;
    }

    fn sessionIsTerminal(self: *Self) !bool {
        const session_id = self.view_model.active_session_id orelse return true;
        var statuses = try self.client.listStatus();
        defer statuses.deinit(self.allocator);

        for (statuses.items) |status_info| {
            if (!std.mem.eql(u8, status_info.session_id, session_id)) continue;
            return std.mem.eql(u8, status_info.status, "completed") or
                std.mem.eql(u8, status_info.status, "failed") or
                std.mem.eql(u8, status_info.status, "cancelled");
        }
        return false;
    }

    fn applyEvent(self: *Self, topic: []const u8, payload_json: []const u8) !void {
        if (std.mem.eql(u8, topic, zig_opencode.session.SESSION_CREATED_EVENT_TOPIC)) {
            const parsed = try std.json.parseFromSlice(SessionCreatedPayload, self.allocator, payload_json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (self.view_model.active_session_id == null) try self.view_model.setSession(parsed.value.sessionId);
            try self.view_model.appendEventLine("session created");
            return;
        }
        if (std.mem.eql(u8, topic, zig_opencode.session.SESSION_STATUS_EVENT_TOPIC)) {
            const parsed = try std.json.parseFromSlice(SessionStatusPayload, self.allocator, payload_json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try self.view_model.setStatus(parsed.value.status);
            const line = try std.fmt.allocPrint(self.allocator, "status -> {s}", .{parsed.value.status});
            defer self.allocator.free(line);
            try self.view_model.appendEventLine(line);
            return;
        }
        if (std.mem.eql(u8, topic, zig_opencode.session.TOOL_CALL_EVENT_TOPIC)) {
            const parsed = try std.json.parseFromSlice(ToolCallPayload, self.allocator, payload_json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try self.view_model.setRecentTool(parsed.value.toolName);
            const line = try std.fmt.allocPrint(self.allocator, "tool call -> {s}", .{parsed.value.toolName});
            defer self.allocator.free(line);
            try self.view_model.appendEventLine(line);
            return;
        }
        if (std.mem.eql(u8, topic, zig_opencode.session.TOOL_RESULT_COMPLETED_EVENT_TOPIC) or std.mem.eql(u8, topic, zig_opencode.session.TOOL_RESULT_FAILED_EVENT_TOPIC)) {
            const parsed = try std.json.parseFromSlice(ToolResultPayload, self.allocator, payload_json, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try self.view_model.setRecentTool(parsed.value.toolName);
            const line = try std.fmt.allocPrint(self.allocator, "tool result -> {s}", .{parsed.value.toolName});
            defer self.allocator.free(line);
            try self.view_model.appendEventLine(line);
            return;
        }
        if (std.mem.eql(u8, topic, zig_opencode.session.SESSION_PART_APPENDED_EVENT_TOPIC) or std.mem.eql(u8, topic, zig_opencode.session.PROVIDER_RESPONSE_COMPLETED_TOPIC)) {
            try self.refreshLatestResponse();
            return;
        }
    }

    fn refreshDashboard(self: *Self) !void {
        var statuses = try self.client.listStatus();
        defer statuses.deinit(self.allocator);
        try self.view_model.replaceSessionStatuses(statuses.items);

        var project_info = try self.client.getProject();
        defer project_info.deinit(self.allocator);
        try self.view_model.replaceProject(project_info);

        var workspaces = try self.client.listWorkspaces();
        defer workspaces.deinit(self.allocator);
        try self.view_model.replaceWorkspaces(workspaces.items);

        var provider_catalog = try self.client.listProviderCatalog();
        defer provider_catalog.deinit(self.allocator);
        try self.view_model.replaceProviderCatalog(provider_catalog);

        var formatter_status = try self.client.listFormatterStatus();
        defer formatter_status.deinit(self.allocator);
        try self.view_model.replaceFormatterStatuses(formatter_status.items);

        var lsp_status = try self.client.listLspStatus();
        defer lsp_status.deinit(self.allocator);
        try self.view_model.replaceLspStatuses(lsp_status.items);

        var mcp_status = try self.client.listMcpStatus();
        defer mcp_status.deinit(self.allocator);
        try self.view_model.replaceMcpStatuses(mcp_status.items);

        var permissions = try self.client.listPermissions();
        defer permissions.deinit(self.allocator);
        try self.view_model.replacePendingPermissions(permissions.items);

        var questions = try self.client.listQuestions();
        defer questions.deinit(self.allocator);
        try self.view_model.replacePendingQuestions(questions.items);
    }

    fn handlePermissionCommand(self: *Self, input: []const u8) !void {
        var parts = std.mem.tokenizeScalar(u8, input, ' ');
        const id = parts.next() orelse return error.MissingPermissionId;
        const action = parts.next() orelse return error.MissingPermissionAction;
        if (std.mem.eql(u8, action, "once")) {
            _ = try self.client.replyPermission(id, .{ .reply = "once" });
            return;
        }
        if (std.mem.eql(u8, action, "reject")) {
            _ = try self.client.replyPermission(id, .{ .reply = "reject" });
            return;
        }
        return error.InvalidPermissionReply;
    }

    fn handleQuestionCommand(self: *Self, input: []const u8) !void {
        const first_space = std.mem.indexOfScalar(u8, input, ' ') orelse return error.MissingQuestionAnswer;
        const id = input[0..first_space];
        const spec = std.mem.trim(u8, input[first_space + 1 ..], " ");
        if (spec.len == 0) return error.MissingQuestionAnswer;

        var answer_sets = std.mem.splitScalar(u8, spec, ';');
        var answers = std.array_list.Managed(zig_opencode.server.QuestionAnswerDto).init(self.allocator);
        defer {
            for (answers.items) |*item| item.deinit(self.allocator);
            answers.deinit();
        }

        while (answer_sets.next()) |set| {
            const trimmed = std.mem.trim(u8, set, " ");
            if (trimmed.len == 0) continue;
            var selections_builder = std.array_list.Managed([]const u8).init(self.allocator);
            defer selections_builder.deinit();
            var selections = std.mem.splitScalar(u8, trimmed, ',');
            while (selections.next()) |item| {
                const selection = std.mem.trim(u8, item, " ");
                if (selection.len == 0) continue;
                try selections_builder.append(try self.allocator.dupe(u8, selection));
            }
            try answers.append(.{ .selections = try selections_builder.toOwnedSlice() });
        }

        _ = try self.client.replyQuestion(id, .{ .answers = answers.items });
    }

    fn refreshLatestResponse(self: *Self) !void {
        const session_id = self.view_model.active_session_id orelse return;
        var history = try self.client.listHistory(session_id);
        defer history.deinit(self.allocator);

        var idx: usize = history.items.len;
        while (idx > 0) {
            idx -= 1;
            const message = history.items[idx];
            if (!std.mem.eql(u8, message.role, "assistant")) continue;
            var out: std.ArrayListUnmanaged(u8) = .empty;
            defer out.deinit(self.allocator);
            
            for (message.parts) |part| {
                if (std.mem.eql(u8, part.kind, "text")) {
                    try out.appendSlice(self.allocator, part.text orelse "");
                }
            }
            if (out.items.len > 0) {
                try self.view_model.setLatestResponse(out.items);
                return;
            }
        }
    }
};

const SessionCreatedPayload = struct {
    sessionId: []const u8,
};

const SessionStatusPayload = struct {
    sessionId: []const u8,
    status: []const u8,
    requestId: []const u8,
};

const ToolCallPayload = struct {
    toolName: []const u8,
};

const ToolResultPayload = struct {
    toolName: []const u8,
};

pub fn runLocal(allocator: std.mem.Allocator, app_context: *zig_opencode.AppContext) !void {
    var services = zig_opencode.server.ServerServices.init(allocator, app_context);
    const local_ptr = try zig_opencode.client.LocalTransport.init(allocator, &services);
    var client = zig_opencode.client.Client.init(allocator, local_ptr.asTransport());
    defer client.deinit();

    var app = try TerminalApp.init(allocator, &client, .{});
    defer app.deinit();
    try app.runInteractive();
}

pub fn runAttached(allocator: std.mem.Allocator, base_url: []const u8) !void {
    const http_ptr = try zig_opencode.client.HttpTransport.init(allocator, base_url);
    var client = zig_opencode.client.Client.init(allocator, http_ptr.asTransport());
    defer client.deinit();

    var app = try TerminalApp.init(allocator, &client, .{});
    defer app.deinit();
    try app.runInteractive();
}

test "terminal app can submit a local prompt through client abstraction and render final assistant output" {
    const MockProvider = struct {
        fn createClient(allocator: std.mem.Allocator, ctx: zig_opencode.ProviderRegistry.ProviderCreateContext) !zig_opencode.ProviderClient {
            const Client = struct {
                allocator: std.mem.Allocator,
                const vtable = zig_opencode.ProviderClient.VTable{
                    .stream = streamErased,
                    .deinit = deinitErased,
                };
                fn asClient(self: *@This()) zig_opencode.ProviderClient {
                    return .{ .ptr = @ptrCast(self), .vtable = &vtable };
                }
                fn stream(_: *@This(), _: zig_opencode.provider.ProviderExecutionContext, _: zig_opencode.ProviderRequest, sink: zig_opencode.provider.LlmEventSink) !void {
                    try sink.onEvent(&.{ .text_delta = .{ .text = "hello from mock" } });
                    try sink.onEvent(&.{ .completed = .{ .stop_reason = "end_turn" } });
                }
                fn streamErased(ptr: *anyopaque, exec_ctx: zig_opencode.provider.ProviderExecutionContext, request: zig_opencode.ProviderRequest, sink: zig_opencode.provider.LlmEventSink) anyerror!void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    try self.stream(exec_ctx, request, sink);
                }
                fn deinitErased(ptr: *anyopaque, arena: std.mem.Allocator) void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    arena.destroy(self);
                }
            };
            _ = ctx;
            const client = try allocator.create(Client);
            client.* = .{ .allocator = allocator };
            return client.asClient();
        }
    };

    var fixture = try makeTuiFixture(std.testing.allocator);
    defer fixture.deinit();

    try fixture.app_context.provider_registry.registerProvider(.{
        .id = "mock",
        .display_name = "Mock",
        .default_model = .{ .provider_id = "mock", .model_id = "mock-model" },
    }, MockProvider.createClient);
    var attempt = try fixture.app_context.config_runtime.writeFields(&.{
        .{ .key = zig_opencode.config.keys.model_default, .value = .{ .string = "mock/mock-model" } },
    }, false);
    defer attempt.deinit();

    var services = zig_opencode.server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const local_ptr = try zig_opencode.client.LocalTransport.init(std.testing.allocator, &services);
    var client = zig_opencode.client.Client.init(std.testing.allocator, local_ptr.asTransport());
    defer client.deinit();

    var app = try TerminalApp.init(std.testing.allocator, &client, .{});
    defer app.deinit();

    var accepted = try app.submitPrompt("hello");
    defer accepted.deinit(std.testing.allocator);

    while (true) {
        _ = try app.pumpEvents(32);
        if (try app.sessionIsTerminal()) break;
        const _ts = std.c.timespec{ .sec = 0, .nsec = 10_000_000 }; _ = std.c.nanosleep(&_ts, null);
    }
    _ = try app.pumpEvents(64);

    try std.testing.expectEqualStrings("completed", app.view_model.status);
    try std.testing.expectEqualStrings("hello from mock", app.view_model.latest_response.?);
}

test "terminal app consumes local client event stream updates" {
    var fixture = try makeTuiFixture(std.testing.allocator);
    defer fixture.deinit();

    var services = zig_opencode.server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const local_ptr = try zig_opencode.client.LocalTransport.init(std.testing.allocator, &services);
    var client = zig_opencode.client.Client.init(std.testing.allocator, local_ptr.asTransport());
    defer client.deinit();

    var app = try TerminalApp.init(std.testing.allocator, &client, .{});
    defer app.deinit();

    try zig_opencode.session.publishSessionCreatedEvent(std.testing.allocator, fixture.app_context.eventBus(), .{
        .session_id = "session_01",
        .agent_id = "build",
        .title = "TUI",
    });
    try zig_opencode.session.publishSessionStatusEvent(std.testing.allocator, fixture.app_context.eventBus(), .{
        .session_id = "session_01",
        .status = "running",
        .request_id = "req_01",
    });
    try zig_opencode.session.publishToolCallEvent(std.testing.allocator, fixture.app_context.eventBus(), .{
        .request_id = "req_01",
        .session_id = "session_01",
        .call_id = "call_01",
        .tool_name = "read_file",
        .input_json = "{\"path\":\"x\"}",
    });

    _ = try app.pumpEvents(16);

    try std.testing.expectEqualStrings("session_01", app.view_model.active_session_id.?);
    try std.testing.expectEqualStrings("running", app.view_model.status);
    try std.testing.expectEqualStrings("read_file", app.view_model.recent_tool.?);
}

test "terminal app refreshes richer dashboard state and renders pending panel" {
    const MockGit = struct {
        fn run(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, argv: [][]const u8) anyerror!zig_opencode.project.runtime.RunOutput {
            if (std.mem.eql(u8, argv[2], "--show-toplevel")) {
                return .{ .stdout = try allocator.dupe(u8, "E:/repo\n"), .stderr = try allocator.alloc(u8, 0), .exit_code = 0 };
            }
            if (std.mem.eql(u8, argv[2], "--abbrev-ref")) {
                return .{ .stdout = try allocator.dupe(u8, "main\n"), .stderr = try allocator.alloc(u8, 0), .exit_code = 0 };
            }
            return .{ .stdout = try allocator.dupe(u8, " M src/app.zig\n"), .stderr = try allocator.alloc(u8, 0), .exit_code = 0 };
        }
    };

    var fixture = try makeTuiFixture(std.testing.allocator);
    defer fixture.deinit();
    fixture.app_context.project_runtime.vcs_executor = .{ .ptr = undefined, .run_fn = MockGit.run };

    const option_defs = [_]zig_opencode.question.QuestionOption{
        .{ .label = "A", .description = "alpha" },
    };
    const question_defs = [_]zig_opencode.question.QuestionInfo{
        .{
            .header = "Mode",
            .question = "Choose one",
            .options = @constCast(option_defs[0..]),
        },
    };
    var pending_question = try fixture.app_context.questionRuntime().createPending(.{
        .session_id = "session_01",
        .questions = @constCast(question_defs[0..]),
    });
    defer pending_question.deinit(std.testing.allocator);

    var pending_permission = try fixture.app_context.permissionRuntime().createPending(.{
        .session_id = "session_01",
        .permission = "edit",
        .patterns = @constCast(&[_][]const u8{"src/main.zig"}),
    });
    defer pending_permission.deinit(std.testing.allocator);

    var services = zig_opencode.server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const local_ptr = try zig_opencode.client.LocalTransport.init(std.testing.allocator, &services);
    var client = zig_opencode.client.Client.init(std.testing.allocator, local_ptr.asTransport());
    defer client.deinit();

    var app = try TerminalApp.init(std.testing.allocator, &client, .{});
    defer app.deinit();
    app.view_model.setPanel(.pending);

    const panel = try render.renderPanel(std.testing.allocator, &app.view_model);
    defer std.testing.allocator.free(panel);
    try std.testing.expect(std.mem.indexOf(u8, panel, "Permissions:") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "Questions:") != null);
}

test "terminal app can reply to pending permission and question commands" {
    var fixture = try makeTuiFixture(std.testing.allocator);
    defer fixture.deinit();

    const option_defs = [_]zig_opencode.question.QuestionOption{
        .{ .label = "A", .description = "alpha" },
    };
    const question_defs = [_]zig_opencode.question.QuestionInfo{
        .{
            .header = "Mode",
            .question = "Choose one",
            .options = @constCast(option_defs[0..]),
        },
    };
    var pending_question = try fixture.app_context.questionRuntime().createPending(.{
        .session_id = "session_01",
        .questions = @constCast(question_defs[0..]),
    });
    defer pending_question.deinit(std.testing.allocator);

    var pending_permission = try fixture.app_context.permissionRuntime().createPending(.{
        .session_id = "session_01",
        .permission = "edit",
        .patterns = @constCast(&[_][]const u8{"src/main.zig"}),
    });
    defer pending_permission.deinit(std.testing.allocator);

    var services = zig_opencode.server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const local_ptr = try zig_opencode.client.LocalTransport.init(std.testing.allocator, &services);
    var client = zig_opencode.client.Client.init(std.testing.allocator, local_ptr.asTransport());
    defer client.deinit();

    var app = try TerminalApp.init(std.testing.allocator, &client, .{});
    defer app.deinit();

    const permission_command = try std.fmt.allocPrint(std.testing.allocator, "{s} once", .{pending_permission.id});
    defer std.testing.allocator.free(permission_command);
    const question_command = try std.fmt.allocPrint(std.testing.allocator, "{s} A", .{pending_question.id});
    defer std.testing.allocator.free(question_command);

    try app.handlePermissionCommand(permission_command);
    try app.handleQuestionCommand(question_command);

    const permissions = try fixture.app_context.permissionRuntime().list(std.testing.allocator);
    defer {
        for (permissions) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(permissions);
    }
    try std.testing.expectEqual(@as(usize, 0), permissions.len);

    const questions = try fixture.app_context.questionRuntime().list(std.testing.allocator);
    defer {
        for (questions) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(questions);
    }
    try std.testing.expectEqual(@as(usize, 0), questions.len);
}

test "terminal app can attach through http transport abstraction and consume remote-style events" {
    var fixture = try makeTuiFixture(std.testing.allocator);
    defer fixture.deinit();

    const listener = try zig_opencode.server.ServerListener.init(std.testing.allocator, &fixture.app_context, .{
        .host = "127.0.0.1",
        .port = 0,
    });
    defer listener.deinit();

    const base_url = try listener.urlAlloc(std.testing.allocator);
    defer std.testing.allocator.free(base_url);

    const http_ptr = try zig_opencode.client.HttpTransport.init(std.testing.allocator, base_url);
    var client = zig_opencode.client.Client.init(std.testing.allocator, http_ptr.asTransport());
    defer client.deinit();

    var created = try client.createSession(.{ .title = "Attach" });
    defer created.deinit(std.testing.allocator);

    var app = try TerminalApp.init(std.testing.allocator, &client, .{});
    defer app.deinit();
    try app.attachSession(created.session_id);

    try zig_opencode.session.publishSessionStatusEvent(std.testing.allocator, fixture.app_context.eventBus(), .{
        .session_id = created.session_id,
        .status = "running",
        .request_id = "req_attach",
    });

    _ = try app.pumpEvents(16);

    try std.testing.expectEqualStrings(created.session_id, app.view_model.active_session_id.?);
    try std.testing.expectEqualStrings("running", app.view_model.status);
}

const TuiFixture = struct {
    tmp_dir: std.testing.TmpDir,
    root_path: []u8,
    project_dir: []u8,
    global_path: []u8,
    app_context: zig_opencode.AppContext,

    pub fn deinit(self: *TuiFixture) void {
        self.app_context.deinit();
        std.testing.allocator.free(self.global_path);
        std.testing.allocator.free(self.project_dir);
        std.testing.allocator.free(self.root_path);
        self.tmp_dir.cleanup();
    }
};

fn makeTuiFixture(allocator: std.mem.Allocator) !TuiFixture {
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    errdefer allocator.free(root_path);
    const project_dir = try std.fs.path.join(allocator, &.{ root_path, "workspace" });
    errdefer allocator.free(project_dir);
    _ = std.c.mkdir(@ptrCast(project_dir.ptr), 0o755);

    const config_path = try std.fs.path.join(allocator, &.{ project_dir, "opencode.json" });
    defer allocator.free(config_path);
    const global_path = try std.fs.path.join(allocator, &.{ root_path, "missing-global.json" });
    errdefer allocator.free(global_path);

    var file = try std.Io.Dir.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll(
        \\{
        \\  "agent": { "default": "build" },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );

    const app_context = try zig_opencode.AppContext.initWithConfigOptions(allocator, .{
        .console_log_enabled = false,
    }, .{
        .current_dir = project_dir,
        .global_config_path = global_path,
    });

    return .{
        .tmp_dir = tmp_dir,
        .root_path = root_path,
        .project_dir = project_dir,
        .global_path = global_path,
        .app_context = app_context,
    };
}
