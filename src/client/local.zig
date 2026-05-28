const std = @import("std");
const framework = @import("framework");
const pty_test_backend = @import("../pty/test_backend.zig");
const project_runtime = @import("../project/runtime.zig");
const server = @import("../server/root.zig");
const transport_model = @import("transport.zig");

pub const LocalTransport = struct {
    allocator: std.mem.Allocator,
    services: *server.ServerServices,

    const Self = @This();

    const vtable = transport_model.ClientTransport.VTable{
        .create_session = createSessionErased,
        .get_session = getSessionErased,
        .list_history = listHistoryErased,
        .submit_prompt = submitPromptErased,
        .abort_session = abortSessionErased,
        .list_status = listStatusErased,
        .list_lsp_status = listLspStatusErased,
        .list_formatter_status = listFormatterStatusErased,
        .list_mcp_status = listMcpStatusErased,
        .list_provider_catalog = listProviderCatalogErased,
        .list_provider_auth = listProviderAuthErased,
        .set_provider_auth = setProviderAuthErased,
        .remove_provider_auth = removeProviderAuthErased,
        .list_plugins = listPluginsErased,
        .list_skills = listSkillsErased,
        .get_project = getProjectErased,
        .list_workspaces = listWorkspacesErased,
        .create_workspace = createWorkspaceErased,
        .remove_workspace = removeWorkspaceErased,
        .create_pty = createPtyErased,
        .get_pty = getPtyErased,
        .list_ptys = listPtysErased,
        .write_pty_input = writePtyInputErased,
        .read_pty_output = readPtyOutputErased,
        .remove_pty = removePtyErased,
        .list_permissions = listPermissionsErased,
        .reply_permission = replyPermissionErased,
        .list_questions = listQuestionsErased,
        .reply_question = replyQuestionErased,
        .reject_question = rejectQuestionErased,
        .subscribe_events = subscribeEventsErased,
        .deinit = deinitErased,
    };

    pub fn init(allocator: std.mem.Allocator, services: *server.ServerServices) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .services = services,
        };
        return self;
    }

    pub fn asTransport(self: *Self) transport_model.ClientTransport {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn createSessionErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: server.CreateSessionRequest) anyerror!server.CreateSessionResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.createSession(request);
    }

    fn getSessionErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!?server.SessionResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.getSession(session_id);
    }

    fn listHistoryErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!server.HistoryResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listHistory(session_id);
    }

    fn submitPromptErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8, request: server.SubmitPromptRequest) anyerror!server.AcceptedResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.submitPrompt(session_id, request);
    }

    fn abortSessionErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!server.AbortResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.abortSession(session_id);
    }

    fn listStatusErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.StatusResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listStatuses();
    }

    fn listLspStatusErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.LspStatusResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listLspStatus();
    }

    fn listFormatterStatusErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.FormatterStatusResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listFormatterStatus();
    }

    fn listMcpStatusErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.McpStatusResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listMcpStatus();
    }

    fn listProviderCatalogErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.ProviderCatalogResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listProviderCatalog();
    }

    fn listProviderAuthErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.ProviderAuthListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listProviderAuth();
    }

    fn setProviderAuthErased(ptr: *anyopaque, allocator: std.mem.Allocator, provider_id: []const u8, request: server.ProviderAuthSetRequest) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.setProviderAuth(provider_id, request);
    }

    fn removeProviderAuthErased(ptr: *anyopaque, allocator: std.mem.Allocator, provider_id: []const u8) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.removeProviderAuth(provider_id);
    }

    fn listPluginsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.PluginListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listPlugins();
    }

    fn listSkillsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.SkillListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listSkills();
    }

    fn getProjectErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.ProjectResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.getProject();
    }

    fn listWorkspacesErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.WorkspaceListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listWorkspaces();
    }

    fn createWorkspaceErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: server.CreateWorkspaceRequest) anyerror!server.WorkspaceResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.createWorkspace(request);
    }

    fn removeWorkspaceErased(ptr: *anyopaque, allocator: std.mem.Allocator, workspace_id: []const u8) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.removeWorkspace(workspace_id);
    }

    fn createPtyErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: server.CreatePtyRequest) anyerror!server.PtyInfoResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.createPty(request);
    }

    fn getPtyErased(ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8) anyerror!?server.PtyInfoResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.getPty(pty_id);
    }

    fn listPtysErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.PtyListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listPtys();
    }

    fn writePtyInputErased(ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8, request: server.PtyInputRequest) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.writePtyInput(pty_id, request);
    }

    fn readPtyOutputErased(ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8, after_seq: u64, limit: usize, follow_ms: u64) anyerror!server.PtyOutputResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.readPtyOutput(pty_id, after_seq, limit, follow_ms);
    }

    fn removePtyErased(ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.removePty(pty_id);
    }

    fn listPermissionsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.PermissionListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listPermissions();
    }

    fn replyPermissionErased(ptr: *anyopaque, allocator: std.mem.Allocator, request_id: []const u8, request: server.PermissionReplyRequest) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.replyPermission(request_id, request);
    }

    fn listQuestionsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.QuestionListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.listQuestions();
    }

    fn replyQuestionErased(ptr: *anyopaque, allocator: std.mem.Allocator, request_id: []const u8, request: server.QuestionReplyRequest) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.replyQuestion(request_id, request);
    }

    fn rejectQuestionErased(ptr: *anyopaque, allocator: std.mem.Allocator, request_id: []const u8) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        return self.services.rejectQuestion(request_id);
    }

    fn subscribeEventsErased(ptr: *anyopaque, allocator: std.mem.Allocator, after_seq: u64) anyerror!transport_model.EventSubscription {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const subscription = try allocator.create(LocalEventSubscription);
        subscription.* = .{
            .allocator = allocator,
            .event_bus = self.services.app_context.eventBus(),
            .subscription_id = try self.services.app_context.eventBus().subscribe(&.{}, after_seq),
        };
        return subscription.asSubscription();
    }

    fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

const LocalEventSubscription = struct {
    allocator: std.mem.Allocator,
    event_bus: framework.EventBus,
    subscription_id: u64,

    const Self = @This();

    const vtable = transport_model.EventSubscription.VTable{
        .poll = pollErased,
        .deinit = deinitErased,
    };

    fn asSubscription(self: *Self) transport_model.EventSubscription {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn pollErased(ptr: *anyopaque, allocator: std.mem.Allocator, limit: usize) anyerror![]server.RuntimeEventDto {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var batch = try self.event_bus.pollSubscription(allocator, self.subscription_id, limit);
        defer batch.deinit(allocator);

        const events = try allocator.alloc(server.RuntimeEventDto, batch.events.len);
        errdefer allocator.free(events);
        for (batch.events, 0..) |event, index| {
            events[index] = .{
                .seq = event.seq,
                .topic = try allocator.dupe(u8, event.topic),
                .ts_unix_ms = event.ts_unix_ms,
                .payload_json = try allocator.dupe(u8, event.payload_json),
            };
        }
        return events;
    }

    fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.event_bus.unsubscribe(self.subscription_id) catch {};
        allocator.destroy(self);
    }
};

test "local transport preserves client boundary and returns session operations" {
    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const transport_ptr = try LocalTransport.init(std.testing.allocator, &services);
    defer transport_ptr.asTransport().deinit(std.testing.allocator);

    const transport = transport_ptr.asTransport();
    var created = try transport.createSession(std.testing.allocator, .{ .title = "Local" });
    defer created.deinit(std.testing.allocator);

    var accepted = try transport.submitPrompt(std.testing.allocator, created.session_id, .{ .text = "hello" });
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expect(accepted.accepted);

    var summary = try fixture.app_context.framework_app.task_runner.waitForCompletion(std.testing.allocator, accepted.task_id, 5000);
    defer summary.deinit(std.testing.allocator);

    var statuses = try transport.listStatus(std.testing.allocator);
    defer statuses.deinit(std.testing.allocator);
    try std.testing.expect(statuses.items.len >= 1);

    var lsp_status = try transport.listLspStatus(std.testing.allocator);
    defer lsp_status.deinit(std.testing.allocator);
    try std.testing.expect(lsp_status.items.len >= 0);

    var formatter_status = try transport.listFormatterStatus(std.testing.allocator);
    defer formatter_status.deinit(std.testing.allocator);
    try std.testing.expect(formatter_status.items.len >= 0);

    var mcp_status = try transport.listMcpStatus(std.testing.allocator);
    defer mcp_status.deinit(std.testing.allocator);
    try std.testing.expect(mcp_status.items.len >= 2);
}

test "local transport exposes permission and question interaction surfaces" {
    if (std.process.getEnvVarOwned(std.testing.allocator, "SKIP_PERMISSION_QUESTION_CLIENT_TEST")) |value| {
        std.testing.allocator.free(value);
        return error.SkipZigTest;
    } else |_| {}
    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const transport_ptr = try LocalTransport.init(std.testing.allocator, &services);
    defer transport_ptr.asTransport().deinit(std.testing.allocator);

    var pending_permission = try fixture.app_context.permissionRuntime().createPending(.{
        .session_id = "session_perm",
        .permission = "edit",
        .patterns = @constCast(&[_][]const u8{"src/main.zig"}),
    });
    defer pending_permission.deinit(std.testing.allocator);

    const transport = transport_ptr.asTransport();
    var permissions = try transport.listPermissions(std.testing.allocator);
    defer permissions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), permissions.items.len);
    try std.testing.expect((try transport.replyPermission(std.testing.allocator, permissions.items[0].id, .{ .reply = "once" })).ok);

    const option_defs = [_]@import("../question/root.zig").QuestionOption{
        .{ .label = "A", .description = "alpha" },
    };
    const question_defs = [_]@import("../question/root.zig").QuestionInfo{
        .{
            .header = "Mode",
            .question = "Choose one",
            .options = @constCast(option_defs[0..]),
        },
    };
    var pending_question = try fixture.app_context.questionRuntime().createPending(.{
        .session_id = "session_question",
        .questions = @constCast(question_defs[0..]),
    });
    defer pending_question.deinit(std.testing.allocator);

    var questions = try transport.listQuestions(std.testing.allocator);
    defer questions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), questions.items.len);

    var answers = [_]server.QuestionAnswerDto{
        .{ .selections = try @import("../question/root.zig").cloneStringSlice(std.testing.allocator, @constCast(&[_][]const u8{"A"})) },
    };
    defer answers[0].deinit(std.testing.allocator);
    try std.testing.expect((try transport.replyQuestion(std.testing.allocator, questions.items[0].id, .{ .answers = answers[0..] })).ok);
}

test "local transport exposes provider catalog and auth surfaces" {
    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const transport_ptr = try LocalTransport.init(std.testing.allocator, &services);
    defer transport_ptr.asTransport().deinit(std.testing.allocator);

    const transport = transport_ptr.asTransport();
    var catalog = try transport.listProviderCatalog(std.testing.allocator);
    defer catalog.deinit(std.testing.allocator);
    try std.testing.expect(catalog.default_model != null);

    {
        var auth_items = try transport.listProviderAuth(std.testing.allocator);
        defer auth_items.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), auth_items.items.len);
    }

    try std.testing.expect((try transport.setProviderAuth(std.testing.allocator, "anthropic", .{ .api_key = "secret" })).ok);

    {
        var auth_items = try transport.listProviderAuth(std.testing.allocator);
        defer auth_items.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), auth_items.items.len);
    }

    try std.testing.expect((try transport.removeProviderAuth(std.testing.allocator, "anthropic")).ok);
}

test "local transport exposes pty session flows" {
    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var mock_state = pty_test_backend.State{};
    fixture.app_context.pty_runtime.backend_factory = pty_test_backend.factory(&mock_state);
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const transport_ptr = try LocalTransport.init(std.testing.allocator, &services);
    defer transport_ptr.asTransport().deinit(std.testing.allocator);

    const transport = transport_ptr.asTransport();
    var created = try transport.createPty(std.testing.allocator, .{});
    defer created.deinit(std.testing.allocator);

    var listed = try transport.listPtys(std.testing.allocator);
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);

    try std.testing.expect((try transport.writePtyInput(std.testing.allocator, created.id, .{ .data = "echo local\n" })).ok);

    var output = try transport.readPtyOutput(std.testing.allocator, created.id, 0, 16, 0);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expectEqualStrings("echo local\n", output.items[0].data);

    try std.testing.expect((try transport.removePty(std.testing.allocator, created.id)).ok);
}

test "local transport exposes project and workspace surfaces" {
    const MockGit = struct {
        fn run(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, argv: [][]const u8) anyerror!project_runtime.RunOutput {
            if (std.mem.eql(u8, argv[2], "--show-toplevel")) {
                return .{
                    .stdout = try allocator.dupe(u8, "E:/repo\n"),
                    .stderr = try allocator.alloc(u8, 0),
                    .exit_code = 0,
                };
            }
            if (std.mem.eql(u8, argv[2], "--abbrev-ref")) {
                return .{
                    .stdout = try allocator.dupe(u8, "main\n"),
                    .stderr = try allocator.alloc(u8, 0),
                    .exit_code = 0,
                };
            }
            return .{
                .stdout = try allocator.dupe(u8, " M src/app.zig\n"),
                .stderr = try allocator.alloc(u8, 0),
                .exit_code = 0,
            };
        }
    };

    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    fixture.app_context.project_runtime.vcs_executor = .{ .ptr = undefined, .run_fn = MockGit.run };
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const transport_ptr = try LocalTransport.init(std.testing.allocator, &services);
    defer transport_ptr.asTransport().deinit(std.testing.allocator);

    const transport = transport_ptr.asTransport();
    var project_info = try transport.getProject(std.testing.allocator);
    defer project_info.deinit(std.testing.allocator);
    try std.testing.expect(project_info.vcs_available);

    var created = try transport.createWorkspace(std.testing.allocator, .{ .name = "demo" });
    defer created.deinit(std.testing.allocator);

    var listed = try transport.listWorkspaces(std.testing.allocator);
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);

    try std.testing.expect((try transport.removeWorkspace(std.testing.allocator, created.id)).ok);
}
