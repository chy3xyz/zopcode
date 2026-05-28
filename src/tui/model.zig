const std = @import("std");
const permission = @import("../permission/root.zig");
const question = @import("../question/root.zig");
const server = @import("../server/root.zig");

pub const Panel = enum {
    dashboard,
    sessions,
    workspaces,
    runtime,
    pending,

    pub fn asText(self: Panel) []const u8 {
        return switch (self) {
            .dashboard => "dashboard",
            .sessions => "sessions",
            .workspaces => "workspaces",
            .runtime => "runtime",
            .pending => "pending",
        };
    }
};

pub const TerminalViewModel = struct {
    allocator: std.mem.Allocator,
    active_session_id: ?[]u8 = null,
    active_agent_id: ?[]u8 = null,
    active_model: ?[]u8 = null,
    status: []u8,
    recent_tool: ?[]u8 = null,
    latest_response: ?[]u8 = null,
    active_panel: Panel = .dashboard,
    project: ?server.ProjectResponse = null,
    session_statuses: []server.SessionStatusDto = &.{},
    workspaces: []server.WorkspaceResponse = &.{},
    provider_catalog: ?server.ProviderCatalogResponse = null,
    formatter_statuses: []server.FormatterStatusDto = &.{},
    lsp_statuses: []server.LspStatusDto = &.{},
    mcp_statuses: []server.McpStatusDto = &.{},
    pending_permissions: []permission.PermissionRequest = &.{},
    pending_questions: []question.QuestionRequest = &.{},
    event_lines: std.ArrayListUnmanaged([]u8) = .empty,
    max_event_lines: usize = 16,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, max_event_lines: usize) !Self {
        return .{
            .allocator = allocator,
            .status = try allocator.dupe(u8, "idle"),
            .max_event_lines = max_event_lines,
        };
    }

    pub fn deinit(self: *Self) void {
        if (self.active_session_id) |value| self.allocator.free(value);
        if (self.active_agent_id) |value| self.allocator.free(value);
        if (self.active_model) |value| self.allocator.free(value);
        self.allocator.free(self.status);
        if (self.recent_tool) |value| self.allocator.free(value);
        if (self.latest_response) |value| self.allocator.free(value);
        if (self.project) |*value| value.deinit(self.allocator);
        if (self.provider_catalog) |*value| value.deinit(self.allocator);
        for (self.session_statuses) |*item| item.deinit(self.allocator);
        if (self.session_statuses.len > 0) self.allocator.free(self.session_statuses);
        for (self.workspaces) |*item| item.deinit(self.allocator);
        if (self.workspaces.len > 0) self.allocator.free(self.workspaces);
        for (self.formatter_statuses) |*item| item.deinit(self.allocator);
        if (self.formatter_statuses.len > 0) self.allocator.free(self.formatter_statuses);
        for (self.lsp_statuses) |*item| item.deinit(self.allocator);
        if (self.lsp_statuses.len > 0) self.allocator.free(self.lsp_statuses);
        for (self.mcp_statuses) |*item| item.deinit(self.allocator);
        if (self.mcp_statuses.len > 0) self.allocator.free(self.mcp_statuses);
        for (self.pending_permissions) |*item| item.deinit(self.allocator);
        if (self.pending_permissions.len > 0) self.allocator.free(self.pending_permissions);
        for (self.pending_questions) |*item| item.deinit(self.allocator);
        if (self.pending_questions.len > 0) self.allocator.free(self.pending_questions);
        for (self.event_lines.items) |line| self.allocator.free(line);
        self.event_lines.deinit(self.allocator);
    }

    pub fn setSession(self: *Self, session_id: []const u8) !void {
        if (self.active_session_id) |value| self.allocator.free(value);
        self.active_session_id = try self.allocator.dupe(u8, session_id);
    }

    pub fn setAgent(self: *Self, agent_id: []const u8) !void {
        if (self.active_agent_id) |value| self.allocator.free(value);
        self.active_agent_id = try self.allocator.dupe(u8, agent_id);
    }

    pub fn setModel(self: *Self, model_id: []const u8) !void {
        if (self.active_model) |value| self.allocator.free(value);
        self.active_model = try self.allocator.dupe(u8, model_id);
    }

    pub fn setStatus(self: *Self, status_text: []const u8) !void {
        self.allocator.free(self.status);
        self.status = try self.allocator.dupe(u8, status_text);
    }

    pub fn setRecentTool(self: *Self, tool_name: []const u8) !void {
        if (self.recent_tool) |value| self.allocator.free(value);
        self.recent_tool = try self.allocator.dupe(u8, tool_name);
    }

    pub fn setLatestResponse(self: *Self, response_text: []const u8) !void {
        if (self.latest_response) |value| self.allocator.free(value);
        self.latest_response = try self.allocator.dupe(u8, response_text);
    }

    pub fn setPanel(self: *Self, panel: Panel) void {
        self.active_panel = panel;
    }

    pub fn replaceProject(self: *Self, value: ?server.ProjectResponse) !void {
        if (self.project) |*existing| existing.deinit(self.allocator);
        self.project = if (value) |item| try item.clone(self.allocator) else null;
    }

    pub fn replaceSessionStatuses(self: *Self, items: []const server.SessionStatusDto) !void {
        for (self.session_statuses) |*item| item.deinit(self.allocator);
        if (self.session_statuses.len > 0) self.allocator.free(self.session_statuses);
        self.session_statuses = try cloneSlice(server.SessionStatusDto, self.allocator, items);
    }

    pub fn replaceWorkspaces(self: *Self, items: []const server.WorkspaceResponse) !void {
        for (self.workspaces) |*item| item.deinit(self.allocator);
        if (self.workspaces.len > 0) self.allocator.free(self.workspaces);
        self.workspaces = try cloneSlice(server.WorkspaceResponse, self.allocator, items);
    }

    pub fn replaceProviderCatalog(self: *Self, value: ?server.ProviderCatalogResponse) !void {
        if (self.provider_catalog) |*existing| existing.deinit(self.allocator);
        self.provider_catalog = if (value) |item| try item.clone(self.allocator) else null;
    }

    pub fn replaceFormatterStatuses(self: *Self, items: []const server.FormatterStatusDto) !void {
        for (self.formatter_statuses) |*item| item.deinit(self.allocator);
        if (self.formatter_statuses.len > 0) self.allocator.free(self.formatter_statuses);
        self.formatter_statuses = try cloneSlice(server.FormatterStatusDto, self.allocator, items);
    }

    pub fn replaceLspStatuses(self: *Self, items: []const server.LspStatusDto) !void {
        for (self.lsp_statuses) |*item| item.deinit(self.allocator);
        if (self.lsp_statuses.len > 0) self.allocator.free(self.lsp_statuses);
        self.lsp_statuses = try cloneSlice(server.LspStatusDto, self.allocator, items);
    }

    pub fn replaceMcpStatuses(self: *Self, items: []const server.McpStatusDto) !void {
        for (self.mcp_statuses) |*item| item.deinit(self.allocator);
        if (self.mcp_statuses.len > 0) self.allocator.free(self.mcp_statuses);
        self.mcp_statuses = try cloneSlice(server.McpStatusDto, self.allocator, items);
    }

    pub fn replacePendingPermissions(self: *Self, items: []const permission.PermissionRequest) !void {
        for (self.pending_permissions) |*item| item.deinit(self.allocator);
        if (self.pending_permissions.len > 0) self.allocator.free(self.pending_permissions);
        self.pending_permissions = try cloneSlice(permission.PermissionRequest, self.allocator, items);
    }

    pub fn replacePendingQuestions(self: *Self, items: []const question.QuestionRequest) !void {
        for (self.pending_questions) |*item| item.deinit(self.allocator);
        if (self.pending_questions.len > 0) self.allocator.free(self.pending_questions);
        self.pending_questions = try cloneSlice(question.QuestionRequest, self.allocator, items);
    }

    pub fn appendEventLine(self: *Self, line: []const u8) !void {
        if (self.event_lines.items.len == self.max_event_lines and self.event_lines.items.len > 0) {
            const removed = self.event_lines.orderedRemove(0);
            self.allocator.free(removed);
        }
        try self.event_lines.append(self.allocator, try self.allocator.dupe(u8, line));
    }

    pub fn pendingInteractionCount(self: *const Self) usize {
        return self.pending_permissions.len + self.pending_questions.len;
    }
};

fn cloneSlice(comptime T: type, allocator: std.mem.Allocator, input: []const T) ![]T {
    const items = try allocator.alloc(T, input.len);
    errdefer allocator.free(items);
    for (input, 0..) |item, index| {
        items[index] = try item.clone(allocator);
        errdefer items[index].deinit(allocator);
    }
    return items;
}

test "terminal view model keeps rich state and pending counts" {
    var model = try TerminalViewModel.init(std.testing.allocator, 2);
    defer model.deinit();

    try model.setStatus("running");
    try model.setRecentTool("read_file");
    model.setPanel(.pending);

    try model.replaceSessionStatuses(&.{
        .{ .session_id = "session_01", .status = "running", .updated_at_ms = 1 },
    });
    try model.replaceWorkspaces(&.{
        .{ .id = "workspace_01", .name = "demo", .path = "E:/demo", .created_at_ms = 1 },
    });
    try model.replacePendingPermissions(&.{
        .{ .id = "perm_01", .session_id = "session_01", .permission = "edit", .patterns = @constCast(&[_][]const u8{"src/main.zig"}) },
    });
    try model.replacePendingQuestions(&.{
        .{ .id = "question_01", .session_id = "session_01", .questions = @constCast(&[_]question.QuestionInfo{
            .{ .header = "Mode", .question = "Choose", .options = @constCast(&[_]question.QuestionOption{.{ .label = "A", .description = "alpha" }}) },
        }) },
    });
    try model.appendEventLine("first");
    try model.appendEventLine("second");
    try model.appendEventLine("third");

    try std.testing.expectEqualStrings("running", model.status);
    try std.testing.expectEqualStrings("read_file", model.recent_tool.?);
    try std.testing.expectEqual(@as(usize, 1), model.session_statuses.len);
    try std.testing.expectEqual(@as(usize, 1), model.workspaces.len);
    try std.testing.expectEqual(@as(usize, 2), model.pendingInteractionCount());
    try std.testing.expectEqual(@as(usize, 2), model.event_lines.items.len);
    try std.testing.expectEqualStrings("second", model.event_lines.items[0]);
}
