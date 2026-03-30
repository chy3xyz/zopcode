const std = @import("std");
const framework = @import("framework");
const formatter = @import("../formatter/root.zig");
const lsp = @import("../lsp/root.zig");
const mcp = @import("../mcp/runtime.zig");
const question = @import("../question/root.zig");
const snapshot = @import("../session/snapshot.zig");
const skill = @import("../skill/root.zig");
const framework_integration = @import("../framework_integration/root.zig");
const result_model = @import("result.zig");

pub const HashlineEditBackend = struct {
    ptr: *anyopaque,
    edit: *const fn (ptr: *anyopaque, ctx: *const ToolExecutionContext, params: []const framework.ValidationField) anyerror!result_model.ToolResult,
};

pub const ToolExecutionContext = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    task_runner: ?*framework.TaskRunner = null,
    event_bus: ?framework.EventBus = null,
    request_id: []const u8,
    trace_id: ?[]const u8 = null,
    tool_id: []const u8,
    session_id: ?[]const u8 = null,
    message_id: ?[]const u8 = null,
    call_id: []const u8,
    working_dir: []const u8,
    hashline_backend: ?HashlineEditBackend = null,
    formatter_runtime: ?*formatter.FormatterRuntime = null,
    lsp_runtime: ?*lsp.LspRuntime = null,
    mcp_runtime: ?*mcp.McpRuntime = null,
    snapshot_service: ?*snapshot.SnapshotService = null,
    skill_runtime: ?*skill.SkillRuntime = null,
    question_runtime: ?*question.QuestionRuntime = null,
    framework_tooling: ?*framework_integration.ToolingBridge = null,
};

pub fn resolvePath(allocator: std.mem.Allocator, working_dir: []const u8, raw_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) {
        return allocator.dupe(u8, raw_path);
    }
    return std.fs.path.join(allocator, &.{ working_dir, raw_path });
}
