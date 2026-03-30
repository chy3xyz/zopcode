//! zig-opencode — foundation scaffold for a Zig AI coding agent.

const std = @import("std");
const framework_pkg = @import("framework");

pub const PACKAGE_NAME = "zig-opencode";
pub const PACKAGE_VERSION = "0.1.0";

pub const framework = framework_pkg;
pub const app_context = @import("app_context.zig");
pub const config = @import("config/root.zig");
pub const session = @import("session/root.zig");
pub const llm = @import("llm/root.zig");
pub const provider = @import("provider/root.zig");
pub const project = @import("project/root.zig");
pub const plugin = @import("plugin/root.zig");
pub const agent = @import("agent/root.zig");
pub const lsp = @import("lsp/root.zig");
pub const mcp = @import("mcp/root.zig");
pub const formatter = @import("formatter/root.zig");
pub const loop = @import("loop/root.zig");
pub const orchestration = @import("orchestration/root.zig");
pub const permission = @import("permission/root.zig");
pub const pty = @import("pty/root.zig");
pub const prompt = @import("prompt/root.zig");
pub const question = @import("question/root.zig");
pub const skill = @import("skill/root.zig");
pub const framework_integration = @import("framework_integration/root.zig");
pub const tools = @import("tools/root.zig");
pub const tui = @import("tui/root.zig");
pub const server = @import("server/root.zig");
pub const client = @import("client/root.zig");

pub const AppContext = app_context.AppContext;
pub const ConfigRuntime = config.ConfigRuntime;
pub const EffectiveConfig = config.EffectiveConfig;
pub const AgentRegistry = agent.AgentRegistry;
pub const AgentProfile = agent.AgentProfile;
pub const CategoryId = agent.CategoryId;
pub const CategoryExecutionPlan = agent.CategoryExecutionPlan;
pub const LspRuntime = lsp.LspRuntime;
pub const LspStatus = lsp.Status;
pub const LspDiagnostic = lsp.Diagnostic;
pub const McpRuntime = mcp.McpRuntime;
pub const McpStatus = mcp.Status;
pub const FormatterRuntime = formatter.FormatterRuntime;
pub const FormatterInfo = formatter.FormatterInfo;
pub const PtyRuntime = pty.PtyRuntime;
pub const PtyInfo = pty.PtyInfo;
pub const LoopService = loop.LoopService;
pub const LoopState = loop.LoopState;
pub const LoopStrategy = loop.LoopStrategy;
pub const PermissionRuntime = permission.PermissionRuntime;
pub const PermissionRequest = permission.PermissionRequest;
pub const QuestionRuntime = question.QuestionRuntime;
pub const QuestionRequest = question.QuestionRequest;
pub const OrchestrationService = orchestration.OrchestrationService;
pub const ChildRequest = orchestration.ChildRequest;
pub const ChildResult = orchestration.ChildResult;
pub const AggregatedResult = orchestration.AggregatedResult;
pub const AssembledPrompt = prompt.AssembledPrompt;
pub const SessionStore = session.SessionStore;
pub const SessionRuntime = session.SessionRuntime;
pub const FileSessionStore = session.FileSessionStore;
pub const HistoryService = session.HistoryService;
pub const MessageWithParts = session.MessageWithParts;
pub const ConversationMessage = session.ConversationMessage;
pub const CompactionPolicy = session.CompactionPolicy;
pub const SessionInfo = session.SessionInfo;
pub const MessageInfo = session.MessageInfo;
pub const MessagePart = session.MessagePart;
pub const ProviderRegistry = provider.ProviderRegistry;
pub const ProviderClient = provider.ProviderClient;
pub const ProviderRequest = provider.ProviderRequest;
pub const ProviderStreamEvent = provider.ProviderStreamEvent;
pub const ProjectRuntime = project.ProjectRuntime;
pub const ProjectInfo = project.ProjectInfo;
pub const WorkspaceInfo = project.WorkspaceInfo;
pub const PluginRuntime = plugin.PluginRuntime;
pub const PluginInfo = plugin.PluginInfo;
pub const SkillRuntime = skill.SkillRuntime;
pub const SkillInfo = skill.SkillInfo;
pub const ToolRegistry = tools.ToolRegistry;
pub const ToolRuntime = tools.ToolRuntime;
pub const ToolDefinition = tools.ToolDefinition;
pub const ToolResult = tools.ToolResult;
pub const ServerServices = server.ServerServices;
pub const Client = client.Client;
pub const ClientTransport = client.ClientTransport;

test {
    std.testing.refAllDecls(@This());
}

test "zig-opencode metadata is non-empty" {
    try std.testing.expect(PACKAGE_NAME.len > 0);
    try std.testing.expect(PACKAGE_VERSION.len > 0);
}

test "framework dependency is available through package root" {
    try std.testing.expectEqualStrings("framework", framework.PACKAGE_NAME);
}

test "foundation module scaffold exports are available" {
    try std.testing.expectEqualStrings("session", session.MODULE_NAME);
    try std.testing.expectEqualStrings("config", config.MODULE_NAME);
    try std.testing.expectEqualStrings("llm", llm.MODULE_NAME);
    try std.testing.expectEqualStrings("provider", provider.MODULE_NAME);
    try std.testing.expectEqualStrings("project", project.MODULE_NAME);
    try std.testing.expectEqualStrings("plugin", plugin.MODULE_NAME);
    try std.testing.expectEqualStrings("agent", agent.MODULE_NAME);
    try std.testing.expectEqualStrings("lsp", lsp.MODULE_NAME);
    try std.testing.expectEqualStrings("mcp", mcp.MODULE_NAME);
    try std.testing.expectEqualStrings("formatter", formatter.MODULE_NAME);
    try std.testing.expectEqualStrings("pty", pty.MODULE_NAME);
    try std.testing.expectEqualStrings("loop", loop.MODULE_NAME);
    try std.testing.expectEqualStrings("permission", permission.MODULE_NAME);
    try std.testing.expectEqualStrings("orchestration", orchestration.MODULE_NAME);
    try std.testing.expectEqualStrings("question", question.MODULE_NAME);
    try std.testing.expectEqualStrings("prompt", prompt.MODULE_NAME);
    try std.testing.expectEqualStrings("framework_integration", framework_integration.MODULE_NAME);
    try std.testing.expectEqualStrings("tools", tools.MODULE_NAME);
    try std.testing.expectEqualStrings("skill", skill.MODULE_NAME);
    try std.testing.expectEqualStrings("tui", tui.MODULE_NAME);
    try std.testing.expectEqualStrings("server", server.MODULE_NAME);
    try std.testing.expectEqualStrings("client", client.MODULE_NAME);
}
