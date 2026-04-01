const std = @import("std");
const framework = @import("framework");
const app_context_model = @import("../app_context.zig");
const config = @import("../config/root.zig");
const provider = @import("../provider/root.zig");
const project = @import("../project/root.zig");
const plugin = @import("../plugin/root.zig");
const permission = @import("../permission/root.zig");
const pty = @import("../pty/root.zig");
const pty_test_backend = @import("../pty/test_backend.zig");
const question = @import("../question/root.zig");
const session = @import("../session/root.zig");
const skill = @import("../skill/root.zig");
const dto = @import("dto.zig");

pub const ServerServices = struct {
    allocator: std.mem.Allocator,
    app_context: *app_context_model.AppContext,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, app_context: *app_context_model.AppContext) Self {
        return .{
            .allocator = allocator,
            .app_context = app_context,
        };
    }

    pub fn createSession(self: *Self, request: dto.CreateSessionRequest) !dto.CreateSessionResponse {
        const profile = (try self.app_context.resolveAgentProfile(request.agent_id)) orelse return error.AgentProfileNotFound;
        var created = try self.app_context.sessionRuntime().createSession(request.title orelse "Session", profile.id);
        defer created.deinit(self.app_context.allocator);
        return dto.fromCreatedSession(self.allocator, created);
    }

    pub fn getSession(self: *Self, session_id: []const u8) !?dto.SessionResponse {
        var session_info = (try self.app_context.sessionStore().getSession(self.allocator, session_id)) orelse return null;
        defer session_info.deinit(self.allocator);
        return try dto.fromSessionInfo(self.allocator, session_info);
    }

    pub fn listHistory(self: *Self, session_id: []const u8) !dto.HistoryResponse {
        const history = try self.app_context.sessionRuntime().listHistory(self.allocator, session_id);
        defer {
            for (history) |*message| message.deinit(self.allocator);
            self.allocator.free(history);
        }
        return dto.fromHistory(self.allocator, history);
    }

    pub fn submitPrompt(self: *Self, session_id: []const u8, request: dto.SubmitPromptRequest) !dto.AcceptedResponse {
        var prompt_message = try self.app_context.sessionRuntime().submitPrompt(.{
            .session_id = session_id,
            .parts = &.{.{ .text = request.text }},
        });
        defer prompt_message.deinit(self.app_context.allocator);

        const request_id = try std.fmt.allocPrint(self.allocator, "ipc_req_{d}", .{std.time.milliTimestamp()});
        errdefer self.allocator.free(request_id);
        const model_ref = if (request.model) |raw_model|
            try parseModelRef(self.allocator, raw_model)
        else
            null;
        defer if (model_ref) |ref| {
            var owned = ref;
            owned.deinit(self.allocator);
        };

        const accepted = try self.app_context.sessionRuntime().submitAgentTask(.{
            .session_id = session_id,
            .agent_id = request.agent_id,
            .category = request.category,
            .model = model_ref,
            .request_id = request_id,
        });

        return .{
            .session_id = try self.allocator.dupe(u8, session_id),
            .request_id = request_id,
            .task_id = try self.allocator.dupe(u8, accepted.task_id),
            .accepted = true,
        };
    }

    pub fn abortSession(self: *Self, session_id: []const u8) !dto.AbortResponse {
        const cancelled = try self.app_context.sessionRuntime().abortSession(self.allocator, session_id);
        return .{
            .session_id = try self.allocator.dupe(u8, session_id),
            .cancelled = cancelled,
        };
    }

    pub fn listStatuses(self: *Self) !dto.StatusResponse {
        const statuses = try self.app_context.sessionRuntime().listSessionStatuses(self.allocator);
        defer {
            for (statuses) |*status_info| status_info.deinit(self.allocator);
            self.allocator.free(statuses);
        }

        const items = try self.allocator.alloc(dto.SessionStatusDto, statuses.len);
        errdefer self.allocator.free(items);

        for (statuses, 0..) |status_info, index| {
            items[index] = try dto.fromStatusInfo(self.allocator, status_info);
            errdefer items[index].deinit(self.allocator);
        }
        return .{ .items = items };
    }

    pub fn getProject(self: *Self) !dto.ProjectResponse {
        var info = try self.app_context.projectRuntime().currentProject(self.allocator);
        defer info.deinit(self.allocator);
        return dto.fromProjectInfo(self.allocator, info);
    }

    pub fn listWorkspaces(self: *Self) !dto.WorkspaceListResponse {
        const items = try self.app_context.projectRuntime().listWorkspaces(self.allocator);
        defer project.freeWorkspaces(self.allocator, items);

        const responses = try self.allocator.alloc(dto.WorkspaceResponse, items.len);
        errdefer self.allocator.free(responses);
        for (items, 0..) |item, index| {
            responses[index] = try dto.fromWorkspaceInfo(self.allocator, item);
            errdefer responses[index].deinit(self.allocator);
        }
        return .{ .items = responses };
    }

    pub fn listPlugins(self: *Self) !dto.PluginListResponse {
        const items = try self.app_context.pluginRuntime().list(self.allocator);
        defer {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
        }

        const responses = try self.allocator.alloc(dto.PluginResponse, items.len);
        errdefer self.allocator.free(responses);
        for (items, 0..) |item, index| {
            responses[index] = try dto.fromPluginInfo(self.allocator, item);
            errdefer responses[index].deinit(self.allocator);
        }
        return .{ .items = responses };
    }

    pub fn listSkills(self: *Self) !dto.SkillListResponse {
        const items = try self.app_context.skillRuntime().list(self.allocator);
        defer {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
        }

        const responses = try self.allocator.alloc(dto.SkillResponse, items.len);
        errdefer self.allocator.free(responses);
        for (items, 0..) |item, index| {
            responses[index] = try dto.fromSkillInfo(self.allocator, item);
            errdefer responses[index].deinit(self.allocator);
        }
        return .{ .items = responses };
    }

    pub fn createWorkspace(self: *Self, request: dto.CreateWorkspaceRequest) !dto.WorkspaceResponse {
        var info = try self.app_context.projectRuntime().createWorkspace(self.allocator, .{ .name = request.name });
        defer info.deinit(self.allocator);
        return dto.fromWorkspaceInfo(self.allocator, info);
    }

    pub fn removeWorkspace(self: *Self, workspace_id: []const u8) !dto.AckResponse {
        return .{ .ok = try self.app_context.projectRuntime().removeWorkspace(workspace_id) };
    }

    pub fn listLspStatus(self: *Self) !dto.LspStatusResponse {
        const statuses = try self.app_context.lspRuntime().status(self.allocator);
        defer {
            for (statuses) |*status_info| status_info.deinit(self.allocator);
            self.allocator.free(statuses);
        }

        const items = try self.allocator.alloc(dto.LspStatusDto, statuses.len);
        errdefer self.allocator.free(items);

        for (statuses, 0..) |status_info, index| {
            items[index] = try dto.fromLspStatus(self.allocator, status_info);
            errdefer items[index].deinit(self.allocator);
        }
        return .{ .items = items };
    }

    pub fn listFormatterStatus(self: *Self) !dto.FormatterStatusResponse {
        const statuses = try self.app_context.formatterRuntime().status(self.allocator);
        defer {
            for (statuses) |*status_info| status_info.deinit(self.allocator);
            self.allocator.free(statuses);
        }

        const items = try self.allocator.alloc(dto.FormatterStatusDto, statuses.len);
        errdefer self.allocator.free(items);
        for (statuses, 0..) |status_info, index| {
            items[index] = try dto.fromFormatterStatus(self.allocator, status_info);
            errdefer items[index].deinit(self.allocator);
        }
        return .{ .items = items };
    }

    pub fn listMcpStatus(self: *Self) !dto.McpStatusResponse {
        const statuses = try self.app_context.mcpRuntime().status(self.allocator);
        defer {
            for (statuses) |*status_info| status_info.deinit(self.allocator);
            self.allocator.free(statuses);
        }

        const items = try self.allocator.alloc(dto.McpStatusDto, statuses.len);
        errdefer self.allocator.free(items);

        for (statuses, 0..) |status_info, index| {
            items[index] = try dto.fromMcpStatus(self.allocator, status_info);
            errdefer items[index].deinit(self.allocator);
        }
        return .{ .items = items };
    }

    pub fn listProviderCatalog(self: *Self) !dto.ProviderCatalogResponse {
        var effective = try self.app_context.effectiveConfig(self.allocator);
        defer effective.deinit(self.allocator);

        const catalog = try self.app_context.provider_registry.catalog(self.allocator);
        defer {
            for (catalog) |*item| item.deinit(self.allocator);
            self.allocator.free(catalog);
        }

        const providers = try self.allocator.alloc(dto.ProviderCatalogProviderDto, catalog.len);
        errdefer self.allocator.free(providers);
        for (catalog, 0..) |item, index| {
            providers[index] = try dto.fromProviderCatalogEntry(self.allocator, item);
            errdefer providers[index].deinit(self.allocator);
        }

        const effective_default_model = if (effective.model.default_model) |model|
            if (self.app_context.provider_registry.isModelReady(model))
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ model.provider_id, model.model_id })
            else if (self.app_context.provider_registry.defaultModel()) |fallback_model|
                try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ fallback_model.provider_id, fallback_model.model_id })
            else
                null
        else if (self.app_context.provider_registry.defaultModel()) |model|
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ model.provider_id, model.model_id })
        else
            null;

        return .{
            .default_model = effective_default_model,
            .providers = providers,
        };
    }

    pub fn listProviderAuth(self: *Self) !dto.ProviderAuthListResponse {
        const items = try self.app_context.providerAuthRuntime().list(self.allocator);
        defer {
            for (items) |*item| item.deinit(self.allocator);
            self.allocator.free(items);
        }

        const converted = try self.allocator.alloc(dto.ProviderAuthStatusDto, items.len);
        errdefer self.allocator.free(converted);
        for (items, 0..) |item, index| {
            converted[index] = try dto.fromProviderAuthStatus(self.allocator, item);
            errdefer converted[index].deinit(self.allocator);
        }
        return .{ .items = converted };
    }

    pub fn createPty(self: *Self, request: dto.CreatePtyRequest) !dto.PtyInfoResponse {
        var info = try self.app_context.ptyRuntime().create(.{
            .cwd = request.cwd orelse self.app_context.config_runtime.resolved_paths.current_dir,
            .shell = request.shell,
        });
        defer info.deinit(self.allocator);
        return dto.fromPtyInfo(self.allocator, info);
    }

    pub fn getPty(self: *Self, pty_id: []const u8) !?dto.PtyInfoResponse {
        var info = (try self.app_context.ptyRuntime().get(self.allocator, pty_id)) orelse return null;
        defer info.deinit(self.allocator);
        return try dto.fromPtyInfo(self.allocator, info);
    }

    pub fn listPtys(self: *Self) !dto.PtyListResponse {
        const infos = try self.app_context.ptyRuntime().list(self.allocator);
        defer pty.types.freeInfos(self.allocator, infos);

        const items = try self.allocator.alloc(dto.PtyInfoResponse, infos.len);
        errdefer self.allocator.free(items);
        for (infos, 0..) |info, index| {
            items[index] = try dto.fromPtyInfo(self.allocator, info);
            errdefer items[index].deinit(self.allocator);
        }
        return .{ .items = items };
    }

    pub fn removePty(self: *Self, pty_id: []const u8) !dto.AckResponse {
        return .{ .ok = try self.app_context.ptyRuntime().remove(pty_id) };
    }

    pub fn writePtyInput(self: *Self, pty_id: []const u8, request: dto.PtyInputRequest) !dto.AckResponse {
        return .{ .ok = try self.app_context.ptyRuntime().writeInput(pty_id, request.data) };
    }

    pub fn readPtyOutput(self: *Self, pty_id: []const u8, after_seq: u64, limit: usize, follow_ms: u64) !dto.PtyOutputResponse {
        const chunks = try self.app_context.ptyRuntime().readOutput(self.allocator, pty_id, after_seq, limit, follow_ms);
        defer pty.types.freeChunks(self.allocator, chunks);

        const items = try self.allocator.alloc(dto.PtyOutputChunkDto, chunks.len);
        errdefer self.allocator.free(items);
        for (chunks, 0..) |chunk, index| {
            items[index] = try dto.fromPtyChunk(self.allocator, chunk);
            errdefer items[index].deinit(self.allocator);
        }
        return .{ .items = items };
    }

    pub fn setProviderAuth(self: *Self, provider_id: []const u8, request: dto.ProviderAuthSetRequest) !dto.AckResponse {
        try self.app_context.providerAuthRuntime().setApiKey(provider_id, request.api_key);
        return .{ .ok = true };
    }

    pub fn removeProviderAuth(self: *Self, provider_id: []const u8) !dto.AckResponse {
        return .{ .ok = try self.app_context.providerAuthRuntime().remove(provider_id) };
    }

    pub fn listPermissions(self: *Self) !dto.PermissionListResponse {
        const items = try self.app_context.permissionRuntime().list(self.allocator);
        return .{ .items = items };
    }

    pub fn replyPermission(self: *Self, request_id: []const u8, request: dto.PermissionReplyRequest) !dto.AckResponse {
        const reply = permission.PermissionReply.fromText(request.reply) orelse return error.InvalidPermissionReply;
        const ok = try self.app_context.permissionRuntime().reply(request_id, reply);
        return .{ .ok = ok };
    }

    pub fn listQuestions(self: *Self) !dto.QuestionListResponse {
        const items = try self.app_context.questionRuntime().list(self.allocator);
        return .{ .items = items };
    }

    pub fn replyQuestion(self: *Self, request_id: []const u8, request: dto.QuestionReplyRequest) !dto.AckResponse {
        const answers = try convertQuestionAnswers(self.allocator, request.answers);
        defer question.freeAnswers(self.allocator, answers);
        const ok = try self.app_context.questionRuntime().reply(request_id, answers);
        return .{ .ok = ok };
    }

    pub fn rejectQuestion(self: *Self, request_id: []const u8) !dto.AckResponse {
        const ok = try self.app_context.questionRuntime().reject(request_id);
        return .{ .ok = ok };
    }

    pub fn projectEvents(self: *Self, after_seq: u64, limit: usize, follow_ms: u64) ![]framework.RuntimeEvent {
        const subscription_id = try self.app_context.eventBus().subscribe(&.{}, after_seq);
        defer self.app_context.eventBus().unsubscribe(subscription_id) catch {};

        var collected: std.ArrayListUnmanaged(framework.RuntimeEvent) = .empty;
        errdefer {
            for (collected.items) |*event| event.deinit(self.allocator);
            collected.deinit(self.allocator);
        }

        const started_at = std.time.milliTimestamp();
        while (true) {
            var batch = try self.app_context.eventBus().pollSubscription(self.allocator, subscription_id, if (limit == 0) 64 else limit - collected.items.len);
            defer batch.deinit(self.allocator);

            for (batch.events) |event| {
                try collected.append(self.allocator, try event.clone(self.allocator));
                if (limit != 0 and collected.items.len >= limit) {
                    return collected.toOwnedSlice(self.allocator);
                }
            }

            if (collected.items.len > 0) {
                return collected.toOwnedSlice(self.allocator);
            }
            if (follow_ms == 0) {
                return collected.toOwnedSlice(self.allocator);
            }
            if (std.time.milliTimestamp() - started_at >= @as(i64, @intCast(follow_ms))) {
                return collected.toOwnedSlice(self.allocator);
            }
            std.Thread.sleep(10 * std.time.ns_per_ms);
        }
    }
};

fn parseModelRef(allocator: std.mem.Allocator, raw: []const u8) !provider.ModelRef {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse return error.InvalidModelRef;
    if (slash == 0 or slash + 1 >= raw.len) return error.InvalidModelRef;
    return .{
        .provider_id = try allocator.dupe(u8, raw[0..slash]),
        .model_id = try allocator.dupe(u8, raw[slash + 1 ..]),
    };
}

test "server services create session submit prompt and report status" {
    var fixture = try makeServerFixture(std.testing.allocator);
    defer fixture.deinit();

    var services = ServerServices.init(std.testing.allocator, &fixture.app_context);

    var created = try services.createSession(.{ .title = "IPC" });
    defer created.deinit(std.testing.allocator);

    var accepted = try services.submitPrompt(created.session_id, .{ .text = "hello" });
    defer accepted.deinit(std.testing.allocator);

    try std.testing.expect(accepted.accepted);

    var summary = try fixture.app_context.framework_app.task_runner.waitForCompletion(std.testing.allocator, accepted.task_id, 5000);
    defer summary.deinit(std.testing.allocator);
    try std.testing.expectEqual(framework.TaskState.succeeded, summary.state);

    var statuses = try services.listStatuses();
    defer statuses.deinit(std.testing.allocator);
    try std.testing.expect(statuses.items.len >= 1);

    var lsp_status = try services.listLspStatus();
    defer lsp_status.deinit(std.testing.allocator);
    try std.testing.expect(lsp_status.items.len >= 0);

    var mcp_status = try services.listMcpStatus();
    defer mcp_status.deinit(std.testing.allocator);
    try std.testing.expect(mcp_status.items.len >= 2);

    var history = try services.listHistory(created.session_id);
    defer history.deinit(std.testing.allocator);
    try std.testing.expect(history.items.len >= 2);
}

test "server services expose pending permission and question interactions" {
    if (std.process.getEnvVarOwned(std.testing.allocator, "SKIP_PERMISSION_QUESTION_SERVICE_TEST")) |value| {
        std.testing.allocator.free(value);
        return error.SkipZigTest;
    } else |_| {}
    var fixture = try makeServerFixture(std.testing.allocator);
    defer fixture.deinit();

    var services = ServerServices.init(std.testing.allocator, &fixture.app_context);
    var pending_permission = try fixture.app_context.permissionRuntime().createPending(.{
        .session_id = "session_perm",
        .permission = "edit",
        .patterns = @constCast(&[_][]const u8{"src/main.zig"}),
    });
    defer pending_permission.deinit(std.testing.allocator);

    var pending_permissions = try services.listPermissions();
    defer pending_permissions.deinit(std.testing.allocator);
    try std.testing.expect((try services.replyPermission(pending_permissions.items[0].id, .{ .reply = "once" })).ok);

    const option_defs = [_]question.QuestionOption{
        .{ .label = "A", .description = "alpha" },
    };
    const question_defs = [_]question.QuestionInfo{
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

    var pending_questions = try services.listQuestions();
    defer pending_questions.deinit(std.testing.allocator);
    var answer_payload = [_]dto.QuestionAnswerDto{
        .{ .selections = try question.cloneStringSlice(std.testing.allocator, @constCast(&[_][]const u8{"A"})) },
    };
    defer {
        var answer = answer_payload[0];
        answer.deinit(std.testing.allocator);
    }
    try std.testing.expect((try services.replyQuestion(pending_questions.items[0].id, .{
        .answers = answer_payload[0..],
    })).ok);
}

test "server services expose provider catalog and auth surfaces" {
    var fixture = try makeServerFixture(std.testing.allocator);
    defer fixture.deinit();

    var services = ServerServices.init(std.testing.allocator, &fixture.app_context);

    var catalog = try services.listProviderCatalog();
    defer catalog.deinit(std.testing.allocator);
    try std.testing.expect(catalog.default_model != null);
    try std.testing.expectEqualStrings("mock/mock-model", catalog.default_model.?);
    try std.testing.expect(catalog.providers.len >= 2);

    {
        var auth_items = try services.listProviderAuth();
        defer auth_items.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), auth_items.items.len);
    }

    try std.testing.expect((try services.setProviderAuth("anthropic", .{ .api_key = "secret" })).ok);
    {
        var auth_items = try services.listProviderAuth();
        defer auth_items.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 1), auth_items.items.len);
        try std.testing.expectEqualStrings("anthropic", auth_items.items[0].provider_id);
    }

    try std.testing.expect((try services.removeProviderAuth("anthropic")).ok);
}

test "server services expose formatter status surface" {
    var fixture = try makeServerFixture(std.testing.allocator);
    defer fixture.deinit();

    var services = ServerServices.init(std.testing.allocator, &fixture.app_context);
    var statuses = try services.listFormatterStatus();
    defer statuses.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), statuses.items.len);
}

test "server services expose pty lifecycle and output flow" {
    var fixture = try makeServerFixture(std.testing.allocator);
    defer fixture.deinit();

    var mock_state = pty_test_backend.State{};
    fixture.app_context.pty_runtime.backend_factory = pty_test_backend.factory(&mock_state);

    var services = ServerServices.init(std.testing.allocator, &fixture.app_context);
    var created = try services.createPty(.{});
    defer created.deinit(std.testing.allocator);

    var listed = try services.listPtys();
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);

    try std.testing.expect((try services.writePtyInput(created.id, .{ .data = "echo hello\n" })).ok);

    var output = try services.readPtyOutput(created.id, 0, 16, 0);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expectEqualStrings("echo hello\n", output.items[0].data);

    try std.testing.expect((try services.removePty(created.id)).ok);
}

test "server services expose project and workspace surfaces" {
    const MockGit = struct {
        fn run(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, argv: [][]const u8) anyerror!project.runtime.RunOutput {
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

    var fixture = try makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    fixture.app_context.project_runtime.vcs_executor = .{ .ptr = undefined, .run_fn = MockGit.run };

    var services = ServerServices.init(std.testing.allocator, &fixture.app_context);
    var project_info = try services.getProject();
    defer project_info.deinit(std.testing.allocator);
    try std.testing.expect(project_info.vcs_available);
    try std.testing.expectEqualStrings("main", project_info.branch.?);

    var created = try services.createWorkspace(.{ .name = "demo" });
    defer created.deinit(std.testing.allocator);

    var listed = try services.listWorkspaces();
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);
    try std.testing.expectEqualStrings("demo", listed.items[0].name);

    try std.testing.expect((try services.removeWorkspace(created.id)).ok);
}

fn convertQuestionAnswers(allocator: std.mem.Allocator, input: []const dto.QuestionAnswerDto) ![]question.QuestionAnswer {
    const answers = try allocator.alloc(question.QuestionAnswer, input.len);
    errdefer allocator.free(answers);
    for (input, 0..) |item, index| {
        answers[index] = .{
            .selections = try question.cloneStringSlice(allocator, item.selections),
        };
        errdefer answers[index].deinit(allocator);
    }
    return answers;
}

const ServerFixture = struct {
    tmp_dir: std.testing.TmpDir,
    root_path: []u8,
    project_dir: []u8,
    global_path: []u8,
    app_context: app_context_model.AppContext,

    pub fn deinit(self: *ServerFixture) void {
        self.app_context.deinit();
        std.testing.allocator.free(self.global_path);
        std.testing.allocator.free(self.project_dir);
        std.testing.allocator.free(self.root_path);
        self.tmp_dir.cleanup();
    }
};

pub fn makeServerFixture(allocator: std.mem.Allocator) !ServerFixture {
    var tmp_dir = std.testing.tmpDir(.{});
    errdefer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(allocator, ".");
    errdefer allocator.free(root_path);
    const project_dir = try std.fs.path.join(allocator, &.{ root_path, "workspace" });
    errdefer allocator.free(project_dir);
    try std.fs.cwd().makePath(project_dir);

    const config_path = try std.fs.path.join(allocator, &.{ project_dir, "opencode.json" });
    defer allocator.free(config_path);
    const global_path = try std.fs.path.join(allocator, &.{ root_path, "missing-global.json" });
    errdefer allocator.free(global_path);

    var file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll(
        \\{
        \\  "agent": { "default": "build" },
        \\  "mcp": { "servers": [
        \\    { "id": "disabled-docs", "type": "remote", "url": "http://example.invalid", "disabled": true },
        \\    { "id": "failing-docs", "type": "remote", "url": "http://example.invalid" }
        \\  ] },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );

    var app_context = try app_context_model.AppContext.initWithConfigOptions(allocator, .{
        .console_log_enabled = false,
    }, .{
        .current_dir = project_dir,
        .global_config_path = global_path,
    });

    const MockProvider = struct {
        fn createClient(alloc: std.mem.Allocator, ctx: provider.ProviderRegistry.ProviderCreateContext) !provider.ProviderClient {
            const Client = struct {
                allocator: std.mem.Allocator,

                const vtable = provider.ProviderClient.VTable{
                    .stream = streamErased,
                    .deinit = deinitErased,
                };

                fn asClient(self: *@This()) provider.ProviderClient {
                    return .{ .ptr = @ptrCast(self), .vtable = &vtable };
                }

                fn stream(_: *@This(), _: provider.ProviderExecutionContext, _: provider.ProviderRequest, sink: provider.LlmEventSink) !void {
                    try sink.onEvent(&.{ .text_delta = .{ .text = "server fixture response" } });
                    try sink.onEvent(&.{ .completed = .{ .stop_reason = "end_turn" } });
                }

                fn streamErased(ptr: *anyopaque, exec_ctx: provider.ProviderExecutionContext, request: provider.ProviderRequest, sink: provider.LlmEventSink) anyerror!void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    try self.stream(exec_ctx, request, sink);
                }

                fn deinitErased(ptr: *anyopaque, arena: std.mem.Allocator) void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    arena.destroy(self);
                }
            };

            _ = ctx;
            const client = try alloc.create(Client);
            client.* = .{ .allocator = alloc };
            return client.asClient();
        }
    };

    try app_context.provider_registry.registerProvider(.{
        .id = "mock",
        .display_name = "Mock",
        .default_model = .{ .provider_id = "mock", .model_id = "mock-model" },
    }, MockProvider.createClient);

    var attempt = try app_context.config_runtime.writeFields(&.{
        .{ .key = config.keys.model_default, .value = .{ .string = "mock/mock-model" } },
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
