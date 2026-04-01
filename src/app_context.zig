const std = @import("std");
const framework = @import("framework");
const agent = @import("agent/root.zig");
const config = @import("config/root.zig");
const formatter = @import("formatter/root.zig");
const lsp = @import("lsp/root.zig");
const mcp = @import("mcp/root.zig");
const loop = @import("loop/root.zig");
const orchestration = @import("orchestration/root.zig");
const permission = @import("permission/root.zig");
const pty = @import("pty/root.zig");
const prompt = @import("prompt/root.zig");
const provider = @import("provider/root.zig");
const project = @import("project/root.zig");
const plugin = @import("plugin/root.zig");
const question = @import("question/root.zig");
const session = @import("session/root.zig");
const skill = @import("skill/root.zig");
const framework_integration = @import("framework_integration/root.zig");
const tools = @import("tools/root.zig");

pub const AppContext = struct {
    allocator: std.mem.Allocator,
    framework_app: framework.AppContext,
    config_runtime: *config.ConfigRuntime,
    agent_registry: *agent.AgentRegistry,
    provider_registry: *provider.ProviderRegistry,
    provider_auth_runtime: *provider.ProviderAuthRuntime,
    project_runtime: *project.ProjectRuntime,
    plugin_runtime: *plugin.PluginRuntime,
    skill_runtime: *skill.SkillRuntime,
    framework_tooling: *framework_integration.ToolingBridge,
    tool_registry: *tools.ToolRegistry,
    tool_runtime: *tools.ToolRuntime,
    formatter_runtime: *formatter.FormatterRuntime,
    lsp_runtime: *lsp.LspRuntime,
    mcp_runtime: *mcp.McpRuntime,
    pty_runtime: *pty.PtyRuntime,
    permission_runtime: *permission.PermissionRuntime,
    question_runtime: *question.QuestionRuntime,
    session_runtime: *session.SessionRuntime,
    loop_store: *loop.FileLoopStateStore,
    loop_service: *loop.LoopService,
    orchestration_service: *orchestration.OrchestrationService,
    status_index: *session.SessionStatusIndex,
    session_store: *session.FileSessionStore,
    snapshot_store: *session.FileSnapshotStore,
    snapshot_service: *session.SnapshotService,
    history_service: session.HistoryService,
    compaction_policy: *session.MessageCountCompactionPolicy,

    // Future agent-specific dependencies are composed here instead of
    // reimplementing the framework runtime surface.
    llm_client: ?*anyopaque = null,
    agent_runner: ?*anyopaque = null,
    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, bootstrap: framework.AppBootstrapConfig) !Self {
        return initWithConfigOptions(allocator, bootstrap, .{});
    }

    pub fn initWithConfigOptions(
        allocator: std.mem.Allocator,
        bootstrap: framework.AppBootstrapConfig,
        options: config.RuntimeOptions,
    ) !Self {
        var framework_app = try framework.AppContext.init(allocator, bootstrap);
        errdefer framework_app.deinit();
        const bootstrap_logger = framework_app.logger.child("app").child("bootstrap");

        const config_runtime = try allocator.create(config.ConfigRuntime);
        errdefer allocator.destroy(config_runtime);
        config_runtime.* = try config.ConfigRuntime.init(allocator, .{
            .store = framework_app.config_store.asConfigStore(),
            .change_log = framework_app.config_change_log.asChangeLog(),
            .side_effect = framework_app.config_side_effects.asSideEffect(),
            .logger = framework_app.logger,
            .observer = framework_app.observer(),
            .event_bus = framework_app.eventBus(),
        }, options);
        errdefer config_runtime.deinit();
        try config_runtime.load();
        bootstrap_logger.info("config runtime initialized", &.{
            framework.LogField.boolean("has_project_config", config_runtime.resolved_paths.project_config_path != null),
            framework.LogField.boolean("has_global_config", config_runtime.resolved_paths.global_config_path != null),
            framework.LogField.boolean("has_custom_config", config_runtime.resolved_paths.custom_config_path != null),
        });

        var effective_config = try config_runtime.effective(allocator);
        defer effective_config.deinit(allocator);

        const agent_registry = try allocator.create(agent.AgentRegistry);
        errdefer allocator.destroy(agent_registry);
        agent_registry.* = agent.AgentRegistry.init(allocator);
        errdefer agent_registry.deinit();
        try agent.registerBuiltins(agent_registry);
        bootstrap_logger.info("agent registry initialized", &.{
            framework.LogField.int("profile_count", @intCast(agent_registry.list().len)),
            framework.LogField.string("default_agent", effective_config.default_agent),
        });

        const session_store = try allocator.create(session.FileSessionStore);
        errdefer allocator.destroy(session_store);
        session_store.* = try session.FileSessionStore.init(allocator, effective_config.session.store_path, framework_app.eventBus(), framework_app.logger);
        errdefer session_store.deinit();
        bootstrap_logger.info("session store initialized", &.{
            framework.LogField.string("store_path", session_store.root_path),
        });

        const snapshot_store_path = try std.fs.path.join(allocator, &.{ session_store.root_path, "_snapshots" });
        defer allocator.free(snapshot_store_path);
        const snapshot_store = try allocator.create(session.FileSnapshotStore);
        errdefer allocator.destroy(snapshot_store);
        snapshot_store.* = try session.FileSnapshotStore.init(allocator, snapshot_store_path);
        errdefer snapshot_store.deinit();

        const snapshot_service = try allocator.create(session.SnapshotService);
        errdefer allocator.destroy(snapshot_service);
        snapshot_service.* = session.SnapshotService.init(allocator, framework_app.logger, snapshot_store);

        const provider_auth_path = try std.fs.path.join(allocator, &.{ session_store.root_path, "_provider_auth.json" });
        defer allocator.free(provider_auth_path);
        const provider_auth_runtime = try provider.ProviderAuthRuntime.init(allocator, framework_app.logger, provider_auth_path);
        errdefer {
            provider_auth_runtime.deinit();
            allocator.destroy(provider_auth_runtime);
        }
        if (effective_config.anthropic.api_key) |api_key| {
            try provider_auth_runtime.seedApiKeyIfMissing("anthropic", api_key);
        }
        if (effective_config.openai.api_key) |api_key| {
            try provider_auth_runtime.seedApiKeyIfMissing("openai", api_key);
        }
        if (try provider.loadOpenAIApiKey(allocator)) |api_key| {
            defer allocator.free(api_key);
            try provider_auth_runtime.seedApiKeyIfMissing("openai", api_key);
        }
        bootstrap_logger.info("provider auth runtime initialized", &.{
            framework.LogField.string("store_path", provider_auth_runtime.store_path),
        });

        const provider_registry = try allocator.create(provider.ProviderRegistry);
        errdefer allocator.destroy(provider_registry);
        provider_registry.* = provider.ProviderRegistry.init(allocator, framework_app.logger, framework_app.eventBus());
        errdefer provider_registry.deinit();
        provider_registry.setAuthRuntime(provider_auth_runtime);
        try provider_registry.setProviderRuntimeConfig("anthropic", .{
            .base_url = effective_config.anthropic.base_url,
            .timeout_ms = effective_config.anthropic.timeout_ms,
        });
        try provider_registry.setProviderRuntimeConfig("openai", .{
            .base_url = effective_config.openai.base_url,
            .timeout_ms = effective_config.openai.timeout_ms,
        });
        try provider_registry.registerAnthropic();
        try provider_registry.registerOpenAI();
        bootstrap_logger.info("provider registry initialized", &.{
            framework.LogField.boolean("has_default_model", effective_config.model.default_model != null),
            framework.LogField.string("provider_id", "anthropic"),
        });

        const workspace_root_path = try std.fs.path.join(allocator, &.{ session_store.root_path, "_workspaces" });
        defer allocator.free(workspace_root_path);
        const project_runtime = try project.ProjectRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .current_dir = config_runtime.resolved_paths.current_dir,
            .workspace_root = workspace_root_path,
        });
        errdefer {
            project_runtime.deinit();
            allocator.destroy(project_runtime);
        }
        bootstrap_logger.info("project runtime initialized", &.{
            framework.LogField.string("current_dir", config_runtime.resolved_paths.current_dir),
            framework.LogField.string("workspace_root", workspace_root_path),
        });

        const plugin_runtime = try plugin.PluginRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .current_dir = config_runtime.resolved_paths.current_dir,
        });
        errdefer {
            plugin_runtime.deinit();
            allocator.destroy(plugin_runtime);
        }
        bootstrap_logger.info("plugin runtime initialized", &.{});

        const skill_runtime = try skill.SkillRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .current_dir = config_runtime.resolved_paths.current_dir,
        });
        errdefer {
            skill_runtime.deinit();
            allocator.destroy(skill_runtime);
        }
        bootstrap_logger.info("skill runtime initialized", &.{});

        const loop_store_path = try std.fs.path.join(allocator, &.{ session_store.root_path, "_loops" });
        defer allocator.free(loop_store_path);
        const loop_store = try allocator.create(loop.FileLoopStateStore);
        errdefer allocator.destroy(loop_store);
        loop_store.* = try loop.FileLoopStateStore.init(allocator, loop_store_path);
        errdefer loop_store.deinit();

        const status_index = try allocator.create(session.SessionStatusIndex);
        errdefer allocator.destroy(status_index);
        status_index.* = session.SessionStatusIndex.init(allocator);
        errdefer status_index.deinit();

        const tool_registry = try allocator.create(tools.ToolRegistry);
        errdefer allocator.destroy(tool_registry);
        tool_registry.* = tools.ToolRegistry.init(allocator);
        errdefer tool_registry.deinit();

        const formatter_runtime = try formatter.FormatterRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .workspace_dir = config_runtime.resolved_paths.current_dir,
            .formatter = effective_config.formatter,
        });
        errdefer {
            formatter_runtime.deinit();
            allocator.destroy(formatter_runtime);
        }

        const lsp_runtime = try lsp.LspRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .event_bus = framework_app.eventBus(),
            .workspace_dir = config_runtime.resolved_paths.current_dir,
            .lsp = effective_config.lsp,
        });
        errdefer lsp_runtime.deinit();

        const mcp_runtime = try mcp.McpRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .event_bus = framework_app.eventBus(),
            .workspace_dir = config_runtime.resolved_paths.current_dir,
            .mcp = effective_config.mcp,
        });
        errdefer {
            mcp_runtime.deinit();
            allocator.destroy(mcp_runtime);
        }

        const pty_runtime = try pty.PtyRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .event_bus = framework_app.eventBus(),
            .workspace_dir = config_runtime.resolved_paths.current_dir,
        });
        errdefer {
            pty_runtime.deinit();
            allocator.destroy(pty_runtime);
        }

        const permission_runtime = try permission.PermissionRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .event_bus = framework_app.eventBus(),
            .rules = effective_config.permission.rules,
        });
        errdefer permission_runtime.deinit();

        const question_runtime = try question.QuestionRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .event_bus = framework_app.eventBus(),
        });
        errdefer question_runtime.deinit();

        const tool_runtime = try allocator.create(tools.ToolRuntime);
        errdefer allocator.destroy(tool_runtime);
        tool_runtime.* = try tools.ToolRuntime.init(
            allocator,
            tool_registry,
            framework_app.logger,
            framework_app.task_runner,
            framework_app.eventBus(),
            config_runtime.resolved_paths.current_dir,
        );
        errdefer tool_runtime.deinit();
        tool_runtime.formatter_runtime = formatter_runtime;
        tool_runtime.lsp_runtime = lsp_runtime;
        tool_runtime.mcp_runtime = mcp_runtime;
        tool_runtime.snapshot_service = snapshot_service;
        tool_runtime.plugin_runtime = plugin_runtime;
        tool_runtime.skill_runtime = skill_runtime;
        tool_runtime.permission_runtime = permission_runtime;
        tool_runtime.question_runtime = question_runtime;
        const framework_tooling = try framework_integration.ToolingBridge.init(allocator, &framework_app);
        errdefer framework_tooling.deinit();
        tool_runtime.framework_tooling = framework_tooling;
        try mcp.tool_adapter.registerConnectedTools(allocator, mcp_runtime, tool_registry);
        try tool_runtime.registerCommands(effective_config, &framework_app);
        bootstrap_logger.info("tool registry initialized", &.{
            framework.LogField.int("tool_count", @intCast(tool_registry.count())),
            framework.LogField.int("command_count", @intCast(framework_app.command_registry.count())),
        });
        bootstrap_logger.info("formatter runtime initialized", &.{
            framework.LogField.int("formatter_count", @intCast(effective_config.formatter.definitions.len)),
        });
        bootstrap_logger.info("lsp runtime initialized", &.{
            framework.LogField.boolean("lsp_enabled", effective_config.lsp.enabled),
            framework.LogField.int("lsp_server_count", @intCast(effective_config.lsp.servers.len)),
        });
        bootstrap_logger.info("mcp runtime initialized", &.{
            framework.LogField.int("mcp_server_count", @intCast(effective_config.mcp.servers.len)),
        });
        bootstrap_logger.info("pty runtime initialized", &.{});
        bootstrap_logger.info("permission runtime initialized", &.{
            framework.LogField.int("rule_count", @intCast(effective_config.permission.rules.len)),
        });
        bootstrap_logger.info("question runtime initialized", &.{});

        const session_runtime = try allocator.create(session.SessionRuntime);
        errdefer allocator.destroy(session_runtime);
        session_runtime.* = session.SessionRuntime.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .task_runner = framework_app.task_runner,
            .event_bus = framework_app.eventBus(),
            .status_index = status_index,
            .config_runtime = config_runtime,
            .agent_registry = agent_registry,
            .provider_registry = provider_registry,
            .tool_runtime = tool_runtime,
            .session_store = session_store.asSessionStore(),
            .history_service = session.HistoryService.init(session_store.asSessionStore()),
            .compaction_policy = undefined,
        });
        try session.registerRunAgentCommand(session_runtime, &framework_app);
        bootstrap_logger.info("session runtime initialized", &.{
            framework.LogField.int("command_count", @intCast(framework_app.command_registry.count())),
        });

        const loop_service = try allocator.create(loop.LoopService);
        errdefer allocator.destroy(loop_service);
        loop_service.* = loop.LoopService.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .event_bus = framework_app.eventBus(),
            .agent_registry = agent_registry,
            .session_runtime = session_runtime,
            .session_store = session_store.asSessionStore(),
            .history_service = session.HistoryService.init(session_store.asSessionStore()),
            .state_store = loop_store.asLoopStateStore(),
        });
        errdefer loop_service.deinit();
        try loop_service.start();
        bootstrap_logger.info("loop service initialized", &.{
            framework.LogField.string("loop_store_path", loop_store.root_path),
        });

        const orchestration_service = try allocator.create(orchestration.OrchestrationService);
        errdefer allocator.destroy(orchestration_service);
        orchestration_service.* = orchestration.OrchestrationService.init(.{
            .allocator = allocator,
            .logger = framework_app.logger,
            .task_runner = framework_app.task_runner,
            .session_runtime = session_runtime,
            .session_store = session_store.asSessionStore(),
        });
        try orchestration.registerDelegateBatchCommand(orchestration_service, &framework_app);
        bootstrap_logger.info("orchestration service initialized", &.{
            framework.LogField.int("command_count", @intCast(framework_app.command_registry.count())),
        });

        const compaction_policy = try allocator.create(session.MessageCountCompactionPolicy);
        errdefer allocator.destroy(compaction_policy);
        compaction_policy.* = .{
            .threshold = 12,
            .preserve_recent_messages = 4,
        };
        session_runtime.deps.compaction_policy = compaction_policy.asPolicy();
        bootstrap_logger.info("runtime bootstrap complete", &.{
            framework.LogField.string("default_agent", effective_config.default_agent),
            framework.LogField.string("session_store_path", session_store.root_path),
        });

        return .{
            .allocator = allocator,
            .framework_app = framework_app,
            .config_runtime = config_runtime,
            .agent_registry = agent_registry,
            .provider_registry = provider_registry,
            .provider_auth_runtime = provider_auth_runtime,
            .project_runtime = project_runtime,
            .plugin_runtime = plugin_runtime,
            .skill_runtime = skill_runtime,
            .framework_tooling = framework_tooling,
            .tool_registry = tool_registry,
            .tool_runtime = tool_runtime,
            .formatter_runtime = formatter_runtime,
            .lsp_runtime = lsp_runtime,
            .mcp_runtime = mcp_runtime,
            .pty_runtime = pty_runtime,
            .permission_runtime = permission_runtime,
            .question_runtime = question_runtime,
            .session_runtime = session_runtime,
            .loop_store = loop_store,
            .loop_service = loop_service,
            .orchestration_service = orchestration_service,
            .status_index = status_index,
            .session_store = session_store,
            .snapshot_store = snapshot_store,
            .snapshot_service = snapshot_service,
            .history_service = session.HistoryService.init(session_store.asSessionStore()),
            .compaction_policy = compaction_policy,
        };
    }

    pub fn deinit(self: *Self) void {
        self.loop_service.deinit();
        self.allocator.destroy(self.loop_service);
        self.loop_store.deinit();
        self.allocator.destroy(self.loop_store);
        self.lsp_runtime.deinit();
        self.mcp_runtime.deinit();
        self.allocator.destroy(self.mcp_runtime);
        self.pty_runtime.deinit();
        self.allocator.destroy(self.pty_runtime);
        self.permission_runtime.deinit();
        self.allocator.destroy(self.permission_runtime);
        self.question_runtime.deinit();
        self.allocator.destroy(self.question_runtime);
        self.session_store.deinit();
        self.allocator.destroy(self.session_store);
        self.allocator.destroy(self.snapshot_service);
        self.snapshot_store.deinit();
        self.allocator.destroy(self.snapshot_store);
        self.allocator.destroy(self.compaction_policy);
        self.framework_tooling.deinit();
        self.tool_runtime.deinit();
        self.allocator.destroy(self.tool_runtime);
        self.formatter_runtime.deinit();
        self.allocator.destroy(self.formatter_runtime);
        self.allocator.destroy(self.lsp_runtime);
        self.allocator.destroy(self.session_runtime);
        self.allocator.destroy(self.orchestration_service);
        self.status_index.deinit();
        self.allocator.destroy(self.status_index);
        self.tool_registry.deinit();
        self.allocator.destroy(self.tool_registry);
        self.agent_registry.deinit();
        self.allocator.destroy(self.agent_registry);
        self.config_runtime.deinit();
        self.allocator.destroy(self.config_runtime);
        self.provider_registry.deinit();
        self.allocator.destroy(self.provider_registry);
        self.provider_auth_runtime.deinit();
        self.allocator.destroy(self.provider_auth_runtime);
        self.project_runtime.deinit();
        self.allocator.destroy(self.project_runtime);
        self.plugin_runtime.deinit();
        self.allocator.destroy(self.plugin_runtime);
        self.skill_runtime.deinit();
        self.allocator.destroy(self.skill_runtime);
        self.framework_app.deinit();
    }

    pub fn observer(self: *Self) framework.Observer {
        return self.framework_app.observer();
    }

    pub fn eventBus(self: *Self) framework.EventBus {
        return self.framework_app.eventBus();
    }

    pub fn effectiveConfig(self: *Self, allocator: std.mem.Allocator) !config.EffectiveConfig {
        return self.config_runtime.effective(allocator);
    }

    pub fn resolveAgentProfile(self: *Self, requested_id: ?[]const u8) !?*const agent.AgentProfile {
        const log = self.framework_app.logger.child("agent").child("resolve");
        if (requested_id) |agent_id| {
            const resolved = self.agent_registry.get(agent_id);
            if (resolved) |profile| {
                log.info("agent profile resolved", &.{
                    framework.LogField.string("requested_agent", agent_id),
                    framework.LogField.string("selected_agent", profile.id),
                    framework.LogField.boolean("fallback", false),
                });
            } else {
                log.warn("requested agent profile not found", &.{
                    framework.LogField.string("requested_agent", agent_id),
                });
            }
            return resolved;
        }

        var effective = try self.effectiveConfig(self.allocator);
        defer effective.deinit(self.allocator);

        if (self.agent_registry.get(effective.default_agent)) |profile| {
            log.info("agent profile resolved", &.{
                framework.LogField.string("requested_agent", effective.default_agent),
                framework.LogField.string("selected_agent", profile.id),
                framework.LogField.boolean("fallback", false),
            });
            return profile;
        }

        const fallback = self.agent_registry.defaultPrimary();
        if (fallback) |profile| {
            log.warn("default agent missing, falling back to primary profile", &.{
                framework.LogField.string("requested_agent", effective.default_agent),
                framework.LogField.string("selected_agent", profile.id),
                framework.LogField.boolean("fallback", true),
            });
        }
        return fallback;
    }

    pub fn preparePromptInput(
        self: *Self,
        allocator: std.mem.Allocator,
        requested_id: ?[]const u8,
        user_input: ?[]const u8,
    ) !session.PreparedPromptInput {
        const profile = (try self.resolveAgentProfile(requested_id)) orelse return error.AgentProfileNotFound;
        var prepared = try session.preparePromptForProfile(allocator, profile, user_input);
        session.prompt_input.logPreparedPrompt(self.framework_app.logger, profile, &prepared);
        return prepared;
    }

    pub fn sessionRuntime(self: *Self) *session.SessionRuntime {
        return self.session_runtime;
    }

    pub fn lspRuntime(self: *Self) *lsp.LspRuntime {
        return self.lsp_runtime;
    }

    pub fn formatterRuntime(self: *Self) *formatter.FormatterRuntime {
        return self.formatter_runtime;
    }

    pub fn providerAuthRuntime(self: *Self) *provider.ProviderAuthRuntime {
        return self.provider_auth_runtime;
    }

    pub fn projectRuntime(self: *Self) *project.ProjectRuntime {
        return self.project_runtime;
    }

    pub fn pluginRuntime(self: *Self) *plugin.PluginRuntime {
        return self.plugin_runtime;
    }

    pub fn skillRuntime(self: *Self) *skill.SkillRuntime {
        return self.skill_runtime;
    }

    pub fn mcpRuntime(self: *Self) *mcp.McpRuntime {
        return self.mcp_runtime;
    }

    pub fn ptyRuntime(self: *Self) *pty.PtyRuntime {
        return self.pty_runtime;
    }

    pub fn permissionRuntime(self: *Self) *permission.PermissionRuntime {
        return self.permission_runtime;
    }

    pub fn questionRuntime(self: *Self) *question.QuestionRuntime {
        return self.question_runtime;
    }

    pub fn loopService(self: *Self) *loop.LoopService {
        return self.loop_service;
    }

    pub fn orchestrationService(self: *Self) *orchestration.OrchestrationService {
        return self.orchestration_service;
    }

    pub fn sessionStore(self: *Self) session.SessionStore {
        return self.session_store.asSessionStore();
    }

    pub fn snapshotService(self: *Self) *session.SnapshotService {
        return self.snapshot_service;
    }

    pub fn sessionStatusIndex(self: *Self) *session.SessionStatusIndex {
        return self.status_index;
    }

    pub fn compactionPolicy(self: *Self) session.CompactionPolicy {
        return self.compaction_policy.asPolicy();
    }

    pub fn makeDispatcher(self: *Self) framework.CommandDispatcher {
        return self.framework_app.makeDispatcher();
    }

    pub fn registerCommand(self: *Self, definition: framework.CommandDefinition) !void {
        try self.framework_app.registerCommand(definition);
    }
};

test "zig-opencode app context composes framework app context" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const project_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "workspace" });
    defer std.testing.allocator.free(project_dir);
    try std.fs.cwd().makePath(project_dir);

    const config_path = try std.fs.path.join(std.testing.allocator, &.{ project_dir, "opencode.json" });
    defer std.testing.allocator.free(config_path);
    const global_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "missing-global.json" });
    defer std.testing.allocator.free(global_path);

    var file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll(
        \\{
        \\  "agent": { "default": "plan" },
        \\  "session": { "store": { "path": "my-sessions" } }
        \\}
    );

    var app_context = try AppContext.initWithConfigOptions(std.testing.allocator, .{
        .console_log_enabled = false,
    }, .{
        .current_dir = project_dir,
        .global_config_path = global_path,
    });
    defer app_context.deinit();

    try std.testing.expect(app_context.llm_client == null);
    try std.testing.expect(app_context.agent_runner == null);
    try std.testing.expect(app_context.agent_registry.get("build") != null);
    try std.testing.expect(app_context.agent_registry.get("plan") != null);
    try std.testing.expect(app_context.agent_registry.get("explore") != null);
    try std.testing.expect(app_context.agent_registry.get("oracle") != null);
    try std.testing.expect(app_context.provider_registry.getProvider("anthropic") != null);
    try std.testing.expect(app_context.provider_registry.getProvider("openai") != null);
    try std.testing.expect(app_context.tool_registry.get("read_file") != null);
    try std.testing.expect(app_context.tool_registry.get("execute_shell") != null);
    try std.testing.expect(app_context.tool_registry.get("lsp") != null);
    try std.testing.expect(app_context.tool_registry.get("mcp_resource") != null);
    try std.testing.expect(app_context.tool_registry.get("question") != null);
    try std.testing.expect(app_context.tool_registry.get("skill") != null);
    {
        const formatters = try app_context.formatterRuntime().status(std.testing.allocator);
        defer {
            for (formatters) |*item| item.deinit(std.testing.allocator);
            std.testing.allocator.free(formatters);
        }
        try std.testing.expectEqual(@as(usize, 0), formatters.len);
    }
    {
        const ptys = try app_context.ptyRuntime().list(std.testing.allocator);
        defer pty.freeInfos(std.testing.allocator, ptys);
        try std.testing.expectEqual(@as(usize, 0), ptys.len);
    }
    {
        var project_info = try app_context.projectRuntime().currentProject(std.testing.allocator);
        defer project_info.deinit(std.testing.allocator);
        try std.testing.expect(project_info.name.len > 0);
    }
    {
        const plugins = try app_context.pluginRuntime().list(std.testing.allocator);
        defer {
            for (plugins) |*item| item.deinit(std.testing.allocator);
            std.testing.allocator.free(plugins);
        }
        try std.testing.expectEqual(@as(usize, 0), plugins.len);
    }
    {
        const skills = try app_context.skillRuntime().list(std.testing.allocator);
        defer {
            for (skills) |*item| item.deinit(std.testing.allocator);
            std.testing.allocator.free(skills);
        }
        try std.testing.expect(skills.len >= 0);
    }
    try std.testing.expect(app_context.framework_app.command_registry.count() >= 7);
    try std.testing.expectEqual(@as(usize, 0), app_context.framework_app.event_bus.count());
    try std.testing.expect(std.mem.endsWith(u8, app_context.session_store.root_path, "my-sessions"));
    try std.testing.expect(app_context.framework_app.memory_sink.count() > 0);

    var effective_config = try app_context.effectiveConfig(std.testing.allocator);
    defer effective_config.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("plan", effective_config.default_agent);

    const resolved = try app_context.resolveAgentProfile(null);
    try std.testing.expect(resolved != null);
    try std.testing.expectEqualStrings("plan", resolved.?.id);

    var prompt_input = try app_context.preparePromptInput(std.testing.allocator, null, "think first");
    defer prompt_input.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, prompt_input.system_prompt, "Planning reminder") != null);
    try std.testing.expect(app_context.framework_app.command_registry.findByMethod("agent.run") != null);
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "runtime bootstrap complete"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "agent profile resolved"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "prepared prompt materialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "loop service initialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "formatter runtime initialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "lsp runtime initialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "mcp runtime initialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "pty runtime initialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "project runtime initialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "permission runtime initialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "question runtime initialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "plugin runtime initialized"));
    try std.testing.expect(findLogMessage(app_context.framework_app.memory_sink, "skill runtime initialized"));
}

test "builtin tool commands dispatch through command layer and validate input" {
    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();
    fixture.app_context.tool_runtime.permission_runtime = null;

    var dispatcher = fixture.app_context.makeDispatcher();

    {
        const invalid_envelope = try dispatcher.dispatch(.{
            .request_id = "req_tool_invalid",
            .method = "read_file",
            .params = &.{},
            .source = .@"test",
        }, false);

        try std.testing.expect(!invalid_envelope.ok);
        try std.testing.expectEqualStrings(framework.core.error_model.code.VALIDATION_FAILED, invalid_envelope.app_error.?.code);
    }

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.project_dir, "note.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("hello tool");
    }

    const params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "note.txt" } },
    };
    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_tool_read",
        .method = "read_file",
        .params = params[0..],
        .source = .@"test",
    }, false);
    defer std.testing.allocator.free(envelope.result.?.success_json);

    try std.testing.expect(envelope.ok);
    try std.testing.expect(std.mem.indexOf(u8, envelope.result.?.success_json, "hello tool") != null);
}

test "skill command lists and loads discovered skills through command layer" {
    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();
    fixture.app_context.tool_runtime.permission_runtime = null;

    const skill_dir = try std.fs.path.join(std.testing.allocator, &.{ fixture.project_dir, "skills", "demo-skill" });
    defer std.testing.allocator.free(skill_dir);
    try std.fs.cwd().makePath(skill_dir);

    const skill_path = try std.fs.path.join(std.testing.allocator, &.{ skill_dir, "SKILL.md" });
    defer std.testing.allocator.free(skill_path);
    {
        var file = try std.fs.cwd().createFile(skill_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(
            \\# Demo Skill
            \\A sample skill.
        );
    }

    try fixture.app_context.skillRuntime().refresh();
    var dispatcher = fixture.app_context.makeDispatcher();

    const list_params = [_]framework.ValidationField{
        .{ .key = "operation", .value = .{ .string = "list" } },
    };
    const list_envelope = try dispatcher.dispatch(.{
        .request_id = "req_skill_list",
        .method = "skill",
        .params = list_params[0..],
        .source = .@"test",
    }, false);
    defer std.testing.allocator.free(list_envelope.result.?.success_json);
    try std.testing.expect(list_envelope.ok);
    try std.testing.expect(std.mem.indexOf(u8, list_envelope.result.?.success_json, "demo-skill: A sample skill.") != null);

    const load_params = [_]framework.ValidationField{
        .{ .key = "operation", .value = .{ .string = "load" } },
        .{ .key = "name", .value = .{ .string = "demo-skill" } },
    };
    const load_envelope = try dispatcher.dispatch(.{
        .request_id = "req_skill_load",
        .method = "skill",
        .params = load_params[0..],
        .source = .@"test",
    }, false);
    defer std.testing.allocator.free(load_envelope.result.?.success_json);
    try std.testing.expect(load_envelope.ok);
    try std.testing.expect(std.mem.indexOf(u8, load_envelope.result.?.success_json, "Demo Skill") != null);
    try std.testing.expect(std.mem.indexOf(u8, load_envelope.result.?.success_json, "A sample skill.") != null);
}

test "execute_shell command runs as task and returns result_json through task runner" {
    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "permission": { "rules": [
        \\    { "permission": "edit", "pattern": "*", "action": "allow" }
        \\  ] },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    errdefer fixture.deinit();
    fixture.app_context.tool_runtime.permission_runtime = null;

    var dispatcher = fixture.app_context.makeDispatcher();
    const params = [_]framework.ValidationField{
        .{ .key = "command", .value = .{ .string = "Write-Output 'tool-ok'" } },
    };

    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_shell_01",
        .method = "execute_shell",
        .params = params[0..],
        .source = .@"test",
    }, false);

    try std.testing.expect(envelope.ok);
    try std.testing.expect(envelope.result.? == .task_accepted);

    var summary = try fixture.app_context.framework_app.task_runner.waitForCompletion(std.testing.allocator, envelope.result.?.task_accepted.task_id, 5000);
    defer summary.deinit(std.testing.allocator);

    try std.testing.expectEqual(framework.TaskState.succeeded, summary.state);
    try std.testing.expect(summary.result_json != null);
    try std.testing.expect(std.mem.indexOf(u8, summary.result_json.?, "tool-ok") != null);
    try std.testing.expect(findLogMessage(fixture.app_context.framework_app.memory_sink, "tool executed"));

    fixture.deinit();
}

test "write_file command runs configured formatter after mutation" {
    const FormatterMock = struct {
        var saw_path = false;

        fn run(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, argv: [][]const u8) anyerror!formatter.runtime.RunOutput {
            try std.testing.expectEqualStrings("mockfmt", argv[0]);
            saw_path = std.mem.endsWith(u8, argv[1], "formatted.txt");
            return .{
                .stdout = try allocator.dupe(u8, "formatted"),
                .stderr = try allocator.alloc(u8, 0),
                .exit_code = 0,
            };
        }
    };

    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "formatter": { "definitions": [
        \\    { "name": "mockfmt", "extensions": [".txt"], "command": ["mockfmt"] }
        \\  ] },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();
    fixture.app_context.tool_runtime.permission_runtime = null;
    fixture.app_context.formatter_runtime.executor = .{ .ptr = undefined, .run_fn = FormatterMock.run };

    var dispatcher = fixture.app_context.makeDispatcher();
    const params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "formatted.txt" } },
        .{ .key = "content", .value = .{ .string = "hello" } },
    };

    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_write_format_01",
        .method = "write_file",
        .params = params[0..],
        .source = .@"test",
    }, false);
    defer std.testing.allocator.free(envelope.result.?.success_json);

    try std.testing.expect(envelope.ok);
    try std.testing.expect(FormatterMock.saw_path);
    try std.testing.expect(std.mem.indexOf(u8, envelope.result.?.success_json, "Formatted with mockfmt") != null);
}

test "edit_file command delegates to hashline backend when available" {
    const FakeBackend = struct {
        fn edit(_: *anyopaque, ctx: *const tools.ToolExecutionContext, _: []const framework.ValidationField) anyerror!tools.ToolResult {
            return .{
                .title = try ctx.allocator.dupe(u8, "edit_file"),
                .output_text = try ctx.allocator.dupe(u8, "delegated"),
                .metadata_json = try ctx.allocator.dupe(u8, "{\"delegated\":true}"),
            };
        }
    };

    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "permission": { "rules": [
        \\    { "permission": "edit", "pattern": "*", "action": "allow" }
        \\  ] },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();
    fixture.app_context.tool_runtime.permission_runtime = null;

    fixture.app_context.tool_runtime.hashline_backend = .{
        .ptr = undefined,
        .edit = FakeBackend.edit,
    };

    var dispatcher = fixture.app_context.makeDispatcher();
    const empty_edits = [_]framework.ValidationValue{};
    const params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "note.txt" } },
        .{ .key = "edits", .value = .{ .array = empty_edits[0..] } },
    };

    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_edit_01",
        .method = "edit_file",
        .params = params[0..],
        .source = .@"test",
    }, false);
    defer std.testing.allocator.free(envelope.result.?.success_json);

    try std.testing.expect(envelope.ok);
    try std.testing.expect(std.mem.indexOf(u8, envelope.result.?.success_json, "\"delegated\":true") != null);
}

test "edit_file command runs configured formatter after delegated edit" {
    const FakeBackend = struct {
        fn edit(_: *anyopaque, ctx: *const tools.ToolExecutionContext, _: []const framework.ValidationField) anyerror!tools.ToolResult {
            const resolved = try tools.context.resolvePath(ctx.allocator, ctx.working_dir, "note.txt");
            defer ctx.allocator.free(resolved);
            var file = try std.fs.cwd().createFile(resolved, .{ .truncate = true });
            defer file.close();
            try file.writeAll("edited");
            return .{
                .title = try ctx.allocator.dupe(u8, "edit_file"),
                .output_text = try ctx.allocator.dupe(u8, "delegated"),
                .metadata_json = try ctx.allocator.dupe(u8, "{\"delegated\":true}"),
            };
        }
    };

    const FormatterMock = struct {
        var saw_path = false;

        fn run(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, argv: [][]const u8) anyerror!formatter.runtime.RunOutput {
            try std.testing.expectEqualStrings("mockfmt", argv[0]);
            saw_path = std.mem.endsWith(u8, argv[1], "note.txt");
            return .{
                .stdout = try allocator.dupe(u8, "formatted"),
                .stderr = try allocator.alloc(u8, 0),
                .exit_code = 0,
            };
        }
    };

    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "formatter": { "definitions": [
        \\    { "name": "mockfmt", "extensions": [".txt"], "command": ["mockfmt"] }
        \\  ] },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();
    fixture.app_context.tool_runtime.permission_runtime = null;
    fixture.app_context.tool_runtime.hashline_backend = .{
        .ptr = undefined,
        .edit = FakeBackend.edit,
    };
    fixture.app_context.formatter_runtime.executor = .{ .ptr = undefined, .run_fn = FormatterMock.run };

    var dispatcher = fixture.app_context.makeDispatcher();
    const empty_edits = [_]framework.ValidationValue{};
    const params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "note.txt" } },
        .{ .key = "edits", .value = .{ .array = empty_edits[0..] } },
    };

    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_edit_format_01",
        .method = "edit_file",
        .params = params[0..],
        .source = .@"test",
    }, false);
    defer std.testing.allocator.free(envelope.result.?.success_json);

    try std.testing.expect(envelope.ok);
    try std.testing.expect(FormatterMock.saw_path);
    try std.testing.expect(std.mem.indexOf(u8, envelope.result.?.success_json, "Formatted with mockfmt") != null);
}

test "hashline read to anchored edit succeeds through command surface" {
    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "permission": { "rules": [
        \\    { "permission": "edit", "pattern": "*", "action": "allow" }
        \\  ] },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();
    fixture.app_context.tool_runtime.permission_runtime = null;

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.project_dir, "sample.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("alpha\nbeta\n");
    }

    var dispatcher = fixture.app_context.makeDispatcher();
    const read_params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "sample.txt" } },
        .{ .key = "hashline", .value = .{ .boolean = true } },
    };

    const read_envelope = try dispatcher.dispatch(.{
        .request_id = "req_hash_read",
        .method = "read_file",
        .params = read_params[0..],
        .source = .@"test",
    }, false);
    defer std.testing.allocator.free(read_envelope.result.?.success_json);

    const read_output = try parseToolOutputText(std.testing.allocator, read_envelope.result.?.success_json);
    defer std.testing.allocator.free(read_output);
    const second_anchor = try extractHashlineAnchor(std.testing.allocator, read_output, 2);
    defer std.testing.allocator.free(second_anchor);

    const edit_object = [_]framework.ValidationField{
        .{ .key = "op", .value = .{ .string = "replace" } },
        .{ .key = "anchor", .value = .{ .string = second_anchor } },
        .{ .key = "content", .value = .{ .string = "gamma" } },
    };
    const edit_items = [_]framework.ValidationValue{
        .{ .object = edit_object[0..] },
    };
    const edit_params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "sample.txt" } },
        .{ .key = "edits", .value = .{ .array = edit_items[0..] } },
    };

    const edit_envelope = try dispatcher.dispatch(.{
        .request_id = "req_hash_edit",
        .method = "edit_file",
        .params = edit_params[0..],
        .source = .@"test",
    }, false);
    try std.testing.expect(edit_envelope.ok);
    defer std.testing.allocator.free(edit_envelope.result.?.success_json);

    const contents = try std.fs.cwd().readFileAlloc(std.testing.allocator, file_path, 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expectEqualStrings("alpha\ngamma\n", contents);
}

test "hashline stale edit returns mismatch payload with refreshed context" {
    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();
    fixture.app_context.tool_runtime.permission_runtime = null;

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.project_dir, "stale.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("beta\n");
    }

    var dispatcher = fixture.app_context.makeDispatcher();
    const read_params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "stale.txt" } },
        .{ .key = "hashline", .value = .{ .boolean = true } },
    };

    const read_envelope = try dispatcher.dispatch(.{
        .request_id = "req_hash_read_stale",
        .method = "read_file",
        .params = read_params[0..],
        .source = .@"test",
    }, false);
    defer std.testing.allocator.free(read_envelope.result.?.success_json);

    const read_output = try parseToolOutputText(std.testing.allocator, read_envelope.result.?.success_json);
    defer std.testing.allocator.free(read_output);
    const anchor_text = try extractHashlineAnchor(std.testing.allocator, read_output, 1);
    defer std.testing.allocator.free(anchor_text);

    {
        var file = try std.fs.cwd().createFile(file_path, .{ .truncate = true });
        defer file.close();
        try file.writeAll("delta\n");
    }

    const edit_object = [_]framework.ValidationField{
        .{ .key = "op", .value = .{ .string = "replace" } },
        .{ .key = "anchor", .value = .{ .string = anchor_text } },
        .{ .key = "content", .value = .{ .string = "gamma" } },
    };
    const edit_items = [_]framework.ValidationValue{
        .{ .object = edit_object[0..] },
    };
    const edit_params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "stale.txt" } },
        .{ .key = "edits", .value = .{ .array = edit_items[0..] } },
    };

    const edit_envelope = try dispatcher.dispatch(.{
        .request_id = "req_hash_edit_stale",
        .method = "edit_file",
        .params = edit_params[0..],
        .source = .@"test",
    }, false);
    try std.testing.expect(edit_envelope.ok);
    defer std.testing.allocator.free(edit_envelope.result.?.success_json);
    try std.testing.expect(std.mem.indexOf(u8, edit_envelope.result.?.success_json, "HASH_MISMATCH") != null);
    try std.testing.expect(std.mem.indexOf(u8, edit_envelope.result.?.success_json, "refreshed_context") != null);

    const refreshed_anchor = try tools.hashline.anchor.formatAnchor(std.testing.allocator, 1, "delta");
    defer std.testing.allocator.free(refreshed_anchor);
    try std.testing.expect(std.mem.indexOf(u8, edit_envelope.result.?.success_json, refreshed_anchor) != null);
}

test "permission rules can block builtin tool execution before tool body runs" {
    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "permission": { "rules": [
        \\    { "permission": "read", "pattern": "*", "action": "deny" }
        \\  ] },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.project_dir, "blocked.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();
        try file.writeAll("blocked");
    }

    var dispatcher = fixture.app_context.makeDispatcher();
    const params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "blocked.txt" } },
    };

    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_read_blocked",
        .method = "read_file",
        .params = params[0..],
        .source = .@"test",
    }, false);

    try std.testing.expect(!envelope.ok);
    try std.testing.expect(envelope.app_error != null);
}

test "repo health check builtin is backed by framework tooling" {
    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();
    fixture.app_context.tool_runtime.permission_runtime = null;

    const git_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.project_dir, ".git" });
    defer std.testing.allocator.free(git_path);
    try fixture.app_context.framework_tooling.effects_runtime.file_system.makePath(git_path);

    const src_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.project_dir, "src" });
    defer std.testing.allocator.free(src_path);
    try fixture.app_context.framework_tooling.effects_runtime.file_system.makePath(src_path);

    const build_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.project_dir, "build.zig" });
    defer std.testing.allocator.free(build_path);
    try fixture.app_context.framework_tooling.effects_runtime.file_system.writeFile(build_path, "const std = @import(\"std\"); pub fn build(_: *std.Build) void {}");

    var dispatcher = fixture.app_context.makeDispatcher();
    const params = [_]framework.ValidationField{
        .{ .key = "path", .value = .{ .string = "." } },
    };

    const envelope = try dispatcher.dispatch(.{
        .request_id = "req_repo_health_check_builtin",
        .method = "repo_health_check",
        .params = params[0..],
        .source = .@"test",
    }, false);
    defer std.testing.allocator.free(envelope.result.?.success_json);

    try std.testing.expect(envelope.ok);
    try std.testing.expect(std.mem.indexOf(u8, envelope.result.?.success_json, "\"repo_health_check\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, envelope.result.?.success_json, "\\\"status\\\":\\\"healthy\\\"") != null);

    const events = try fixture.app_context.framework_app.event_bus.snapshot(std.testing.allocator);
    defer {
        for (events) |*event| event.deinit(std.testing.allocator);
        std.testing.allocator.free(events);
    }
    var saw_started = false;
    var saw_completed = false;
    for (events) |event| {
        if (std.mem.eql(u8, event.topic, "tool.started")) saw_started = true;
        if (std.mem.eql(u8, event.topic, "tool.completed")) saw_completed = true;
    }
    try std.testing.expect(saw_started);
    try std.testing.expect(saw_completed);
}

test "question builtin tool blocks until answers are supplied and returns formatted result" {
    var fixture = try makeTestAppContextWithConfig(
        std.testing.allocator,
        \\{
        \\  "agent": { "default": "build" },
        \\  "permission": { "rules": [
        \\    { "permission": "question", "pattern": "*", "action": "allow" }
        \\  ] },
        \\  "session": { "store": { "path": "sessions" } }
        \\}
    );
    defer fixture.deinit();

    const question_tool = fixture.app_context.tool_registry.get("question").?;
    const object_fields = [_]framework.ValidationField{
        .{ .key = "label", .value = .{ .string = "A" } },
        .{ .key = "description", .value = .{ .string = "alpha" } },
    };
    const question_fields = [_]framework.ValidationField{
        .{ .key = "header", .value = .{ .string = "Mode" } },
        .{ .key = "question", .value = .{ .string = "Choose one" } },
        .{ .key = "options", .value = .{ .array = &.{.{ .object = object_fields[0..] }} } },
    };
    const params = [_]framework.ValidationField{
        .{ .key = "questions", .value = .{ .array = &.{.{ .object = question_fields[0..] }} } },
    };

    const tool_thread = try std.Thread.spawn(.{}, struct {
        fn run(fixture_ptr: *AppTestFixture, definition: *const tools.ToolDefinition, params_value: []const framework.ValidationField) !void {
            const logger = fixture_ptr.app_context.framework_app.logger.child("test").child("question");
            const command_ctx = framework.CommandContext{
                .allocator = std.testing.allocator,
                .request = .{
                    .request_id = "req_question_tool",
                    .source = .@"test",
                    .authority = .public,
                },
                .command_id = definition.id,
                .command_method = definition.id,
                .command_description = definition.description,
                .logger = logger,
                .validated_params = params_value,
            };

            var result = try fixture_ptr.app_context.tool_runtime.executeById(&command_ctx, definition, .{
                .session_id = "session_question_tool",
                .message_id = "message_question_tool",
                .call_id = "call_question_tool",
            });
            defer result.deinit(std.testing.allocator);
            try std.testing.expect(std.mem.indexOf(u8, result.output_text, "User answered your questions") != null);
            try std.testing.expect(std.mem.indexOf(u8, result.output_text, "\"Choose one\"=\"A\"") != null);
        }
    }.run, .{ &fixture, question_tool, params[0..] });

    const started = std.time.milliTimestamp();
    var pending_questions = try fixture.app_context.questionRuntime().list(std.testing.allocator);
    while (pending_questions.len == 0 and @as(u64, @intCast(std.time.milliTimestamp() - started)) < 1_000) {
        std.testing.allocator.free(pending_questions);
        std.Thread.sleep(5 * std.time.ns_per_ms);
        pending_questions = try fixture.app_context.questionRuntime().list(std.testing.allocator);
    }
    defer {
        for (pending_questions) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(pending_questions);
    }
    try std.testing.expectEqual(@as(usize, 1), pending_questions.len);

    var answers = [_]question.QuestionAnswer{
        .{ .selections = try question.cloneStringSlice(std.testing.allocator, @constCast(&[_][]const u8{"A"})) },
    };
    defer answers[0].deinit(std.testing.allocator);
    try std.testing.expect(try fixture.app_context.questionRuntime().reply(pending_questions[0].id, answers[0..]));

    tool_thread.join();
}

fn findLogMessage(sink: *framework.MemorySink, message: []const u8) bool {
    for (0..sink.count()) |index| {
        const record = sink.recordAt(index) orelse continue;
        if (std.mem.eql(u8, record.message, message)) return true;
    }
    return false;
}

const AppTestFixture = struct {
    tmp_dir: std.testing.TmpDir,
    root_path: []u8,
    project_dir: []u8,
    global_path: []u8,
    app_context: AppContext,

    fn deinit(self: *AppTestFixture) void {
        self.app_context.deinit();
        std.testing.allocator.free(self.global_path);
        std.testing.allocator.free(self.project_dir);
        std.testing.allocator.free(self.root_path);
        self.tmp_dir.cleanup();
    }
};

fn makeTestAppContextWithConfig(allocator: std.mem.Allocator, config_json: []const u8) !AppTestFixture {
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
    try file.writeAll(config_json);

    const app_context = try AppContext.initWithConfigOptions(allocator, .{
        .console_log_enabled = false,
    }, .{
        .current_dir = project_dir,
        .global_config_path = global_path,
    });

    return .{
        .tmp_dir = tmp_dir,
        .root_path = root_path,
        .project_dir = project_dir,
        .global_path = global_path,
        .app_context = app_context,
    };
}

fn parseToolOutputText(allocator: std.mem.Allocator, json_text: []const u8) ![]u8 {
    const Parsed = struct {
        output_text: []const u8,
    };
    const parsed = try std.json.parseFromSlice(Parsed, allocator, json_text, .{
        .ignore_unknown_fields = true,
    });
    defer parsed.deinit();
    return allocator.dupe(u8, parsed.value.output_text);
}

fn extractHashlineAnchor(allocator: std.mem.Allocator, output_text: []const u8, line_no: usize) ![]u8 {
    var lines = std.mem.splitScalar(u8, output_text, '\n');
    var index: usize = 1;
    while (lines.next()) |line| : (index += 1) {
        if (index != line_no) continue;
        if (std.mem.indexOfScalar(u8, line, '|')) |pipe_index| {
            return allocator.dupe(u8, line[0..pipe_index]);
        }
        return error.HashlineAnchorMissing;
    }
    return error.HashlineAnchorMissing;
}
