const std = @import("std");
const effects = @import("../effects/root.zig");
const runtime = @import("../runtime/root.zig");
const tool_registry = @import("tool_registry.zig");
const tool_runner = @import("tool_runner.zig");
const script_host = @import("script_host.zig");

pub const ToolingRuntime = struct {
    allocator: std.mem.Allocator,
    app_context: *runtime.AppContext,
    effects: *effects.EffectsRuntime,
    registry: *tool_registry.ToolRegistry,
    tool_runner: *tool_runner.ToolRunner,
    script_host: *script_host.ScriptHost,
    owns_tool_runner: bool,
    owns_script_host: bool,

    pub const Dependencies = struct {
        allocator: std.mem.Allocator,
        app_context: *runtime.AppContext,
        effects: *effects.EffectsRuntime,
        registry: *tool_registry.ToolRegistry,
        tool_runner: ?*tool_runner.ToolRunner = null,
        script_host: ?*script_host.ScriptHost = null,
    };

    pub fn init(deps: Dependencies) !*ToolingRuntime {
        const self = try deps.allocator.create(ToolingRuntime);
        errdefer deps.allocator.destroy(self);

        var owns_tool_runner = false;
        const runner_ref = if (deps.tool_runner) |runner|
            runner
        else blk: {
            const runner = try deps.allocator.create(tool_runner.ToolRunner);
            runner.* = tool_runner.ToolRunner.init(
                deps.allocator,
                deps.registry,
                deps.effects,
                null,
                deps.app_context.logger,
                deps.app_context.eventBus(),
            );
            owns_tool_runner = true;
            break :blk runner;
        };
        errdefer if (owns_tool_runner) deps.allocator.destroy(runner_ref);

        var owns_script_host = false;
        const host_ref = if (deps.script_host) |host|
            host
        else blk: {
            const host = try deps.allocator.create(script_host.ScriptHost);
            host.* = script_host.ScriptHost.init(
                deps.allocator,
                deps.effects.process_runner,
                deps.app_context.logger,
                deps.app_context.eventBus(),
            );
            owns_script_host = true;
            break :blk host;
        };
        errdefer if (owns_script_host) deps.allocator.destroy(host_ref);

        if (owns_tool_runner) {
            runner_ref.script_host = host_ref;
        }

        self.* = .{
            .allocator = deps.allocator,
            .app_context = deps.app_context,
            .effects = deps.effects,
            .registry = deps.registry,
            .tool_runner = runner_ref,
            .script_host = host_ref,
            .owns_tool_runner = owns_tool_runner,
            .owns_script_host = owns_script_host,
        };
        return self;
    }

    pub fn deinit(self: *ToolingRuntime) void {
        if (self.owns_script_host) self.allocator.destroy(self.script_host);
        if (self.owns_tool_runner) self.allocator.destroy(self.tool_runner);
        self.allocator.destroy(self);
    }
};

test "tooling runtime initializes with owned runner and script host" {
    var app_context = try runtime.AppContext.init(std.testing.allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    var effects_runtime = effects.EffectsRuntime.init(.{});
    var registry = tool_registry.ToolRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const tooling_runtime = try ToolingRuntime.init(.{
        .allocator = std.testing.allocator,
        .app_context = &app_context,
        .effects = &effects_runtime,
        .registry = &registry,
    });
    defer tooling_runtime.deinit();

    try std.testing.expect(tooling_runtime.tool_runner.registry == &registry);
    try std.testing.expect(tooling_runtime.script_host.process_runner.name().len > 0);
}


