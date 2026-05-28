const std = @import("std");
const server = @import("../server/root.zig");
const transport_model = @import("transport.zig");

pub const MODULE_NAME = "client";

pub const transport = transport_model;
pub const local = @import("local.zig");
pub const http = @import("http.zig");

pub const ClientTransport = transport_model.ClientTransport;
pub const EventSubscription = transport_model.EventSubscription;
pub const LocalTransport = local.LocalTransport;
pub const HttpTransport = http.HttpTransport;
pub const HttpRequester = http.Requester;

pub const Client = struct {
    allocator: std.mem.Allocator,
    transport: ClientTransport,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, tr: ClientTransport) Self {
        return .{
                        .transport = tr,
        };
    }

    pub fn deinit(self: *Self) void {
        self.transport.deinit(self.allocator);
    }

    pub fn createSession(self: *Self, request: server.CreateSessionRequest) !server.CreateSessionResponse {
        return self.transport.createSession(self.allocator, request);
    }

    pub fn getSession(self: *Self, session_id: []const u8) !?server.SessionResponse {
        return self.transport.getSession(self.allocator, session_id);
    }

    pub fn listHistory(self: *Self, session_id: []const u8) !server.HistoryResponse {
        return self.transport.listHistory(self.allocator, session_id);
    }

    pub fn submitPrompt(self: *Self, session_id: []const u8, request: server.SubmitPromptRequest) !server.AcceptedResponse {
        return self.transport.submitPrompt(self.allocator, session_id, request);
    }

    pub fn abortSession(self: *Self, session_id: []const u8) !server.AbortResponse {
        return self.transport.abortSession(self.allocator, session_id);
    }

    pub fn listStatus(self: *Self) !server.StatusResponse {
        return self.transport.listStatus(self.allocator);
    }

    pub fn listLspStatus(self: *Self) !server.LspStatusResponse {
        return self.transport.listLspStatus(self.allocator);
    }

    pub fn listFormatterStatus(self: *Self) !server.FormatterStatusResponse {
        return self.transport.listFormatterStatus(self.allocator);
    }

    pub fn listMcpStatus(self: *Self) !server.McpStatusResponse {
        return self.transport.listMcpStatus(self.allocator);
    }

    pub fn listProviderCatalog(self: *Self) !server.ProviderCatalogResponse {
        return self.transport.listProviderCatalog(self.allocator);
    }

    pub fn listProviderAuth(self: *Self) !server.ProviderAuthListResponse {
        return self.transport.listProviderAuth(self.allocator);
    }

    pub fn setProviderAuth(self: *Self, provider_id: []const u8, request: server.ProviderAuthSetRequest) !server.AckResponse {
        return self.transport.setProviderAuth(self.allocator, provider_id, request);
    }

    pub fn removeProviderAuth(self: *Self, provider_id: []const u8) !server.AckResponse {
        return self.transport.removeProviderAuth(self.allocator, provider_id);
    }

    pub fn listPlugins(self: *Self) !server.PluginListResponse {
        return self.transport.listPlugins(self.allocator);
    }

    pub fn listSkills(self: *Self) !server.SkillListResponse {
        return self.transport.listSkills(self.allocator);
    }

    pub fn getProject(self: *Self) !server.ProjectResponse {
        return self.transport.getProject(self.allocator);
    }

    pub fn listWorkspaces(self: *Self) !server.WorkspaceListResponse {
        return self.transport.listWorkspaces(self.allocator);
    }

    pub fn createWorkspace(self: *Self, request: server.CreateWorkspaceRequest) !server.WorkspaceResponse {
        return self.transport.createWorkspace(self.allocator, request);
    }

    pub fn removeWorkspace(self: *Self, workspace_id: []const u8) !server.AckResponse {
        return self.transport.removeWorkspace(self.allocator, workspace_id);
    }

    pub fn createPty(self: *Self, request: server.CreatePtyRequest) !server.PtyInfoResponse {
        return self.transport.createPty(self.allocator, request);
    }

    pub fn getPty(self: *Self, pty_id: []const u8) !?server.PtyInfoResponse {
        return self.transport.getPty(self.allocator, pty_id);
    }

    pub fn listPtys(self: *Self) !server.PtyListResponse {
        return self.transport.listPtys(self.allocator);
    }

    pub fn writePtyInput(self: *Self, pty_id: []const u8, request: server.PtyInputRequest) !server.AckResponse {
        return self.transport.writePtyInput(self.allocator, pty_id, request);
    }

    pub fn readPtyOutput(self: *Self, pty_id: []const u8, after_seq: u64, limit: usize, follow_ms: u64) !server.PtyOutputResponse {
        return self.transport.readPtyOutput(self.allocator, pty_id, after_seq, limit, follow_ms);
    }

    pub fn removePty(self: *Self, pty_id: []const u8) !server.AckResponse {
        return self.transport.removePty(self.allocator, pty_id);
    }

    pub fn listPermissions(self: *Self) !server.PermissionListResponse {
        return self.transport.listPermissions(self.allocator);
    }

    pub fn replyPermission(self: *Self, request_id: []const u8, request: server.PermissionReplyRequest) !server.AckResponse {
        return self.transport.replyPermission(self.allocator, request_id, request);
    }

    pub fn listQuestions(self: *Self) !server.QuestionListResponse {
        return self.transport.listQuestions(self.allocator);
    }

    pub fn replyQuestion(self: *Self, request_id: []const u8, request: server.QuestionReplyRequest) !server.AckResponse {
        return self.transport.replyQuestion(self.allocator, request_id, request);
    }

    pub fn rejectQuestion(self: *Self, request_id: []const u8) !server.AckResponse {
        return self.transport.rejectQuestion(self.allocator, request_id);
    }

    pub fn subscribeEvents(self: *Self, after_seq: u64) !EventSubscription {
        return self.transport.subscribeEvents(self.allocator, after_seq);
    }
};

test {
    std.testing.refAllDecls(@This());
}

test "client module exports are available" {
    try std.testing.expectEqualStrings("client", MODULE_NAME);
}
