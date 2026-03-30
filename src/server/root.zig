const std = @import("std");

pub const MODULE_NAME = "server";

pub const dto = @import("dto.zig");
pub const services = @import("services.zig");
pub const http = @import("http.zig");
pub const listener = @import("listener.zig");

pub const CreateSessionRequest = dto.CreateSessionRequest;
pub const CreateSessionResponse = dto.CreateSessionResponse;
pub const SessionResponse = dto.SessionResponse;
pub const SubmitPromptRequest = dto.SubmitPromptRequest;
pub const AcceptedResponse = dto.AcceptedResponse;
pub const AbortResponse = dto.AbortResponse;
pub const AckResponse = dto.AckResponse;
pub const StatusResponse = dto.StatusResponse;
pub const SessionStatusDto = dto.SessionStatusDto;
pub const LspStatusResponse = dto.LspStatusResponse;
pub const LspStatusDto = dto.LspStatusDto;
pub const FormatterStatusResponse = dto.FormatterStatusResponse;
pub const FormatterStatusDto = dto.FormatterStatusDto;
pub const McpStatusResponse = dto.McpStatusResponse;
pub const McpStatusDto = dto.McpStatusDto;
pub const ProviderCatalogResponse = dto.ProviderCatalogResponse;
pub const ProviderCatalogProviderDto = dto.ProviderCatalogProviderDto;
pub const ProviderModelDto = dto.ProviderModelDto;
pub const ProviderAuthListResponse = dto.ProviderAuthListResponse;
pub const ProviderAuthStatusDto = dto.ProviderAuthStatusDto;
pub const ProviderAuthSetRequest = dto.ProviderAuthSetRequest;
pub const ProjectResponse = dto.ProjectResponse;
pub const CreateWorkspaceRequest = dto.CreateWorkspaceRequest;
pub const WorkspaceResponse = dto.WorkspaceResponse;
pub const WorkspaceListResponse = dto.WorkspaceListResponse;
pub const PluginResponse = dto.PluginResponse;
pub const PluginListResponse = dto.PluginListResponse;
pub const SkillResponse = dto.SkillResponse;
pub const SkillListResponse = dto.SkillListResponse;
pub const CreatePtyRequest = dto.CreatePtyRequest;
pub const PtyInputRequest = dto.PtyInputRequest;
pub const PtyInfoResponse = dto.PtyInfoResponse;
pub const PtyListResponse = dto.PtyListResponse;
pub const PtyOutputChunkDto = dto.PtyOutputChunkDto;
pub const PtyOutputResponse = dto.PtyOutputResponse;
pub const PermissionListResponse = dto.PermissionListResponse;
pub const QuestionListResponse = dto.QuestionListResponse;
pub const PermissionReplyRequest = dto.PermissionReplyRequest;
pub const QuestionReplyRequest = dto.QuestionReplyRequest;
pub const QuestionAnswerDto = dto.QuestionAnswerDto;
pub const HistoryResponse = dto.HistoryResponse;
pub const MessageDto = dto.MessageDto;
pub const PartDto = dto.PartDto;
pub const RuntimeEventDto = dto.RuntimeEventDto;

pub const ServerServices = services.ServerServices;
pub const ServerListener = listener.ServerListener;
pub const ListenOptions = listener.ListenOptions;
pub const HttpMethod = http.Method;
pub const HttpRequest = http.Request;
pub const HttpResponse = http.Response;
pub const handleRequest = http.handleRequest;

test {
    std.testing.refAllDecls(@This());
}

test "server module exports are available" {
    try std.testing.expectEqualStrings("server", MODULE_NAME);
}
