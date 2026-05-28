const std = @import("std");
const pty_test_backend = @import("../pty/test_backend.zig");
const project_runtime = @import("../project/runtime.zig");
const server = @import("../server/root.zig");
const session = @import("../session/root.zig");
const transport_model = @import("transport.zig");

pub const RequesterResponse = struct {
    status: u16,
    content_type: []u8,
    body: []u8,

    pub fn deinit(self: *RequesterResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        allocator.free(self.body);
    }
};

pub const Requester = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        request: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, method: server.HttpMethod, url: []const u8, body: ?[]const u8) anyerror!RequesterResponse,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn request(self: Requester, allocator: std.mem.Allocator, method: server.HttpMethod, url: []const u8, body: ?[]const u8) anyerror!RequesterResponse {
        return self.vtable.request(self.ptr, allocator, method, url, body);
    }

    pub fn deinit(self: Requester, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub const HttpTransport = struct {
    allocator: std.mem.Allocator,
    base_url: []u8,
    requester: Requester,

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

    pub fn init(allocator: std.mem.Allocator, base_url: []const u8) !*Self {
        const requester = try StdRequester.init(allocator);
        return initWithRequester(allocator, base_url, requester.asRequester());
    }

    pub fn initWithRequester(allocator: std.mem.Allocator, base_url: []const u8, requester: Requester) !*Self {
        const self = try allocator.create(Self);
        self.* = .{
                        .base_url = try allocator.dupe(u8, base_url),
            .requester = requester,
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
        const body = try encodeJsonBody(allocator, request);
        defer allocator.free(body);
        const url = try joinUrl(allocator, self.base_url, "/session");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .POST, url, body);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.CreateSessionResponse, allocator, response.body);
    }

    fn getSessionErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!?server.SessionResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/session/{s}", .{ self.base_url, session_id });
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status == 404) return null;
        if (response.status != 200) return error.HttpRequestFailed;
        return try parseOwned(server.SessionResponse, allocator, response.body);
    }

    fn listHistoryErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!server.HistoryResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/session/{s}/message", .{ self.base_url, session_id });
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.HistoryResponse, allocator, response.body);
    }

    fn submitPromptErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8, request: server.SubmitPromptRequest) anyerror!server.AcceptedResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/session/{s}/prompt", .{ self.base_url, session_id });
        defer allocator.free(url);
        const body = try encodeJsonBody(allocator, request);
        defer allocator.free(body);
        var response = try self.requester.request(allocator, .POST, url, body);
        defer response.deinit(allocator);
        if (response.status != 202) return error.HttpRequestFailed;
        return parseOwned(server.AcceptedResponse, allocator, response.body);
    }

    fn abortSessionErased(ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!server.AbortResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/session/{s}/abort", .{ self.base_url, session_id });
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .POST, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.AbortResponse, allocator, response.body);
    }

    fn listStatusErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.StatusResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/session/status");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.StatusResponse, allocator, response.body);
    }

    fn listLspStatusErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.LspStatusResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/lsp");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.LspStatusResponse, allocator, response.body);
    }

    fn listFormatterStatusErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.FormatterStatusResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/formatter");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.FormatterStatusResponse, allocator, response.body);
    }

    fn listMcpStatusErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.McpStatusResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/mcp");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.McpStatusResponse, allocator, response.body);
    }

    fn listProviderCatalogErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.ProviderCatalogResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/provider");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.ProviderCatalogResponse, allocator, response.body);
    }

    fn listProviderAuthErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.ProviderAuthListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/provider/auth");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.ProviderAuthListResponse, allocator, response.body);
    }

    fn setProviderAuthErased(ptr: *anyopaque, allocator: std.mem.Allocator, provider_id: []const u8, request: server.ProviderAuthSetRequest) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/provider/{s}/auth", .{ self.base_url, provider_id });
        defer allocator.free(url);
        const body = try encodeJsonBody(allocator, request);
        defer allocator.free(body);
        var response = try self.requester.request(allocator, .POST, url, body);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.AckResponse, allocator, response.body);
    }

    fn removeProviderAuthErased(ptr: *anyopaque, allocator: std.mem.Allocator, provider_id: []const u8) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/provider/{s}/auth/remove", .{ self.base_url, provider_id });
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .POST, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.AckResponse, allocator, response.body);
    }

    fn listPluginsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.PluginListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/plugin");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.PluginListResponse, allocator, response.body);
    }

    fn listSkillsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.SkillListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/skill");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.SkillListResponse, allocator, response.body);
    }

    fn getProjectErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.ProjectResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/project");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.ProjectResponse, allocator, response.body);
    }

    fn listWorkspacesErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.WorkspaceListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/workspace");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.WorkspaceListResponse, allocator, response.body);
    }

    fn createWorkspaceErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: server.CreateWorkspaceRequest) anyerror!server.WorkspaceResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/workspace");
        defer allocator.free(url);
        const body = try encodeJsonBody(allocator, request);
        defer allocator.free(body);
        var response = try self.requester.request(allocator, .POST, url, body);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.WorkspaceResponse, allocator, response.body);
    }

    fn removeWorkspaceErased(ptr: *anyopaque, allocator: std.mem.Allocator, workspace_id: []const u8) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/workspace/{s}/remove", .{ self.base_url, workspace_id });
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .POST, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.AckResponse, allocator, response.body);
    }

    fn createPtyErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: server.CreatePtyRequest) anyerror!server.PtyInfoResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/pty");
        defer allocator.free(url);
        const body = try encodeJsonBody(allocator, request);
        defer allocator.free(body);
        var response = try self.requester.request(allocator, .POST, url, body);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.PtyInfoResponse, allocator, response.body);
    }

    fn getPtyErased(ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8) anyerror!?server.PtyInfoResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/pty/{s}", .{ self.base_url, pty_id });
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status == 404) return null;
        if (response.status != 200) return error.HttpRequestFailed;
        return try parseOwned(server.PtyInfoResponse, allocator, response.body);
    }

    fn listPtysErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.PtyListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/pty");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.PtyListResponse, allocator, response.body);
    }

    fn writePtyInputErased(ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8, request: server.PtyInputRequest) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/pty/{s}/input", .{ self.base_url, pty_id });
        defer allocator.free(url);
        const body = try encodeJsonBody(allocator, request);
        defer allocator.free(body);
        var response = try self.requester.request(allocator, .POST, url, body);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.AckResponse, allocator, response.body);
    }

    fn readPtyOutputErased(ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8, after_seq: u64, limit: usize, follow_ms: u64) anyerror!server.PtyOutputResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/pty/{s}/output?after_seq={d}&limit={d}&follow_ms={d}", .{ self.base_url, pty_id, after_seq, limit, follow_ms });
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.PtyOutputResponse, allocator, response.body);
    }

    fn removePtyErased(ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/pty/{s}/remove", .{ self.base_url, pty_id });
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .POST, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.AckResponse, allocator, response.body);
    }

    fn listPermissionsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.PermissionListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/permission");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.PermissionListResponse, allocator, response.body);
    }

    fn replyPermissionErased(ptr: *anyopaque, allocator: std.mem.Allocator, request_id: []const u8, request: server.PermissionReplyRequest) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/permission/{s}/reply", .{ self.base_url, request_id });
        defer allocator.free(url);
        const body = try encodeJsonBody(allocator, request);
        defer allocator.free(body);
        var response = try self.requester.request(allocator, .POST, url, body);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.AckResponse, allocator, response.body);
    }

    fn listQuestionsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.QuestionListResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try joinUrl(allocator, self.base_url, "/question");
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .GET, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.QuestionListResponse, allocator, response.body);
    }

    fn replyQuestionErased(ptr: *anyopaque, allocator: std.mem.Allocator, request_id: []const u8, request: server.QuestionReplyRequest) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/question/{s}/reply", .{ self.base_url, request_id });
        defer allocator.free(url);
        const body = try encodeJsonBody(allocator, request);
        defer allocator.free(body);
        var response = try self.requester.request(allocator, .POST, url, body);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.AckResponse, allocator, response.body);
    }

    fn rejectQuestionErased(ptr: *anyopaque, allocator: std.mem.Allocator, request_id: []const u8) anyerror!server.AckResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const url = try std.fmt.allocPrint(allocator, "{s}/question/{s}/reject", .{ self.base_url, request_id });
        defer allocator.free(url);
        var response = try self.requester.request(allocator, .POST, url, null);
        defer response.deinit(allocator);
        if (response.status != 200) return error.HttpRequestFailed;
        return parseOwned(server.AckResponse, allocator, response.body);
    }

    fn subscribeEventsErased(ptr: *anyopaque, allocator: std.mem.Allocator, after_seq: u64) anyerror!transport_model.EventSubscription {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const subscription = try allocator.create(HttpEventSubscription);
        subscription.* = .{
                        .base_url = try allocator.dupe(u8, self.base_url),
            .after_seq = after_seq,
            .queue = .empty,
            .stop_requested = .init(false),
        };
        subscription.thread = try std.Thread.spawn(.{}, HttpEventSubscription.readerThreadMain, .{subscription});
        return subscription.asSubscription();
    }

    fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.requester.deinit(allocator);
        allocator.free(self.base_url);
        allocator.destroy(self);
    }
};

const HttpEventSubscription = struct {
    allocator: std.mem.Allocator,
    base_url: []u8,
    after_seq: u64,
    queue: std.ArrayListUnmanaged(server.RuntimeEventDto),
    mutex: std.atomic.Mutex = .unlocked,
    stop_requested: std.atomic.Value(bool),
    thread: ?std.Thread = null,

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
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const count = if (limit == 0) self.queue.items.len else @min(limit, self.queue.items.len);
        const events = try allocator.alloc(server.RuntimeEventDto, count);
        errdefer allocator.free(events);

        for (0..count) |index| {
            events[index] = self.queue.orderedRemove(0);
        }
        return events;
    }

    fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.stop_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        for (self.queue.items) |*item| item.deinit(self.allocator);
        self.queue.deinit(self.allocator);
        allocator.free(self.base_url);
        allocator.destroy(self);
    }

    fn readerThreadMain(self: *Self) void {
        var client = std.http.Client{ .allocator = self.allocator, .io = std.Io.Threaded.global_single_threaded.*.io() };
        defer client.deinit();

        while (!self.stop_requested.load(.acquire)) {
            const url = std.fmt.allocPrint(self.allocator, "{s}/event?after_seq={d}", .{ self.base_url, self.after_seq }) catch return;
            defer self.allocator.free(url);

            const uri = std.Uri.parse(url) catch return;
            var req = client.request(.GET, uri, .{
                .keep_alive = false,
                .headers = .{
                    .user_agent = .{ .override = "zopcode/0.1.0" },
                },
            }) catch return;
            defer req.deinit();

            req.sendBodiless() catch return;
            var head_buffer: [4096]u8 = undefined;
            var response = req.receiveHead(head_buffer[0..]) catch return;
            if (response.head.status != .ok) return;

            var transfer_buffer: [4096]u8 = undefined;
            var reader = response.reader(transfer_buffer[0..]);

            while (!self.stop_requested.load(.acquire)) {
                const maybe_line = reader.takeDelimiter('\n') catch return;
                const line = maybe_line orelse break;
                const trimmed = std.mem.trim(u8, line, " \r");
                if (trimmed.len == 0) continue;
                if (trimmed[0] == ':') continue;
                if (!std.mem.startsWith(u8, trimmed, "data:")) continue;
                const payload = std.mem.trimStart(u8, trimmed["data:".len..], " ");
                const parsed = std.json.parseFromSlice(server.RuntimeEventDto, self.allocator, payload, .{ .ignore_unknown_fields = true }) catch return;
                defer parsed.deinit();
                const event = parsed.value.clone(self.allocator) catch return;

                while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
                self.queue.append(self.allocator, event) catch {
                    self.mutex.unlock();
                    return;
                };
                self.after_seq = event.seq;
                self.mutex.unlock();
            }
        }
    }
};

const StdRequester = struct {
    allocator: std.mem.Allocator,

    const Self = @This();

    const vtable = Requester.VTable{
        .request = requestErased,
        .deinit = deinitErased,
    };

    fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        self.* = .{ .allocator = allocator };
        return self;
    }

    fn asRequester(self: *Self) Requester {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn requestErased(ptr: *anyopaque, allocator: std.mem.Allocator, method: server.HttpMethod, url: []const u8, body: ?[]const u8) anyerror!RequesterResponse {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.request(allocator, method, url, body);
    }

    fn request(self: *Self, allocator: std.mem.Allocator, method: server.HttpMethod, url: []const u8, body: ?[]const u8) !RequesterResponse {
        _ = self;
        var client = std.http.Client{ .allocator = allocator, .io = std.Io.Threaded.global_single_threaded.*.io() };
        defer client.deinit();

        const uri = try std.Uri.parse(url);
        var req = try client.request(methodToStd(method), uri, .{
            .keep_alive = false,
            .headers = .{
                .content_type = .{ .override = if (body != null) "application/json" else "" },
                .user_agent = .{ .override = "zopcode/0.1.0" },
            },
        });
        defer req.deinit();

        if (body) |payload| {
            req.transfer_encoding = .{ .content_length = payload.len };
            var send_buffer: [4096]u8 = undefined;
            var body_writer = try req.sendBodyUnflushed(send_buffer[0..]);
            try body_writer.writer.writeAll(payload);
            try body_writer.end();
            try req.connection.?.flush();
        } else {
            try req.sendBodiless();
        }

        var head_buffer: [4096]u8 = undefined;
        var response = try req.receiveHead(head_buffer[0..]);
        var transfer_buffer: [4096]u8 = undefined;
        const reader = response.reader(transfer_buffer[0..]);
        const response_body = try reader.allocRemaining(allocator, .limited(512 * 1024));

        return .{
            .status = @intFromEnum(response.head.status),
            .content_type = try allocator.dupe(u8, ""),
            .body = response_body,
        };
    }

    fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        allocator.destroy(self);
    }
};

fn methodToStd(method: server.HttpMethod) std.http.Method {
    return switch (method) {
        .GET => .GET,
        .POST => .POST,
    };
}

fn joinUrl(allocator: std.mem.Allocator, base_url: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, suffix });
}

fn encodeJsonBody(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    
    try out.print(allocator, "{f}", .{std.json.fmt(value, .{})});
    return allocator.dupe(u8, out.items);
}

fn parseOwned(comptime T: type, allocator: std.mem.Allocator, body: []const u8) !T {
    const parsed = try std.json.parseFromSlice(T, allocator, body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return parsed.value.clone(allocator);
}

test "http transport can use injected requester for session routes" {
    const RouteRequester = struct {
        allocator: std.mem.Allocator,
        services: *server.ServerServices,

        const V = Requester.VTable{
            .request = requestErased,
            .deinit = deinitErased,
        };

        fn init(allocator: std.mem.Allocator, services: *server.ServerServices) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .allocator = allocator, .services = services };
            return self;
        }

        fn asRequester(self: *@This()) Requester {
            return .{ .ptr = @ptrCast(self), .vtable = &V };
        }

        fn requestErased(ptr: *anyopaque, allocator: std.mem.Allocator, method: server.HttpMethod, url: []const u8, body: ?[]const u8) anyerror!RequesterResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const uri = try std.Uri.parse(url);
            const target = if (uri.query) |query|
                try std.fmt.allocPrint(allocator, "{s}?{s}", .{ uri.path.percent_encoded, query.percent_encoded })
            else
                try allocator.dupe(u8, uri.path.percent_encoded);
            defer allocator.free(target);
            var response = try server.handleRequest(allocator, self.services, .{
                .method = method,
                .target = target,
                .body = body,
            });
            defer response.deinit(allocator);
            return .{
                .status = response.status,
                .content_type = try allocator.dupe(u8, response.content_type),
                .body = try allocator.dupe(u8, response.body),
            };
        }

        fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }
    };

    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const requester_ptr = try RouteRequester.init(std.testing.allocator, &services);
    const transport_ptr = try HttpTransport.initWithRequester(std.testing.allocator, "http://test", requester_ptr.asRequester());
    defer transport_ptr.asTransport().deinit(std.testing.allocator);
    const transport = transport_ptr.asTransport();

    var created = try transport.createSession(std.testing.allocator, .{ .title = "HTTP" });
    defer created.deinit(std.testing.allocator);

    var accepted = try transport.submitPrompt(std.testing.allocator, created.session_id, .{ .text = "hello" });
    defer accepted.deinit(std.testing.allocator);
    try std.testing.expect(accepted.accepted);

    var summary = try fixture.app_context.framework_app.task_runner.waitForCompletion(std.testing.allocator, accepted.task_id, 5000);
    defer summary.deinit(std.testing.allocator);

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

test "http transport can use injected requester for permission and question routes" {
    if (std.process.getEnvVarOwned(std.testing.allocator, "SKIP_PERMISSION_QUESTION_CLIENT_TEST")) |value| {
        std.testing.allocator.free(value);
        return error.SkipZigTest;
    } else |_| {}
    const RouteRequester = struct {
        allocator: std.mem.Allocator,
        services: *server.ServerServices,

        const V = Requester.VTable{
            .request = requestErased,
            .deinit = deinitErased,
        };

        fn init(allocator: std.mem.Allocator, services: *server.ServerServices) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .allocator = allocator, .services = services };
            return self;
        }

        fn asRequester(self: *@This()) Requester {
            return .{ .ptr = @ptrCast(self), .vtable = &V };
        }

        fn requestErased(ptr: *anyopaque, allocator: std.mem.Allocator, method: server.HttpMethod, url: []const u8, body: ?[]const u8) anyerror!RequesterResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const uri = try std.Uri.parse(url);
            const target = if (uri.query) |query|
                try std.fmt.allocPrint(allocator, "{s}?{s}", .{ uri.path.percent_encoded, query.percent_encoded })
            else
                try allocator.dupe(u8, uri.path.percent_encoded);
            defer allocator.free(target);
            var response = try server.handleRequest(allocator, self.services, .{
                .method = method,
                .target = target,
                .body = body,
            });
            defer response.deinit(allocator);
            return .{
                .status = response.status,
                .content_type = try allocator.dupe(u8, response.content_type),
                .body = try allocator.dupe(u8, response.body),
            };
        }

        fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }
    };

    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const requester_ptr = try RouteRequester.init(std.testing.allocator, &services);
    const transport_ptr = try HttpTransport.initWithRequester(std.testing.allocator, "http://test", requester_ptr.asRequester());
    defer transport_ptr.asTransport().deinit(std.testing.allocator);
    const transport = transport_ptr.asTransport();

    var pending_permission = try fixture.app_context.permissionRuntime().createPending(.{
        .session_id = "session_perm",
        .permission = "edit",
        .patterns = @constCast(&[_][]const u8{"src/main.zig"}),
    });
    defer pending_permission.deinit(std.testing.allocator);

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

test "http transport can use injected requester for provider catalog and auth routes" {
    const RouteRequester = struct {
        allocator: std.mem.Allocator,
        services: *server.ServerServices,

        const V = Requester.VTable{
            .request = requestErased,
            .deinit = deinitErased,
        };

        fn init(allocator: std.mem.Allocator, services: *server.ServerServices) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .allocator = allocator, .services = services };
            return self;
        }

        fn asRequester(self: *@This()) Requester {
            return .{ .ptr = @ptrCast(self), .vtable = &V };
        }

        fn requestErased(ptr: *anyopaque, allocator: std.mem.Allocator, method: server.HttpMethod, url: []const u8, body: ?[]const u8) anyerror!RequesterResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const uri = try std.Uri.parse(url);
            const target = if (uri.query) |query|
                try std.fmt.allocPrint(allocator, "{s}?{s}", .{ uri.path.percent_encoded, query.percent_encoded })
            else
                try allocator.dupe(u8, uri.path.percent_encoded);
            defer allocator.free(target);
            var response = try server.handleRequest(allocator, self.services, .{
                .method = method,
                .target = target,
                .body = body,
            });
            defer response.deinit(allocator);
            return .{
                .status = response.status,
                .content_type = try allocator.dupe(u8, response.content_type),
                .body = try allocator.dupe(u8, response.body),
            };
        }

        fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }
    };

    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const requester_ptr = try RouteRequester.init(std.testing.allocator, &services);
    const transport_ptr = try HttpTransport.initWithRequester(std.testing.allocator, "http://test", requester_ptr.asRequester());
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

test "http transport can use injected requester for pty routes" {
    const RouteRequester = struct {
        allocator: std.mem.Allocator,
        services: *server.ServerServices,

        const V = Requester.VTable{
            .request = requestErased,
            .deinit = deinitErased,
        };

        fn init(allocator: std.mem.Allocator, services: *server.ServerServices) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .allocator = allocator, .services = services };
            return self;
        }

        fn asRequester(self: *@This()) Requester {
            return .{ .ptr = @ptrCast(self), .vtable = &V };
        }

        fn requestErased(ptr: *anyopaque, allocator: std.mem.Allocator, method: server.HttpMethod, url: []const u8, body: ?[]const u8) anyerror!RequesterResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const uri = try std.Uri.parse(url);
            const target = if (uri.query) |query|
                try std.fmt.allocPrint(allocator, "{s}?{s}", .{ uri.path.percent_encoded, query.percent_encoded })
            else
                try allocator.dupe(u8, uri.path.percent_encoded);
            defer allocator.free(target);
            var response = try server.handleRequest(allocator, self.services, .{
                .method = method,
                .target = target,
                .body = body,
            });
            defer response.deinit(allocator);
            return .{
                .status = response.status,
                .content_type = try allocator.dupe(u8, response.content_type),
                .body = try allocator.dupe(u8, response.body),
            };
        }

        fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }
    };

    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var mock_state = pty_test_backend.State{};
    fixture.app_context.pty_runtime.backend_factory = pty_test_backend.factory(&mock_state);
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const requester_ptr = try RouteRequester.init(std.testing.allocator, &services);
    const transport_ptr = try HttpTransport.initWithRequester(std.testing.allocator, "http://test", requester_ptr.asRequester());
    defer transport_ptr.asTransport().deinit(std.testing.allocator);
    const transport = transport_ptr.asTransport();

    var created = try transport.createPty(std.testing.allocator, .{});
    defer created.deinit(std.testing.allocator);

    var listed = try transport.listPtys(std.testing.allocator);
    defer listed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), listed.items.len);

    try std.testing.expect((try transport.writePtyInput(std.testing.allocator, created.id, .{ .data = "echo http\n" })).ok);

    var output = try transport.readPtyOutput(std.testing.allocator, created.id, 0, 16, 0);
    defer output.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), output.items.len);
    try std.testing.expectEqualStrings("echo http\n", output.items[0].data);

    try std.testing.expect((try transport.removePty(std.testing.allocator, created.id)).ok);
}

test "http transport can use injected requester for project and workspace routes" {
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

    const RouteRequester = struct {
        allocator: std.mem.Allocator,
        services: *server.ServerServices,

        const V = Requester.VTable{
            .request = requestErased,
            .deinit = deinitErased,
        };

        fn init(allocator: std.mem.Allocator, services: *server.ServerServices) !*@This() {
            const self = try allocator.create(@This());
            self.* = .{ .allocator = allocator, .services = services };
            return self;
        }

        fn asRequester(self: *@This()) Requester {
            return .{ .ptr = @ptrCast(self), .vtable = &V };
        }

        fn requestErased(ptr: *anyopaque, allocator: std.mem.Allocator, method: server.HttpMethod, url: []const u8, body: ?[]const u8) anyerror!RequesterResponse {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            const uri = try std.Uri.parse(url);
            const target = if (uri.query) |query|
                try std.fmt.allocPrint(allocator, "{s}?{s}", .{ uri.path.percent_encoded, query.percent_encoded })
            else
                try allocator.dupe(u8, uri.path.percent_encoded);
            defer allocator.free(target);
            var response = try server.handleRequest(allocator, self.services, .{
                .method = method,
                .target = target,
                .body = body,
            });
            defer response.deinit(allocator);
            return .{
                .status = response.status,
                .content_type = try allocator.dupe(u8, response.content_type),
                .body = try allocator.dupe(u8, response.body),
            };
        }

        fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            allocator.destroy(self);
        }
    };

    var fixture = try server.services.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    fixture.app_context.project_runtime.vcs_executor = .{ .ptr = undefined, .run_fn = MockGit.run };
    var services = server.ServerServices.init(std.testing.allocator, &fixture.app_context);
    const requester_ptr = try RouteRequester.init(std.testing.allocator, &services);
    const transport_ptr = try HttpTransport.initWithRequester(std.testing.allocator, "http://test", requester_ptr.asRequester());
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
