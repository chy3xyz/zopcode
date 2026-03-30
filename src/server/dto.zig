const std = @import("std");
const mcp = @import("../mcp/root.zig");
const permission = @import("../permission/root.zig");
const pty = @import("../pty/root.zig");
const project = @import("../project/root.zig");
const question = @import("../question/root.zig");
const formatter = @import("../formatter/root.zig");
const plugin = @import("../plugin/root.zig");
const session = @import("../session/root.zig");
const skill = @import("../skill/root.zig");

pub const CreateSessionRequest = struct {
    title: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
};

pub const CreateSessionResponse = struct {
    session_id: []const u8,
    title: []const u8,
    agent_id: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn clone(self: CreateSessionResponse, allocator: std.mem.Allocator) !CreateSessionResponse {
        return .{
            .session_id = try allocator.dupe(u8, self.session_id),
            .title = try allocator.dupe(u8, self.title),
            .agent_id = try allocator.dupe(u8, self.agent_id),
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
        };
    }

    pub fn deinit(self: *CreateSessionResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.title);
        allocator.free(self.agent_id);
    }
};

pub const SessionResponse = struct {
    session_id: []const u8,
    title: []const u8,
    agent_id: []const u8,
    parent_id: ?[]const u8 = null,
    archived: bool,
    created_at_ms: i64,
    updated_at_ms: i64,

    pub fn clone(self: SessionResponse, allocator: std.mem.Allocator) !SessionResponse {
        return .{
            .session_id = try allocator.dupe(u8, self.session_id),
            .title = try allocator.dupe(u8, self.title),
            .agent_id = try allocator.dupe(u8, self.agent_id),
            .parent_id = if (self.parent_id) |parent_id| try allocator.dupe(u8, parent_id) else null,
            .archived = self.archived,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
        };
    }

    pub fn deinit(self: *SessionResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.title);
        allocator.free(self.agent_id);
        if (self.parent_id) |parent_id| allocator.free(parent_id);
    }
};

pub const SubmitPromptRequest = struct {
    text: []const u8,
    title: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    category: ?[]const u8 = null,
    model: ?[]const u8 = null,
};

pub const AcceptedResponse = struct {
    session_id: []const u8,
    request_id: []const u8,
    task_id: []const u8,
    accepted: bool = true,

    pub fn clone(self: AcceptedResponse, allocator: std.mem.Allocator) !AcceptedResponse {
        return .{
            .session_id = try allocator.dupe(u8, self.session_id),
            .request_id = try allocator.dupe(u8, self.request_id),
            .task_id = try allocator.dupe(u8, self.task_id),
            .accepted = self.accepted,
        };
    }

    pub fn deinit(self: *AcceptedResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.request_id);
        allocator.free(self.task_id);
    }
};

pub const AbortResponse = struct {
    session_id: []const u8,
    cancelled: bool,

    pub fn clone(self: AbortResponse, allocator: std.mem.Allocator) !AbortResponse {
        return .{
            .session_id = try allocator.dupe(u8, self.session_id),
            .cancelled = self.cancelled,
        };
    }

    pub fn deinit(self: *AbortResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
    }
};

pub const AckResponse = struct {
    ok: bool,

    pub fn clone(self: AckResponse, _: std.mem.Allocator) !AckResponse {
        return self;
    }

    pub fn deinit(self: *AckResponse, _: std.mem.Allocator) void {
        _ = self;
    }
};

pub const StatusResponse = struct {
    items: []SessionStatusDto,

    pub fn clone(self: StatusResponse, allocator: std.mem.Allocator) !StatusResponse {
        const items = try allocator.alloc(SessionStatusDto, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *StatusResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const LspStatusResponse = struct {
    items: []LspStatusDto,

    pub fn clone(self: LspStatusResponse, allocator: std.mem.Allocator) !LspStatusResponse {
        const items = try allocator.alloc(LspStatusDto, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *LspStatusResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const FormatterStatusResponse = struct {
    items: []FormatterStatusDto,

    pub fn clone(self: FormatterStatusResponse, allocator: std.mem.Allocator) !FormatterStatusResponse {
        const items = try allocator.alloc(FormatterStatusDto, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *FormatterStatusResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const McpStatusResponse = struct {
    items: []McpStatusDto,

    pub fn clone(self: McpStatusResponse, allocator: std.mem.Allocator) !McpStatusResponse {
        const items = try allocator.alloc(McpStatusDto, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *McpStatusResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const ProviderCatalogResponse = struct {
    default_model: ?[]const u8 = null,
    providers: []ProviderCatalogProviderDto,

    pub fn clone(self: ProviderCatalogResponse, allocator: std.mem.Allocator) !ProviderCatalogResponse {
        const providers = try allocator.alloc(ProviderCatalogProviderDto, self.providers.len);
        errdefer allocator.free(providers);
        for (self.providers, 0..) |item, index| {
            providers[index] = try item.clone(allocator);
            errdefer providers[index].deinit(allocator);
        }
        return .{
            .default_model = if (self.default_model) |value| try allocator.dupe(u8, value) else null,
            .providers = providers,
        };
    }

    pub fn deinit(self: *ProviderCatalogResponse, allocator: std.mem.Allocator) void {
        if (self.default_model) |value| allocator.free(value);
        for (self.providers) |*item| item.deinit(allocator);
        allocator.free(self.providers);
    }
};

pub const ProviderAuthListResponse = struct {
    items: []ProviderAuthStatusDto,

    pub fn clone(self: ProviderAuthListResponse, allocator: std.mem.Allocator) !ProviderAuthListResponse {
        const items = try allocator.alloc(ProviderAuthStatusDto, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *ProviderAuthListResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const CreatePtyRequest = struct {
    cwd: ?[]const u8 = null,
    shell: ?[]const u8 = null,
};

pub const CreateWorkspaceRequest = struct {
    name: []const u8,
};

pub const PtyInputRequest = struct {
    data: []const u8,
};

pub const PtyInfoResponse = struct {
    id: []const u8,
    cwd: []const u8,
    shell: []const u8,
    status: []const u8,
    created_at_ms: i64,
    updated_at_ms: i64,
    exit_code: ?i32 = null,

    pub fn clone(self: PtyInfoResponse, allocator: std.mem.Allocator) !PtyInfoResponse {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .cwd = try allocator.dupe(u8, self.cwd),
            .shell = try allocator.dupe(u8, self.shell),
            .status = try allocator.dupe(u8, self.status),
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .exit_code = self.exit_code,
        };
    }

    pub fn deinit(self: *PtyInfoResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.cwd);
        allocator.free(self.shell);
        allocator.free(self.status);
    }
};

pub const PtyListResponse = struct {
    items: []PtyInfoResponse,

    pub fn clone(self: PtyListResponse, allocator: std.mem.Allocator) !PtyListResponse {
        const items = try allocator.alloc(PtyInfoResponse, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *PtyListResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const PtyOutputChunkDto = struct {
    seq: u64,
    pty_id: []const u8,
    stream: []const u8,
    data: []const u8,
    ts_unix_ms: i64,

    pub fn clone(self: PtyOutputChunkDto, allocator: std.mem.Allocator) !PtyOutputChunkDto {
        return .{
            .seq = self.seq,
            .pty_id = try allocator.dupe(u8, self.pty_id),
            .stream = try allocator.dupe(u8, self.stream),
            .data = try allocator.dupe(u8, self.data),
            .ts_unix_ms = self.ts_unix_ms,
        };
    }

    pub fn deinit(self: *PtyOutputChunkDto, allocator: std.mem.Allocator) void {
        allocator.free(self.pty_id);
        allocator.free(self.stream);
        allocator.free(self.data);
    }
};

pub const PtyOutputResponse = struct {
    items: []PtyOutputChunkDto,

    pub fn clone(self: PtyOutputResponse, allocator: std.mem.Allocator) !PtyOutputResponse {
        const items = try allocator.alloc(PtyOutputChunkDto, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *PtyOutputResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const ProjectResponse = struct {
    name: []const u8,
    workspace_dir: []const u8,
    project_root: []const u8,
    vcs_available: bool,
    branch: ?[]const u8 = null,
    dirty: bool,
    changed_file_count: u32,

    pub fn clone(self: ProjectResponse, allocator: std.mem.Allocator) !ProjectResponse {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .workspace_dir = try allocator.dupe(u8, self.workspace_dir),
            .project_root = try allocator.dupe(u8, self.project_root),
            .vcs_available = self.vcs_available,
            .branch = if (self.branch) |value| try allocator.dupe(u8, value) else null,
            .dirty = self.dirty,
            .changed_file_count = self.changed_file_count,
        };
    }

    pub fn deinit(self: *ProjectResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.workspace_dir);
        allocator.free(self.project_root);
        if (self.branch) |value| allocator.free(value);
    }
};

pub const WorkspaceResponse = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    created_at_ms: i64,

    pub fn clone(self: WorkspaceResponse, allocator: std.mem.Allocator) !WorkspaceResponse {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .name = try allocator.dupe(u8, self.name),
            .path = try allocator.dupe(u8, self.path),
            .created_at_ms = self.created_at_ms,
        };
    }

    pub fn deinit(self: *WorkspaceResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub const WorkspaceListResponse = struct {
    items: []WorkspaceResponse,

    pub fn clone(self: WorkspaceListResponse, allocator: std.mem.Allocator) !WorkspaceListResponse {
        const items = try allocator.alloc(WorkspaceResponse, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *WorkspaceListResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const PluginResponse = struct {
    id: []const u8,
    path: []const u8,
    description: ?[]const u8 = null,
    enabled: bool,
    hooks: [][]const u8,

    pub fn clone(self: PluginResponse, allocator: std.mem.Allocator) !PluginResponse {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .path = try allocator.dupe(u8, self.path),
            .description = if (self.description) |value| try allocator.dupe(u8, value) else null,
            .enabled = self.enabled,
            .hooks = try question.cloneStringSlice(allocator, self.hooks),
        };
    }

    pub fn deinit(self: *PluginResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        if (self.description) |value| allocator.free(value);
        question.freeStringSlice(allocator, self.hooks);
    }
};

pub const PluginListResponse = struct {
    items: []PluginResponse,

    pub fn clone(self: PluginListResponse, allocator: std.mem.Allocator) !PluginListResponse {
        const items = try allocator.alloc(PluginResponse, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *PluginListResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const SkillResponse = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    summary: []const u8,

    pub fn clone(self: SkillResponse, allocator: std.mem.Allocator) !SkillResponse {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .name = try allocator.dupe(u8, self.name),
            .path = try allocator.dupe(u8, self.path),
            .summary = try allocator.dupe(u8, self.summary),
        };
    }

    pub fn deinit(self: *SkillResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.summary);
    }
};

pub const SkillListResponse = struct {
    items: []SkillResponse,

    pub fn clone(self: SkillListResponse, allocator: std.mem.Allocator) !SkillListResponse {
        const items = try allocator.alloc(SkillResponse, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *SkillListResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const SessionStatusDto = struct {
    session_id: []const u8,
    status: []const u8,
    request_id: ?[]const u8 = null,
    task_id: ?[]const u8 = null,
    updated_at_ms: i64,

    pub fn clone(self: SessionStatusDto, allocator: std.mem.Allocator) !SessionStatusDto {
        return .{
            .session_id = try allocator.dupe(u8, self.session_id),
            .status = try allocator.dupe(u8, self.status),
            .request_id = if (self.request_id) |request_id| try allocator.dupe(u8, request_id) else null,
            .task_id = if (self.task_id) |task_id| try allocator.dupe(u8, task_id) else null,
            .updated_at_ms = self.updated_at_ms,
        };
    }

    pub fn deinit(self: *SessionStatusDto, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.status);
        if (self.request_id) |request_id| allocator.free(request_id);
        if (self.task_id) |task_id| allocator.free(task_id);
    }
};

pub const LspStatusDto = struct {
    id: []const u8,
    root: []const u8,
    status: []const u8,
    error_message: ?[]const u8 = null,

    pub fn clone(self: LspStatusDto, allocator: std.mem.Allocator) !LspStatusDto {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .root = try allocator.dupe(u8, self.root),
            .status = try allocator.dupe(u8, self.status),
            .error_message = if (self.error_message) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *LspStatusDto, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.root);
        allocator.free(self.status);
        if (self.error_message) |value| allocator.free(value);
    }
};

pub const FormatterStatusDto = struct {
    name: []const u8,
    enabled: bool,
    extensions: [][]const u8,

    pub fn clone(self: FormatterStatusDto, allocator: std.mem.Allocator) !FormatterStatusDto {
        const extensions = try question.cloneStringSlice(allocator, self.extensions);
        errdefer question.freeStringSlice(allocator, extensions);
        return .{
            .name = try allocator.dupe(u8, self.name),
            .enabled = self.enabled,
            .extensions = extensions,
        };
    }

    pub fn deinit(self: *FormatterStatusDto, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        question.freeStringSlice(allocator, self.extensions);
    }
};

pub const McpStatusDto = struct {
    id: []const u8,
    transport: []const u8,
    status: []const u8,
    error_message: ?[]const u8 = null,
    tool_count: u32 = 0,
    resource_count: u32 = 0,

    pub fn clone(self: McpStatusDto, allocator: std.mem.Allocator) !McpStatusDto {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .transport = try allocator.dupe(u8, self.transport),
            .status = try allocator.dupe(u8, self.status),
            .error_message = if (self.error_message) |value| try allocator.dupe(u8, value) else null,
            .tool_count = self.tool_count,
            .resource_count = self.resource_count,
        };
    }

    pub fn deinit(self: *McpStatusDto, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.transport);
        allocator.free(self.status);
        if (self.error_message) |value| allocator.free(value);
    }
};

pub const ProviderModelDto = struct {
    provider_id: []const u8,
    model_id: []const u8,
    display_name: []const u8,

    pub fn clone(self: ProviderModelDto, allocator: std.mem.Allocator) !ProviderModelDto {
        return .{
            .provider_id = try allocator.dupe(u8, self.provider_id),
            .model_id = try allocator.dupe(u8, self.model_id),
            .display_name = try allocator.dupe(u8, self.display_name),
        };
    }

    pub fn deinit(self: *ProviderModelDto, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model_id);
        allocator.free(self.display_name);
    }
};

pub const ProviderCatalogProviderDto = struct {
    id: []const u8,
    display_name: []const u8,
    auth_kind: []const u8,
    has_credentials: bool,
    status: []const u8,
    default_model: []const u8,
    models: []ProviderModelDto,

    pub fn clone(self: ProviderCatalogProviderDto, allocator: std.mem.Allocator) !ProviderCatalogProviderDto {
        const models = try allocator.alloc(ProviderModelDto, self.models.len);
        errdefer allocator.free(models);
        for (self.models, 0..) |item, index| {
            models[index] = try item.clone(allocator);
            errdefer models[index].deinit(allocator);
        }
        return .{
            .id = try allocator.dupe(u8, self.id),
            .display_name = try allocator.dupe(u8, self.display_name),
            .auth_kind = try allocator.dupe(u8, self.auth_kind),
            .has_credentials = self.has_credentials,
            .status = try allocator.dupe(u8, self.status),
            .default_model = try allocator.dupe(u8, self.default_model),
            .models = models,
        };
    }

    pub fn deinit(self: *ProviderCatalogProviderDto, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.display_name);
        allocator.free(self.auth_kind);
        allocator.free(self.status);
        allocator.free(self.default_model);
        for (self.models) |*item| item.deinit(allocator);
        allocator.free(self.models);
    }
};

pub const ProviderAuthStatusDto = struct {
    provider_id: []const u8,
    has_api_key: bool,

    pub fn clone(self: ProviderAuthStatusDto, allocator: std.mem.Allocator) !ProviderAuthStatusDto {
        return .{
            .provider_id = try allocator.dupe(u8, self.provider_id),
            .has_api_key = self.has_api_key,
        };
    }

    pub fn deinit(self: *ProviderAuthStatusDto, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
    }
};

pub const ProviderAuthSetRequest = struct {
    api_key: []const u8,
};

pub const PermissionListResponse = struct {
    items: []permission.PermissionRequest,

    pub fn clone(self: PermissionListResponse, allocator: std.mem.Allocator) !PermissionListResponse {
        const items = try allocator.alloc(permission.PermissionRequest, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *PermissionListResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const QuestionListResponse = struct {
    items: []question.QuestionRequest,

    pub fn clone(self: QuestionListResponse, allocator: std.mem.Allocator) !QuestionListResponse {
        const items = try allocator.alloc(question.QuestionRequest, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *QuestionListResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const PermissionReplyRequest = struct {
    reply: []const u8,
};

pub const QuestionReplyRequest = struct {
    answers: []QuestionAnswerDto,

    pub fn deinit(self: *QuestionReplyRequest, allocator: std.mem.Allocator) void {
        for (self.answers) |*answer| answer.deinit(allocator);
        allocator.free(self.answers);
    }
};

pub const QuestionAnswerDto = struct {
    selections: [][]const u8,

    pub fn clone(self: QuestionAnswerDto, allocator: std.mem.Allocator) !QuestionAnswerDto {
        return .{
            .selections = try question.cloneStringSlice(allocator, self.selections),
        };
    }

    pub fn deinit(self: *QuestionAnswerDto, allocator: std.mem.Allocator) void {
        question.freeStringSlice(allocator, self.selections);
    }
};

pub const HistoryResponse = struct {
    items: []MessageDto,

    pub fn clone(self: HistoryResponse, allocator: std.mem.Allocator) !HistoryResponse {
        const items = try allocator.alloc(MessageDto, self.items.len);
        errdefer allocator.free(items);
        for (self.items, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *HistoryResponse, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
    }
};

pub const MessageDto = struct {
    id: []const u8,
    role: []const u8,
    agent_id: ?[]const u8 = null,
    provider_id: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    completed: bool,
    error_code: ?[]const u8 = null,
    created_at_ms: i64,
    parts: []PartDto,

    pub fn clone(self: MessageDto, allocator: std.mem.Allocator) !MessageDto {
        const parts = try allocator.alloc(PartDto, self.parts.len);
        errdefer allocator.free(parts);
        for (self.parts, 0..) |part, index| {
            parts[index] = try part.clone(allocator);
            errdefer parts[index].deinit(allocator);
        }
        return .{
            .id = try allocator.dupe(u8, self.id),
            .role = try allocator.dupe(u8, self.role),
            .agent_id = if (self.agent_id) |agent_id| try allocator.dupe(u8, agent_id) else null,
            .provider_id = if (self.provider_id) |provider_id| try allocator.dupe(u8, provider_id) else null,
            .model_id = if (self.model_id) |model_id| try allocator.dupe(u8, model_id) else null,
            .completed = self.completed,
            .error_code = if (self.error_code) |error_code| try allocator.dupe(u8, error_code) else null,
            .created_at_ms = self.created_at_ms,
            .parts = parts,
        };
    }

    pub fn deinit(self: *MessageDto, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.role);
        if (self.agent_id) |agent_id| allocator.free(agent_id);
        if (self.provider_id) |provider_id| allocator.free(provider_id);
        if (self.model_id) |model_id| allocator.free(model_id);
        if (self.error_code) |error_code| allocator.free(error_code);
        for (self.parts) |*part| part.deinit(allocator);
        allocator.free(self.parts);
    }
};

pub const PartDto = struct {
    id: []const u8,
    kind: []const u8,
    text: ?[]const u8 = null,
    compacted_until_message_id: ?[]const u8 = null,
    original_message_count: ?u32 = null,
    call_id: ?[]const u8 = null,
    tool_name: ?[]const u8 = null,
    input_json: ?[]const u8 = null,
    output_text: ?[]const u8 = null,
    metadata_json: ?[]const u8 = null,
    child_session_id: ?[]const u8 = null,
    agent_id: ?[]const u8 = null,
    status: ?[]const u8 = null,
    summary: ?[]const u8 = null,
    batch_id: ?[]const u8 = null,
    success_count: ?u32 = null,
    failure_count: ?u32 = null,
    child_results_json: ?[]const u8 = null,

    pub fn clone(self: PartDto, allocator: std.mem.Allocator) !PartDto {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .kind = try allocator.dupe(u8, self.kind),
            .text = if (self.text) |value| try allocator.dupe(u8, value) else null,
            .compacted_until_message_id = if (self.compacted_until_message_id) |value| try allocator.dupe(u8, value) else null,
            .original_message_count = self.original_message_count,
            .call_id = if (self.call_id) |value| try allocator.dupe(u8, value) else null,
            .tool_name = if (self.tool_name) |value| try allocator.dupe(u8, value) else null,
            .input_json = if (self.input_json) |value| try allocator.dupe(u8, value) else null,
            .output_text = if (self.output_text) |value| try allocator.dupe(u8, value) else null,
            .metadata_json = if (self.metadata_json) |value| try allocator.dupe(u8, value) else null,
            .child_session_id = if (self.child_session_id) |value| try allocator.dupe(u8, value) else null,
            .agent_id = if (self.agent_id) |value| try allocator.dupe(u8, value) else null,
            .status = if (self.status) |value| try allocator.dupe(u8, value) else null,
            .summary = if (self.summary) |value| try allocator.dupe(u8, value) else null,
            .batch_id = if (self.batch_id) |value| try allocator.dupe(u8, value) else null,
            .success_count = self.success_count,
            .failure_count = self.failure_count,
            .child_results_json = if (self.child_results_json) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *PartDto, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.kind);
        if (self.text) |value| allocator.free(value);
        if (self.compacted_until_message_id) |value| allocator.free(value);
        if (self.call_id) |value| allocator.free(value);
        if (self.tool_name) |value| allocator.free(value);
        if (self.input_json) |value| allocator.free(value);
        if (self.output_text) |value| allocator.free(value);
        if (self.metadata_json) |value| allocator.free(value);
        if (self.child_session_id) |value| allocator.free(value);
        if (self.agent_id) |value| allocator.free(value);
        if (self.status) |value| allocator.free(value);
        if (self.summary) |value| allocator.free(value);
        if (self.batch_id) |value| allocator.free(value);
        if (self.child_results_json) |value| allocator.free(value);
    }
};

pub const RuntimeEventDto = struct {
    seq: u64,
    topic: []const u8,
    ts_unix_ms: i64,
    payload_json: []const u8,

    pub fn clone(self: RuntimeEventDto, allocator: std.mem.Allocator) !RuntimeEventDto {
        return .{
            .seq = self.seq,
            .topic = try allocator.dupe(u8, self.topic),
            .ts_unix_ms = self.ts_unix_ms,
            .payload_json = try allocator.dupe(u8, self.payload_json),
        };
    }

    pub fn deinit(self: *RuntimeEventDto, allocator: std.mem.Allocator) void {
        allocator.free(self.topic);
        allocator.free(self.payload_json);
    }
};

pub fn fromSessionInfo(allocator: std.mem.Allocator, info: session.SessionInfo) !SessionResponse {
    return .{
        .session_id = try allocator.dupe(u8, info.id),
        .title = try allocator.dupe(u8, info.title),
        .agent_id = try allocator.dupe(u8, info.agent_id),
        .parent_id = if (info.parent_id) |parent_id| try allocator.dupe(u8, parent_id) else null,
        .archived = info.archived,
        .created_at_ms = info.created_at_ms,
        .updated_at_ms = info.updated_at_ms,
    };
}

pub fn fromCreatedSession(allocator: std.mem.Allocator, info: session.SessionInfo) !CreateSessionResponse {
    return .{
        .session_id = try allocator.dupe(u8, info.id),
        .title = try allocator.dupe(u8, info.title),
        .agent_id = try allocator.dupe(u8, info.agent_id),
        .created_at_ms = info.created_at_ms,
        .updated_at_ms = info.updated_at_ms,
    };
}

pub fn fromStatusInfo(allocator: std.mem.Allocator, info: session.SessionStatusInfo) !SessionStatusDto {
    return .{
        .session_id = try allocator.dupe(u8, info.session_id),
        .status = try allocator.dupe(u8, info.status.asText()),
        .request_id = if (info.request_id) |request_id| try allocator.dupe(u8, request_id) else null,
        .task_id = if (info.task_id) |task_id| try allocator.dupe(u8, task_id) else null,
        .updated_at_ms = info.updated_at_ms,
    };
}

pub fn fromLspStatus(allocator: std.mem.Allocator, status: @import("../lsp/root.zig").Status) !LspStatusDto {
    return .{
        .id = try allocator.dupe(u8, status.id),
        .root = try allocator.dupe(u8, status.root),
        .status = try allocator.dupe(u8, status.status.asText()),
        .error_message = if (status.error_message) |value| try allocator.dupe(u8, value) else null,
    };
}

pub fn fromFormatterStatus(allocator: std.mem.Allocator, status: formatter.FormatterInfo) !FormatterStatusDto {
    return .{
        .name = try allocator.dupe(u8, status.name),
        .enabled = status.enabled,
        .extensions = try question.cloneStringSlice(allocator, status.extensions),
    };
}

pub fn fromMcpStatus(allocator: std.mem.Allocator, status: mcp.Status) !McpStatusDto {
    return .{
        .id = try allocator.dupe(u8, status.id),
        .transport = try allocator.dupe(u8, status.transport),
        .status = try allocator.dupe(u8, status.status.asText()),
        .error_message = if (status.error_message) |value| try allocator.dupe(u8, value) else null,
        .tool_count = status.tool_count,
        .resource_count = status.resource_count,
    };
}

pub fn fromProviderCatalogEntry(allocator: std.mem.Allocator, entry: @import("../provider/root.zig").ProviderRegistry.ProviderCatalogEntry) !ProviderCatalogProviderDto {
    const models = try allocator.alloc(ProviderModelDto, entry.models.len);
    errdefer allocator.free(models);
    for (entry.models, 0..) |item, index| {
        models[index] = .{
            .provider_id = try allocator.dupe(u8, item.provider_id),
            .model_id = try allocator.dupe(u8, item.model_id),
            .display_name = try allocator.dupe(u8, item.display_name),
        };
        errdefer models[index].deinit(allocator);
    }
    const default_model = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ entry.default_model.provider_id, entry.default_model.model_id });
    errdefer allocator.free(default_model);
    return .{
        .id = try allocator.dupe(u8, entry.id),
        .display_name = try allocator.dupe(u8, entry.display_name),
        .auth_kind = try allocator.dupe(u8, entry.auth_kind.asText()),
        .has_credentials = entry.has_credentials,
        .status = try allocator.dupe(u8, entry.status),
        .default_model = default_model,
        .models = models,
    };
}

pub fn fromProviderAuthStatus(allocator: std.mem.Allocator, item: @import("../provider/root.zig").ProviderAuthStatus) !ProviderAuthStatusDto {
    return .{
        .provider_id = try allocator.dupe(u8, item.provider_id),
        .has_api_key = item.has_api_key,
    };
}

pub fn fromPtyInfo(allocator: std.mem.Allocator, info: pty.PtyInfo) !PtyInfoResponse {
    return .{
        .id = try allocator.dupe(u8, info.id),
        .cwd = try allocator.dupe(u8, info.cwd),
        .shell = try allocator.dupe(u8, info.shell),
        .status = try allocator.dupe(u8, info.status.asText()),
        .created_at_ms = info.created_at_ms,
        .updated_at_ms = info.updated_at_ms,
        .exit_code = info.exit_code,
    };
}

pub fn fromPtyChunk(allocator: std.mem.Allocator, chunk: pty.OutputChunk) !PtyOutputChunkDto {
    return .{
        .seq = chunk.seq,
        .pty_id = try allocator.dupe(u8, chunk.pty_id),
        .stream = try allocator.dupe(u8, chunk.stream.asText()),
        .data = try allocator.dupe(u8, chunk.data),
        .ts_unix_ms = chunk.ts_unix_ms,
    };
}

pub fn fromProjectInfo(allocator: std.mem.Allocator, info: project.ProjectInfo) !ProjectResponse {
    return .{
        .name = try allocator.dupe(u8, info.name),
        .workspace_dir = try allocator.dupe(u8, info.workspace_dir),
        .project_root = try allocator.dupe(u8, info.project_root),
        .vcs_available = info.vcs.available,
        .branch = if (info.vcs.branch) |value| try allocator.dupe(u8, value) else null,
        .dirty = info.vcs.dirty,
        .changed_file_count = info.vcs.changed_file_count,
    };
}

pub fn fromWorkspaceInfo(allocator: std.mem.Allocator, info: project.WorkspaceInfo) !WorkspaceResponse {
    return .{
        .id = try allocator.dupe(u8, info.id),
        .name = try allocator.dupe(u8, info.name),
        .path = try allocator.dupe(u8, info.path),
        .created_at_ms = info.created_at_ms,
    };
}

pub fn fromPluginInfo(allocator: std.mem.Allocator, info: plugin.PluginInfo) !PluginResponse {
    const hooks = try allocator.alloc([]const u8, info.hooks.len);
    errdefer allocator.free(hooks);
    for (info.hooks, 0..) |hook, index| {
        hooks[index] = try allocator.dupe(u8, hook.name);
    }
    return .{
        .id = try allocator.dupe(u8, info.id),
        .path = try allocator.dupe(u8, info.path),
        .description = if (info.description) |value| try allocator.dupe(u8, value) else null,
        .enabled = info.enabled,
        .hooks = hooks,
    };
}

pub fn fromSkillInfo(allocator: std.mem.Allocator, info: skill.SkillInfo) !SkillResponse {
    return .{
        .id = try allocator.dupe(u8, info.id),
        .name = try allocator.dupe(u8, info.name),
        .path = try allocator.dupe(u8, info.path),
        .summary = try allocator.dupe(u8, info.summary),
    };
}

pub fn fromHistory(allocator: std.mem.Allocator, items: []const session.MessageWithParts) !HistoryResponse {
    const messages = try allocator.alloc(MessageDto, items.len);
    errdefer allocator.free(messages);

    for (items, 0..) |item, index| {
        messages[index] = try fromMessageWithParts(allocator, item);
        errdefer messages[index].deinit(allocator);
    }
    return .{ .items = messages };
}

fn fromMessageWithParts(allocator: std.mem.Allocator, item: session.MessageWithParts) !MessageDto {
    const parts = try allocator.alloc(PartDto, item.parts.len);
    errdefer allocator.free(parts);

    for (item.parts, 0..) |part, index| {
        parts[index] = try fromMessagePart(allocator, part);
        errdefer parts[index].deinit(allocator);
    }

    return .{
        .id = try allocator.dupe(u8, item.info.id),
        .role = try allocator.dupe(u8, item.info.role.asText()),
        .agent_id = if (item.info.agent_id) |agent_id| try allocator.dupe(u8, agent_id) else null,
        .provider_id = if (item.info.provider_id) |provider_id| try allocator.dupe(u8, provider_id) else null,
        .model_id = if (item.info.model_id) |model_id| try allocator.dupe(u8, model_id) else null,
        .completed = item.info.completed,
        .error_code = if (item.info.error_code) |error_code| try allocator.dupe(u8, error_code) else null,
        .created_at_ms = item.info.created_at_ms,
        .parts = parts,
    };
}

fn fromMessagePart(allocator: std.mem.Allocator, part: session.MessagePart) !PartDto {
    return switch (part) {
        .text => |value| .{
            .id = try allocator.dupe(u8, value.id),
            .kind = try allocator.dupe(u8, "text"),
            .text = try allocator.dupe(u8, value.text),
        },
        .reasoning => |value| .{
            .id = try allocator.dupe(u8, value.id),
            .kind = try allocator.dupe(u8, "reasoning"),
            .text = try allocator.dupe(u8, value.text),
        },
        .tool_call => |value| .{
            .id = try allocator.dupe(u8, value.id),
            .kind = try allocator.dupe(u8, "tool_call"),
            .call_id = try allocator.dupe(u8, value.call_id),
            .tool_name = try allocator.dupe(u8, value.tool_name),
            .input_json = try allocator.dupe(u8, value.input_json),
        },
        .tool_result => |value| .{
            .id = try allocator.dupe(u8, value.id),
            .kind = try allocator.dupe(u8, "tool_result"),
            .call_id = try allocator.dupe(u8, value.call_id),
            .tool_name = try allocator.dupe(u8, value.tool_name),
            .output_text = try allocator.dupe(u8, value.output_text),
            .metadata_json = try allocator.dupe(u8, value.metadata_json),
        },
        .system_reminder => |value| .{
            .id = try allocator.dupe(u8, value.id),
            .kind = try allocator.dupe(u8, "system_reminder"),
            .text = try allocator.dupe(u8, value.text),
        },
        .compaction_summary => |value| .{
            .id = try allocator.dupe(u8, value.id),
            .kind = try allocator.dupe(u8, "compaction_summary"),
            .compacted_until_message_id = try allocator.dupe(u8, value.compacted_until_message_id),
            .original_message_count = value.original_message_count,
            .summary = try allocator.dupe(u8, value.summary),
        },
        .subtask => |value| .{
            .id = try allocator.dupe(u8, value.id),
            .kind = try allocator.dupe(u8, "subtask"),
            .child_session_id = try allocator.dupe(u8, value.child_session_id),
            .agent_id = try allocator.dupe(u8, value.agent_id),
            .status = try allocator.dupe(u8, value.status),
            .summary = try allocator.dupe(u8, value.summary),
        },
        .subtask_aggregate => |value| .{
            .id = try allocator.dupe(u8, value.id),
            .kind = try allocator.dupe(u8, "subtask_aggregate"),
            .batch_id = try allocator.dupe(u8, value.batch_id),
            .summary = try allocator.dupe(u8, value.summary),
            .success_count = value.success_count,
            .failure_count = value.failure_count,
            .child_results_json = try allocator.dupe(u8, value.child_results_json),
        },
    };
}

test "history dto conversion preserves tool parts" {
    var message = session.MessageWithParts{
        .info = .{
            .id = try std.testing.allocator.dupe(u8, "message_01"),
            .session_id = try std.testing.allocator.dupe(u8, "session_01"),
            .role = .assistant,
            .created_at_ms = 1,
            .completed = true,
        },
        .parts = try std.testing.allocator.alloc(session.MessagePart, 1),
    };
    defer message.deinit(std.testing.allocator);
    message.parts[0] = try session.toolCallPart(std.testing.allocator, "call_01", "read_file", "{\"path\":\"a\"}");

    var dto = try fromHistory(std.testing.allocator, &.{message});
    defer dto.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), dto.items.len);
    try std.testing.expectEqual(@as(usize, 1), dto.items[0].parts.len);
    try std.testing.expectEqualStrings("tool_call", dto.items[0].parts[0].kind);
}
