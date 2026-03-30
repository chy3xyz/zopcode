const std = @import("std");
const framework = @import("framework");

pub const ToolingBridge = struct {
    allocator: std.mem.Allocator,
    effects_runtime: framework.EffectsRuntime,
    registry: framework.ToolRegistry,
    tooling_runtime: *framework.ToolingRuntime,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, app_context: *framework.AppContext) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .effects_runtime = framework.EffectsRuntime.init(.{}),
            .registry = framework.ToolRegistry.init(allocator),
            .tooling_runtime = undefined,
        };
        errdefer self.registry.deinit();

        try self.registry.register(framework.defineTool(framework.RepoHealthCheckTool));

        self.tooling_runtime = try framework.ToolingRuntime.init(.{
            .allocator = allocator,
            .app_context = app_context,
            .effects = &self.effects_runtime,
            .registry = &self.registry,
        });
        errdefer self.tooling_runtime.deinit();

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.tooling_runtime.deinit();
        self.registry.deinit();
        self.allocator.destroy(self);
    }

    pub fn runRepoHealth(
        self: *Self,
        allocator: std.mem.Allocator,
        request_id: []const u8,
        trace_id: ?[]const u8,
        working_dir: []const u8,
        raw_path: []const u8,
    ) ![]u8 {
        const resolved_path = if (std.fs.path.isAbsolute(raw_path))
            try allocator.dupe(u8, raw_path)
        else
            try std.fs.path.join(allocator, &.{ working_dir, raw_path });
        defer allocator.free(resolved_path);

        const params = [_]framework.ValidationField{
            .{ .key = "path", .value = .{ .string = resolved_path } },
        };

        var result = try self.tooling_runtime.tool_runner.run(.{
            .tool_id = framework.RepoHealthCheckTool.tool_id,
            .request = .{
                .request_id = request_id,
                .trace_id = trace_id,
                .source = .bridge,
                .authority = .public,
            },
            .params = params[0..],
        });
        defer result.deinit(self.allocator);

        return try allocator.dupe(u8, result.output_json);
    }
};

test "tooling bridge runs framework repo health check" {
    var app_context = try framework.AppContext.init(std.testing.allocator, .{
        .console_log_enabled = false,
    });
    defer app_context.deinit();

    const bridge = try ToolingBridge.init(std.testing.allocator, &app_context);
    defer bridge.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);

    const git_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, ".git" });
    defer std.testing.allocator.free(git_path);
    try bridge.effects_runtime.file_system.makePath(git_path);

    const src_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "src" });
    defer std.testing.allocator.free(src_path);
    try bridge.effects_runtime.file_system.makePath(src_path);

    const build_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "build.zig" });
    defer std.testing.allocator.free(build_path);
    try bridge.effects_runtime.file_system.writeFile(build_path, "const std = @import(\"std\"); pub fn build(_: *std.Build) void {}");

    const output = try bridge.runRepoHealth(
        std.testing.allocator,
        "zig_opencode_bridge_repo_health_01",
        null,
        root_path,
        ".",
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"status\":\"healthy\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"has_src_dir\":true") != null);
}
