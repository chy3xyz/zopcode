const std = @import("std");
const framework = @import("framework");
const config = @import("../config/root.zig");
const builtin = @import("builtin/root.zig");
const context_model = @import("context.zig");
const formatter_model = @import("../formatter/root.zig");
const hashline = @import("hashline/root.zig");
const lsp = @import("../lsp/root.zig");
const mcp_runtime_model = @import("../mcp/runtime.zig");
const permission = @import("../permission/root.zig");
const plugin_model = @import("../plugin/root.zig");
const question = @import("../question/root.zig");
const snapshot_model = @import("../session/snapshot.zig");
const skill_model = @import("../skill/root.zig");
const framework_integration = @import("../framework_integration/root.zig");
const registry_model = @import("registry.zig");
const result_model = @import("result.zig");
const tool_model = @import("tool.zig");

pub const ToolRuntime = struct {
    allocator: std.mem.Allocator,
    registry: *registry_model.ToolRegistry,
    logger: *framework.Logger,
    task_runner: *framework.TaskRunner,
    event_bus: framework.EventBus,
    working_dir: []u8,
    hashline_backend: ?context_model.HashlineEditBackend = null,
    formatter_runtime: ?*formatter_model.FormatterRuntime = null,
    lsp_runtime: ?*lsp.LspRuntime = null,
    mcp_runtime: ?*mcp_runtime_model.McpRuntime = null,
    snapshot_service: ?*snapshot_model.SnapshotService = null,
    plugin_runtime: ?*plugin_model.PluginRuntime = null,
    skill_runtime: ?*skill_model.SkillRuntime = null,
    permission_runtime: ?*permission.PermissionRuntime = null,
    question_runtime: ?*question.QuestionRuntime = null,
    framework_tooling: ?*framework_integration.ToolingBridge = null,
    adapters: std.ArrayListUnmanaged(*AdapterData) = .empty,

    const Self = @This();

    const AdapterData = struct {
        runtime: *Self,
        tool_id: []u8,
    };

    pub const ExecutionOverrides = struct {
        session_id: ?[]const u8 = null,
        message_id: ?[]const u8 = null,
        call_id: ?[]const u8 = null,
    };

    pub fn init(
        allocator: std.mem.Allocator,
        registry: *registry_model.ToolRegistry,
        logger: *framework.Logger,
        task_runner: *framework.TaskRunner,
        event_bus: framework.EventBus,
        working_dir: []const u8,
    ) !Self {
        var self = Self{
            .allocator = allocator,
            .registry = registry,
            .logger = logger,
            .task_runner = task_runner,
            .event_bus = event_bus,
            .working_dir = try allocator.dupe(u8, working_dir),
            .hashline_backend = hashline.backend.backend(),
        };
        errdefer allocator.free(self.working_dir);

        try self.registerBuiltins();
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.adapters.items) |adapter| {
            self.allocator.free(adapter.tool_id);
            self.allocator.destroy(adapter);
        }
        self.adapters.deinit(self.allocator);
        self.allocator.free(self.working_dir);
    }

    pub fn registerBuiltins(self: *Self) !void {
        for (builtin.builtins()) |definition| {
            try self.registry.register(definition);
        }
    }

    pub fn registerCommands(
        self: *Self,
        effective_config: config.EffectiveConfig,
        framework_app: *framework.AppContext,
    ) !void {
        for (self.registry.list()) |tool| {
            if (!toolEnabled(effective_config, tool.id)) continue;

            const adapter = try self.allocator.create(AdapterData);
            errdefer self.allocator.destroy(adapter);
            adapter.* = .{
                .runtime = self,
                .tool_id = try self.allocator.dupe(u8, tool.id),
            };
            errdefer self.allocator.free(adapter.tool_id);
            try self.adapters.append(self.allocator, adapter);

            try framework_app.registerCommand(.{
                .id = tool.id,
                .method = tool.id,
                .description = tool.description,
                .execution_mode = tool.execution_mode,
                .params = tool.params,
                .handler = if (tool.execution_mode == .sync) syncHandler else null,
                .async_handler = if (tool.execution_mode == .async_task) asyncHandler else null,
                .user_data = adapter,
            });
        }
    }

    fn executeTool(
        self: *Self,
        command_ctx: *const framework.CommandContext,
        definition: *const tool_model.ToolDefinition,
        overrides: ?ExecutionOverrides,
    ) !result_model.ToolResult {
        try self.authorizeTool(command_ctx, definition, overrides);

        try triggerPluginHook(self, "tool.before", command_ctx, definition, overrides, null);

        const tool_ctx = context_model.ToolExecutionContext{
            .allocator = command_ctx.allocator,
            .logger = self.logger,
            .task_runner = self.task_runner,
            .event_bus = self.event_bus,
            .request_id = command_ctx.request.request_id,
            .trace_id = command_ctx.request.trace_id,
            .session_id = if (overrides) |item| item.session_id else null,
            .message_id = if (overrides) |item| item.message_id else null,
            .call_id = if (overrides) |item| item.call_id orelse command_ctx.request.request_id else command_ctx.request.request_id,
            .working_dir = self.working_dir,
            .tool_id = definition.id,
            .hashline_backend = self.hashline_backend,
            .formatter_runtime = self.formatter_runtime,
            .lsp_runtime = self.lsp_runtime,
            .mcp_runtime = self.mcp_runtime,
            .snapshot_service = self.snapshot_service,
            .skill_runtime = self.skill_runtime,
            .question_runtime = self.question_runtime,
            .framework_tooling = self.framework_tooling,
        };

        errdefer triggerPluginHook(self, "tool.after", command_ctx, definition, overrides, "error") catch {};
        const result = switch (definition.execution_mode) {
            .sync => definition.execute_fn.?( &tool_ctx, command_ctx.validated_params ),
            .async_task => definition.async_execute_fn.?( &tool_ctx, command_ctx.validated_params ),
        };
        try triggerPluginHook(self, "tool.after", command_ctx, definition, overrides, "ok");
        return result;
    }

    pub fn executeById(
        self: *Self,
        command_ctx: *const framework.CommandContext,
        definition: *const tool_model.ToolDefinition,
        overrides: ?ExecutionOverrides,
    ) !result_model.ToolResult {
        return self.executeTool(command_ctx, definition, overrides);
    }

    fn syncHandler(command_ctx: *const framework.CommandContext) anyerror![]const u8 {
        const adapter = adapterFromContext(command_ctx);
        const definition = adapter.runtime.registry.get(adapter.tool_id) orelse return error.ToolNotFound;
        var result = try adapter.runtime.executeTool(command_ctx, definition, null);
        defer result.deinit(command_ctx.allocator);
        return result.toJson(command_ctx.allocator);
    }

    fn asyncHandler(command_ctx: *const framework.CommandContext) anyerror![]const u8 {
        return syncHandler(command_ctx);
    }

    fn adapterFromContext(command_ctx: *const framework.CommandContext) *AdapterData {
        return @ptrCast(@alignCast(command_ctx.user_data.?));
    }

    fn authorizeTool(
        self: *Self,
        command_ctx: *const framework.CommandContext,
        definition: *const tool_model.ToolDefinition,
        overrides: ?ExecutionOverrides,
    ) !void {
        const runtime = self.permission_runtime orelse return;
        const mapped = try permissionRequestForTool(command_ctx.allocator, self.working_dir, definition.id, command_ctx.validated_params);
        defer {
            command_ctx.allocator.free(mapped.permission_name);
            permission.types.freeStringSlice(command_ctx.allocator, mapped.patterns);
            command_ctx.allocator.free(mapped.metadata_json);
        }

        try runtime.authorize(.{
            .session_id = if (overrides) |item| item.session_id else null,
            .request_id = command_ctx.request.request_id,
            .message_id = if (overrides) |item| item.message_id else null,
            .call_id = if (overrides) |item| item.call_id else null,
            .tool_name = definition.id,
            .permission = mapped.permission_name,
            .patterns = mapped.patterns,
            .metadata_json = mapped.metadata_json,
        });
    }
};

fn toolEnabled(effective_config: config.EffectiveConfig, tool_id: []const u8) bool {
    if (std.mem.eql(u8, tool_id, "read_file")) return effective_config.tools.read_file_enabled;
    if (std.mem.eql(u8, tool_id, "write_file")) return effective_config.tools.write_file_enabled;
    if (std.mem.eql(u8, tool_id, "execute_shell")) return effective_config.tools.execute_shell_enabled;
    if (std.mem.eql(u8, tool_id, "list_files")) return effective_config.tools.list_files_enabled;
    if (std.mem.eql(u8, tool_id, "search_files")) return effective_config.tools.search_files_enabled;
    if (std.mem.eql(u8, tool_id, "fetch_url")) return effective_config.tools.fetch_url_enabled;
    if (std.mem.eql(u8, tool_id, "lsp")) return effective_config.tools.lsp_enabled;
    return true;
}

const ToolPermissionRequest = struct {
    permission_name: []u8,
    patterns: [][]const u8,
    metadata_json: []u8,
};

fn permissionRequestForTool(
    allocator: std.mem.Allocator,
    working_dir: []const u8,
    tool_id: []const u8,
    fields: []const framework.ValidationField,
) !ToolPermissionRequest {
    const metadata_json = try buildPermissionMetadata(allocator, tool_id, fields);
    errdefer allocator.free(metadata_json);

    if (std.mem.eql(u8, tool_id, "read_file")) return .{
        .permission_name = try allocator.dupe(u8, "read"),
        .patterns = try singlePattern(allocator, try pathPattern(allocator, working_dir, fields)),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "list_files")) return .{
        .permission_name = try allocator.dupe(u8, "read"),
        .patterns = try singlePattern(allocator, try pathPattern(allocator, working_dir, fields)),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "search_files")) return .{
        .permission_name = try allocator.dupe(u8, "read"),
        .patterns = try singlePattern(allocator, try pathPattern(allocator, working_dir, fields)),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "write_file")) return .{
        .permission_name = try allocator.dupe(u8, "edit"),
        .patterns = try singlePattern(allocator, try pathPattern(allocator, working_dir, fields)),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "edit_file")) return .{
        .permission_name = try allocator.dupe(u8, "edit"),
        .patterns = try singlePattern(allocator, try pathPattern(allocator, working_dir, fields)),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "revert_files")) return .{
        .permission_name = try allocator.dupe(u8, "edit"),
        .patterns = try singlePattern(allocator, try allocator.dupe(u8, "*")),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "execute_shell")) return .{
        .permission_name = try allocator.dupe(u8, "execute_shell"),
        .patterns = try singlePattern(allocator, try stringFieldOrDefault(allocator, fields, "command", "*")),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "fetch_url")) return .{
        .permission_name = try allocator.dupe(u8, "fetch_url"),
        .patterns = try singlePattern(allocator, try stringFieldOrDefault(allocator, fields, "url", "*")),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "repo_health_check")) return .{
        .permission_name = try allocator.dupe(u8, "read"),
        .patterns = try singlePattern(allocator, try pathPattern(allocator, working_dir, fields)),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "mcp_resource")) return .{
        .permission_name = try allocator.dupe(u8, "read"),
        .patterns = try singlePattern(allocator, try stringFieldOrDefault(allocator, fields, "uri", "*")),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "lsp")) return .{
        .permission_name = try allocator.dupe(u8, "lsp"),
        .patterns = try singlePattern(allocator, try pathPattern(allocator, working_dir, fields)),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "question")) return .{
        .permission_name = try allocator.dupe(u8, "question"),
        .patterns = try singlePattern(allocator, try allocator.dupe(u8, "*")),
        .metadata_json = metadata_json,
    };
    if (std.mem.eql(u8, tool_id, "skill")) return .{
        .permission_name = try allocator.dupe(u8, "read"),
        .patterns = try singlePattern(allocator, try allocator.dupe(u8, "*")),
        .metadata_json = metadata_json,
    };
    if (std.mem.startsWith(u8, tool_id, "mcp.")) return .{
        .permission_name = try allocator.dupe(u8, "mcp"),
        .patterns = try singlePattern(allocator, try allocator.dupe(u8, "*")),
        .metadata_json = metadata_json,
    };

    return .{
        .permission_name = try allocator.dupe(u8, tool_id),
        .patterns = try singlePattern(allocator, try allocator.dupe(u8, "*")),
        .metadata_json = metadata_json,
    };
}

fn triggerPluginHook(
    self: *ToolRuntime,
    hook_name: []const u8,
    command_ctx: *const framework.CommandContext,
    definition: *const tool_model.ToolDefinition,
    overrides: ?ToolRuntime.ExecutionOverrides,
    outcome: ?[]const u8,
) !void {
    const runtime = self.plugin_runtime orelse return;
    const payload = try buildPluginHookPayload(self.allocator, hook_name, definition.id, command_ctx.request.request_id, if (overrides) |item| item.session_id else null, outcome);
    defer self.allocator.free(payload);
    _ = try runtime.triggerHook(hook_name, payload);
}

fn buildPluginHookPayload(
    allocator: std.mem.Allocator,
    hook_name: []const u8,
    tool_id: []const u8,
    request_id: []const u8,
    session_id: ?[]const u8,
    outcome: ?[]const u8,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"hook\":");
    try out.append(allocator, '"');
    try writeJsonStringFragment(&out, allocator, hook_name);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, ",\"tool\":");
    try out.append(allocator, '"');
    try writeJsonStringFragment(&out, allocator, tool_id);
    try out.append(allocator, '"');
    try out.appendSlice(allocator, ",\"request_id\":");
    try out.append(allocator, '"');
    try writeJsonStringFragment(&out, allocator, request_id);
    try out.append(allocator, '"');
    if (session_id) |value| {
        try out.appendSlice(allocator, ",\"session_id\":");
        try out.append(allocator, '"');
        try writeJsonStringFragment(&out, allocator, value);
        try out.append(allocator, '"');
    }
    if (outcome) |value| {
        try out.appendSlice(allocator, ",\"outcome\":");
        try out.append(allocator, '"');
        try writeJsonStringFragment(&out, allocator, value);
        try out.append(allocator, '"');
    }
    try out.append(allocator, '}');
    return allocator.dupe(u8, out.items);
}

fn singlePattern(allocator: std.mem.Allocator, pattern: []u8) ![][]const u8 {
    const patterns = try allocator.alloc([]const u8, 1);
    patterns[0] = pattern;
    return patterns;
}

fn pathPattern(allocator: std.mem.Allocator, working_dir: []const u8, fields: []const framework.ValidationField) ![]u8 {
    if (fieldString(fields, "path")) |path_text| {
        return context_model.resolvePath(allocator, working_dir, path_text);
    }
    return allocator.dupe(u8, "*");
}

fn stringFieldOrDefault(allocator: std.mem.Allocator, fields: []const framework.ValidationField, key: []const u8, fallback: []const u8) ![]u8 {
    if (fieldString(fields, key)) |value| return allocator.dupe(u8, value);
    return allocator.dupe(u8, fallback);
}

fn fieldString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn buildPermissionMetadata(allocator: std.mem.Allocator, tool_id: []const u8, fields: []const framework.ValidationField) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"tool\":\"");
    try writeJsonStringFragment(&out, allocator, tool_id);
    try out.appendSlice(allocator, "\",\"params\":{");
    for (fields, 0..) |field, index| {
        if (index > 0) try out.append(allocator, ',');
        try out.append(allocator, '"');
        try writeJsonStringFragment(&out, allocator, field.key);
        try out.appendSlice(allocator, "\":");
                        try writeValidationValueJson(&out, allocator, field.value);
    }
    try out.appendSlice(allocator, "}}");
    return allocator.dupe(u8, out.items);
}

fn writeValidationValueJson(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: framework.ValidationValue) !void {
    switch (value) {
        .string => |text| {
            try out.append(allocator, '"');
            try writeJsonStringFragment(out, allocator, text);
            try out.append(allocator, '"');
        },
        .integer => |number| {
            const buf = try std.fmt.allocPrint(allocator, "{d}", .{number});
            defer allocator.free(buf);
            try out.appendSlice(allocator, buf);
        },
        .boolean => |flag| try out.appendSlice(allocator, if (flag) "true" else "false"),
        .float => |number| {
            const buf = try std.fmt.allocPrint(allocator, "{d}", .{number});
            defer allocator.free(buf);
            try out.appendSlice(allocator, buf);
        },
        .null => try out.appendSlice(allocator, "null"),
        .object => |fields| {
            try out.append(allocator, '{');
            for (fields, 0..) |field, index| {
                if (index > 0) try out.append(allocator, ',');
                try out.append(allocator, '"');
                try writeJsonStringFragment(out, allocator, field.key);
                try out.appendSlice(allocator, "\":");
                try writeValidationValueJson(out, allocator, field.value);
            }
            try out.append(allocator, '}');
        },
        .array => |items| {
            try out.append(allocator, '[');
            for (items, 0..) |item, index| {
                if (index > 0) try out.append(allocator, ',');
                try writeValidationValueJson(out, allocator, item);
            }
            try out.append(allocator, ']');
        },
    }
}

fn writeJsonStringFragment(out: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    for (value) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(allocator, "\\\""),
            '\\' => try out.appendSlice(allocator, "\\\\"),
            '\n' => try out.appendSlice(allocator, "\\n"),
            '\r' => try out.appendSlice(allocator, "\\r"),
            '\t' => try out.appendSlice(allocator, "\\t"),
            else => {
                if (ch < 32) {
                    const escaped = try std.fmt.allocPrint(allocator, "\\u00{x:0>2}", .{ch});
                    defer allocator.free(escaped);
                    try out.appendSlice(allocator, escaped);
                } else {
                    try out.append(allocator, ch);
                }
            },
        }
    }
}

test "tool runtime registers builtin tools in registry" {
    var registry = registry_model.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var memory_sink = framework.MemorySink.init(std.testing.allocator, 8);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();
    var runner = framework.TaskRunner.init(std.testing.allocator);
    defer runner.deinit();

    var runtime = try ToolRuntime.init(std.testing.allocator, &registry, &logger, &runner, event_bus.asEventBus(), ".");
    defer runtime.deinit();

    try std.testing.expect(registry.get("read_file") != null);
    try std.testing.expect(registry.get("execute_shell") != null);
}
