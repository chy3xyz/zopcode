const std = @import("std");
const server = @import("../server/root.zig");

pub const EventSubscription = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        poll: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, limit: usize) anyerror![]server.RuntimeEventDto,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn poll(self: EventSubscription, allocator: std.mem.Allocator, limit: usize) anyerror![]server.RuntimeEventDto {
        return self.vtable.poll(self.ptr, allocator, limit);
    }

    pub fn deinit(self: EventSubscription, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub const ClientTransport = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        create_session: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: server.CreateSessionRequest) anyerror!server.CreateSessionResponse,
        get_session: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!?server.SessionResponse,
        list_history: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!server.HistoryResponse,
        submit_prompt: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8, request: server.SubmitPromptRequest) anyerror!server.AcceptedResponse,
        abort_session: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, session_id: []const u8) anyerror!server.AbortResponse,
        list_status: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.StatusResponse,
        list_lsp_status: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.LspStatusResponse,
        list_formatter_status: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.FormatterStatusResponse,
        list_mcp_status: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.McpStatusResponse,
        list_provider_catalog: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.ProviderCatalogResponse,
        list_provider_auth: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.ProviderAuthListResponse,
        set_provider_auth: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, provider_id: []const u8, request: server.ProviderAuthSetRequest) anyerror!server.AckResponse,
        remove_provider_auth: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, provider_id: []const u8) anyerror!server.AckResponse,
        list_plugins: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.PluginListResponse,
        list_skills: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.SkillListResponse,
        get_project: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.ProjectResponse,
        list_workspaces: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.WorkspaceListResponse,
        create_workspace: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: server.CreateWorkspaceRequest) anyerror!server.WorkspaceResponse,
        remove_workspace: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, workspace_id: []const u8) anyerror!server.AckResponse,
        create_pty: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: server.CreatePtyRequest) anyerror!server.PtyInfoResponse,
        get_pty: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8) anyerror!?server.PtyInfoResponse,
        list_ptys: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.PtyListResponse,
        write_pty_input: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8, request: server.PtyInputRequest) anyerror!server.AckResponse,
        read_pty_output: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8, after_seq: u64, limit: usize, follow_ms: u64) anyerror!server.PtyOutputResponse,
        remove_pty: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, pty_id: []const u8) anyerror!server.AckResponse,
        list_permissions: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.PermissionListResponse,
        reply_permission: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request_id: []const u8, request: server.PermissionReplyRequest) anyerror!server.AckResponse,
        list_questions: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!server.QuestionListResponse,
        reply_question: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request_id: []const u8, request: server.QuestionReplyRequest) anyerror!server.AckResponse,
        reject_question: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request_id: []const u8) anyerror!server.AckResponse,
        subscribe_events: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, after_seq: u64) anyerror!EventSubscription,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn createSession(self: ClientTransport, allocator: std.mem.Allocator, request: server.CreateSessionRequest) anyerror!server.CreateSessionResponse {
        return self.vtable.create_session(self.ptr, allocator, request);
    }

    pub fn getSession(self: ClientTransport, allocator: std.mem.Allocator, session_id: []const u8) anyerror!?server.SessionResponse {
        return self.vtable.get_session(self.ptr, allocator, session_id);
    }

    pub fn listHistory(self: ClientTransport, allocator: std.mem.Allocator, session_id: []const u8) anyerror!server.HistoryResponse {
        return self.vtable.list_history(self.ptr, allocator, session_id);
    }

    pub fn submitPrompt(self: ClientTransport, allocator: std.mem.Allocator, session_id: []const u8, request: server.SubmitPromptRequest) anyerror!server.AcceptedResponse {
        return self.vtable.submit_prompt(self.ptr, allocator, session_id, request);
    }

    pub fn abortSession(self: ClientTransport, allocator: std.mem.Allocator, session_id: []const u8) anyerror!server.AbortResponse {
        return self.vtable.abort_session(self.ptr, allocator, session_id);
    }

    pub fn listStatus(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.StatusResponse {
        return self.vtable.list_status(self.ptr, allocator);
    }

    pub fn listLspStatus(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.LspStatusResponse {
        return self.vtable.list_lsp_status(self.ptr, allocator);
    }

    pub fn listFormatterStatus(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.FormatterStatusResponse {
        return self.vtable.list_formatter_status(self.ptr, allocator);
    }

    pub fn listMcpStatus(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.McpStatusResponse {
        return self.vtable.list_mcp_status(self.ptr, allocator);
    }

    pub fn listProviderCatalog(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.ProviderCatalogResponse {
        return self.vtable.list_provider_catalog(self.ptr, allocator);
    }

    pub fn listProviderAuth(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.ProviderAuthListResponse {
        return self.vtable.list_provider_auth(self.ptr, allocator);
    }

    pub fn setProviderAuth(self: ClientTransport, allocator: std.mem.Allocator, provider_id: []const u8, request: server.ProviderAuthSetRequest) anyerror!server.AckResponse {
        return self.vtable.set_provider_auth(self.ptr, allocator, provider_id, request);
    }

    pub fn removeProviderAuth(self: ClientTransport, allocator: std.mem.Allocator, provider_id: []const u8) anyerror!server.AckResponse {
        return self.vtable.remove_provider_auth(self.ptr, allocator, provider_id);
    }

    pub fn listPlugins(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.PluginListResponse {
        return self.vtable.list_plugins(self.ptr, allocator);
    }

    pub fn listSkills(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.SkillListResponse {
        return self.vtable.list_skills(self.ptr, allocator);
    }

    pub fn getProject(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.ProjectResponse {
        return self.vtable.get_project(self.ptr, allocator);
    }

    pub fn listWorkspaces(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.WorkspaceListResponse {
        return self.vtable.list_workspaces(self.ptr, allocator);
    }

    pub fn createWorkspace(self: ClientTransport, allocator: std.mem.Allocator, request: server.CreateWorkspaceRequest) anyerror!server.WorkspaceResponse {
        return self.vtable.create_workspace(self.ptr, allocator, request);
    }

    pub fn removeWorkspace(self: ClientTransport, allocator: std.mem.Allocator, workspace_id: []const u8) anyerror!server.AckResponse {
        return self.vtable.remove_workspace(self.ptr, allocator, workspace_id);
    }

    pub fn createPty(self: ClientTransport, allocator: std.mem.Allocator, request: server.CreatePtyRequest) anyerror!server.PtyInfoResponse {
        return self.vtable.create_pty(self.ptr, allocator, request);
    }

    pub fn getPty(self: ClientTransport, allocator: std.mem.Allocator, pty_id: []const u8) anyerror!?server.PtyInfoResponse {
        return self.vtable.get_pty(self.ptr, allocator, pty_id);
    }

    pub fn listPtys(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.PtyListResponse {
        return self.vtable.list_ptys(self.ptr, allocator);
    }

    pub fn writePtyInput(self: ClientTransport, allocator: std.mem.Allocator, pty_id: []const u8, request: server.PtyInputRequest) anyerror!server.AckResponse {
        return self.vtable.write_pty_input(self.ptr, allocator, pty_id, request);
    }

    pub fn readPtyOutput(self: ClientTransport, allocator: std.mem.Allocator, pty_id: []const u8, after_seq: u64, limit: usize, follow_ms: u64) anyerror!server.PtyOutputResponse {
        return self.vtable.read_pty_output(self.ptr, allocator, pty_id, after_seq, limit, follow_ms);
    }

    pub fn removePty(self: ClientTransport, allocator: std.mem.Allocator, pty_id: []const u8) anyerror!server.AckResponse {
        return self.vtable.remove_pty(self.ptr, allocator, pty_id);
    }

    pub fn listPermissions(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.PermissionListResponse {
        return self.vtable.list_permissions(self.ptr, allocator);
    }

    pub fn replyPermission(self: ClientTransport, allocator: std.mem.Allocator, request_id: []const u8, request: server.PermissionReplyRequest) anyerror!server.AckResponse {
        return self.vtable.reply_permission(self.ptr, allocator, request_id, request);
    }

    pub fn listQuestions(self: ClientTransport, allocator: std.mem.Allocator) anyerror!server.QuestionListResponse {
        return self.vtable.list_questions(self.ptr, allocator);
    }

    pub fn replyQuestion(self: ClientTransport, allocator: std.mem.Allocator, request_id: []const u8, request: server.QuestionReplyRequest) anyerror!server.AckResponse {
        return self.vtable.reply_question(self.ptr, allocator, request_id, request);
    }

    pub fn rejectQuestion(self: ClientTransport, allocator: std.mem.Allocator, request_id: []const u8) anyerror!server.AckResponse {
        return self.vtable.reject_question(self.ptr, allocator, request_id);
    }

    pub fn subscribeEvents(self: ClientTransport, allocator: std.mem.Allocator, after_seq: u64) anyerror!EventSubscription {
        return self.vtable.subscribe_events(self.ptr, allocator, after_seq);
    }

    pub fn deinit(self: ClientTransport, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub fn freeEventDtos(allocator: std.mem.Allocator, items: []server.RuntimeEventDto) void {
    for (items) |item| {
        allocator.free(item.topic);
        allocator.free(item.payload_json);
    }
    allocator.free(items);
}
