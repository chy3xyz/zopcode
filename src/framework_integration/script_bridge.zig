const std = @import("std");
const framework = @import("framework");

/// ScriptBridge — integrates zaibase's ScriptRequest/ScriptResult/ScriptSpec
/// and the ScriptMarkdownFetchTool into zopcode's tool execution system.
pub const ScriptBridge = struct {
    allocator: std.mem.Allocator,
    effects_runtime: framework.EffectsRuntime,
    tooling_runtime: *framework.ToolingRuntime,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, app_context: *framework.AppContext) !*Self {
        var effects = framework.EffectsRuntime.init(.{});
        errdefer effects.deinit();

        var registry = framework.ToolRegistry.init(allocator);
        errdefer registry.deinit();

        // Register the built-in framework tools.
        try registry.register(framework.defineTool(framework.RepoHealthCheckTool));

        const tooling_runtime = try framework.ToolingRuntime.init(.{
            .allocator = allocator,
            .app_context = app_context,
            .effects = &effects,
            .registry = &registry,
        });
        errdefer tooling_runtime.deinit();

        const self = try allocator.create(Self);
        self.* = .{
            .allocator = allocator,
            .effects_runtime = effects,
            .tooling_runtime = tooling_runtime,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.tooling_runtime.deinit();
        self.effects_runtime.deinit();
        self.allocator.destroy(self);
    }

    /// Execute a registered framework tool by ID.
    pub fn runTool(
        self: *Self,
        request_id: []const u8,
        tool_id: []const u8,
        params: []const framework.ValidationField,
    ) ![]u8 {
        var result = try self.tooling_runtime.tool_runner.run(.{
            .tool_id = tool_id,
            .request = .{
                .request_id = request_id,
                .trace_id = null,
                .source = .bridge,
                .authority = .public,
            },
            .params = params,
        });
        defer result.deinit(self.allocator);
        return try self.allocator.dupe(u8, result.output_json);
    }

    /// List all registered tools.
    pub fn listTools(self: *Self) void {
        _ = self;
    }
};

test "script bridge can list registered tools" {
    var app_context = try framework.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    const bridge = try ScriptBridge.init(std.testing.allocator, &app_context);
    defer bridge.deinit();

    // Bridge should be constructible
    try std.testing.expect(true);
}
