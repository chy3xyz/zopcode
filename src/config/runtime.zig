const std = @import("std");
const framework = @import("framework");
const defaults = @import("defaults.zig");
const loader = @import("loader.zig");
const paths = @import("paths.zig");
const schema = @import("schema.zig");
const view = @import("view.zig");

pub const RuntimeOptions = paths.RuntimeOptions;

pub const Dependencies = struct {
    store: framework.ConfigStore,
    change_log: ?framework.ConfigChangeLog = null,
    side_effect: ?framework.ConfigSideEffect = null,
    logger: ?*framework.Logger = null,
    observer: ?framework.Observer = null,
    event_bus: ?framework.EventBus = null,
};

pub const ConfigRuntime = struct {
    allocator: std.mem.Allocator,
    dependencies: Dependencies,
    defaults: framework.ConfigDefaults,
    resolved_paths: paths.ResolvedPaths,
    env_prefix: []u8,
    owned_env_pairs: ?[]paths.EnvPair = null,

    const Self = @This();

    pub fn init(
        allocator: std.mem.Allocator,
        dependencies: Dependencies,
        options: RuntimeOptions,
    ) !Self {
        var self = Self{
            .allocator = allocator,
            .dependencies = dependencies,
            .defaults = defaults.bootstrapDefaults(),
            .resolved_paths = try paths.resolve(allocator, options),
            .env_prefix = try allocator.dupe(u8, options.env_prefix),
            .owned_env_pairs = null,
        };
        errdefer self.deinit();

        if (options.env_pairs) |pairs| {
            const cloned = try allocator.alloc(paths.EnvPair, pairs.len);
            errdefer allocator.free(cloned);

            for (pairs, 0..) |pair, index| {
                cloned[index] = .{
                    .name = try allocator.dupe(u8, pair.name),
                    .value = try allocator.dupe(u8, pair.value),
                };
            }
            self.owned_env_pairs = cloned;
        }

        return self;
    }

    pub fn deinit(self: *Self) void {
        if (self.owned_env_pairs) |pairs| {
            for (pairs) |pair| {
                self.allocator.free(pair.name);
                self.allocator.free(pair.value);
            }
            self.allocator.free(pairs);
        }
        self.allocator.free(self.env_prefix);
        self.resolved_paths.deinit(self.allocator);
    }

    pub fn load(self: *Self) !void {
        if (self.dependencies.logger) |logger| {
            var trace = try framework.StepTrace.begin(self.allocator, logger, "config/runtime", "load", 250);
            defer trace.deinit();

            self.loadWithLogging(logger) catch |err| {
                trace.finish("CONFIG_LOAD_FAILED");
                return err;
            };

            trace.finish(null);
            return;
        }

        try self.loadWithoutLogging();
    }

    fn loadWithLogging(self: *Self, logger: *framework.Logger) !void {
        var layers = try loader.loadLayers(self.allocator, &self.resolved_paths, self.owned_env_pairs, self.env_prefix);
        defer layers.deinit(self.allocator);

        logger.child("config").child("runtime").info("config layers discovered", &.{
            framework.LogField.boolean("has_defaults", true),
            framework.LogField.boolean("has_global", layers.global.len > 0),
            framework.LogField.boolean("has_custom", layers.custom.len > 0),
            framework.LogField.boolean("has_project", layers.project.len > 0),
            framework.LogField.int("env_override_count", @intCast(layers.env.len)),
        });

        try self.applyBootstrapLayer(layers.global);
        if (layers.global.len > 0) {
            logger.child("config").child("runtime").info("config layer applied", &.{
                framework.LogField.string("layer", "global"),
                framework.LogField.int("field_count", @intCast(layers.global.len)),
            });
        }
        try self.applyBootstrapLayer(layers.custom);
        if (layers.custom.len > 0) {
            logger.child("config").child("runtime").info("config layer applied", &.{
                framework.LogField.string("layer", "custom"),
                framework.LogField.int("field_count", @intCast(layers.custom.len)),
            });
        }
        try self.applyBootstrapLayer(layers.project);
        if (layers.project.len > 0) {
            logger.child("config").child("runtime").info("config layer applied", &.{
                framework.LogField.string("layer", "project"),
                framework.LogField.int("field_count", @intCast(layers.project.len)),
            });
        }
        try self.applyBootstrapLayer(layers.env);
        if (layers.env.len > 0) {
            logger.child("config").child("runtime").info("config layer applied", &.{
                framework.LogField.string("layer", "env"),
                framework.LogField.int("field_count", @intCast(layers.env.len)),
            });
        }

        var effective_config = try self.effective(self.allocator);
        defer effective_config.deinit(self.allocator);
        const default_model = if (effective_config.model.default_model) |model|
            try std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ model.provider_id, model.model_id })
        else
            try self.allocator.dupe(u8, "unset");
        defer self.allocator.free(default_model);

        logger.child("config").child("runtime").info("effective config resolved", &.{
            framework.LogField.string("default_agent", effective_config.default_agent),
            framework.LogField.string("default_model", default_model),
            framework.LogField.string("session_store_path", effective_config.session.store_path),
        });
    }

    fn loadWithoutLogging(self: *Self) !void {
        var layers = try loader.loadLayers(self.allocator, &self.resolved_paths, self.owned_env_pairs, self.env_prefix);
        defer layers.deinit(self.allocator);

        try self.applyBootstrapLayer(layers.global);
        try self.applyBootstrapLayer(layers.custom);
        try self.applyBootstrapLayer(layers.project);
        try self.applyBootstrapLayer(layers.env);
    }

    pub fn effective(self: *const Self, allocator: std.mem.Allocator) !view.EffectiveConfig {
        return view.buildEffectiveConfig(allocator, self.dependencies.store, self.defaults, &self.resolved_paths);
    }

    pub fn writeFields(self: *Self, updates: []const framework.ValidationField, confirm_risk: bool) !framework.ConfigWriteAttempt {
        if (self.dependencies.logger) |logger| {
            var trace = try framework.StepTrace.begin(self.allocator, logger, "config/runtime", "write_fields", 250);
            defer trace.deinit();

            var pipeline = self.makePipeline();
            var attempt = pipeline.applyWrite(updates, confirm_risk) catch |err| {
                trace.finish("CONFIG_WRITE_FAILED");
                return err;
            };

            logger.child("config").child("runtime").info("runtime config write applied", &.{
                framework.LogField.int("field_count", @intCast(updates.len)),
                framework.LogField.boolean("applied", attempt.applied()),
                framework.LogField.boolean("requires_restart", attempt.requiresRestart()),
            });

            trace.finish(null);
            return attempt;
        }

        var pipeline = self.makePipeline();
        return pipeline.applyWrite(updates, confirm_risk);
    }

    pub fn fieldDefinitions(self: *const Self) []const framework.FieldDefinition {
        _ = self;
        return schema.fieldDefinitions();
    }

    fn applyBootstrapLayer(self: *Self, updates: []const framework.ValidationField) !void {
        if (updates.len == 0) return;

        var pipeline = self.makePipeline();
        var report = try pipeline.validateWrite(updates, false);
        defer report.deinit();
        if (!report.isOk()) return error.InvalidBootstrapConfigLayer;

        _ = try self.dependencies.store.applyValidatedWrites(updates);
    }

    fn makePipeline(self: *Self) framework.ConfigWritePipeline {
        return framework.ConfigWritePipeline.initWithDependencies(
            self.allocator,
            schema.fieldDefinitions(),
            &.{},
            self.dependencies.store,
            self.dependencies.change_log,
            self.dependencies.side_effect,
            null,
            self.dependencies.observer,
            self.dependencies.event_bus,
            self.dependencies.logger,
        );
    }
};

test "config runtime loads layered config with deterministic precedence" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const project_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "workspace" });
    defer std.testing.allocator.free(project_dir);
    _ = std.c.mkdir(@ptrCast(project_dir.ptr), 0o755);

    const global_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "global.json" });
    defer std.testing.allocator.free(global_path);
    const custom_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "custom.json" });
    defer std.testing.allocator.free(custom_path);
    const project_config = try std.fs.path.join(std.testing.allocator, &.{ project_dir, "zopcode.json" });
    defer std.testing.allocator.free(project_config);

    {
        var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), global_path, .{});
        defer file.close(std.Io.Threaded.global_single_threaded.*.io());
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "{\"server\":{\"hostname\":\"127.0.0.1\"},\"model\":{\"default\":\"anthropic/claude-sonnet-4-5\"}}");
    }
    {
        var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), custom_path, .{});
        defer file.close(std.Io.Threaded.global_single_threaded.*.io());
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "{\"agent\":{\"default\":\"plan\"}}");
    }
    {
        var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), project_config, .{});
        defer file.close(std.Io.Threaded.global_single_threaded.*.io());
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "{\"server\":{\"port\":9191},\"session\":{\"store\":{\"path\":\"data/sessions\"}}}");
    }

    var store = framework.MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();
    var change_log = framework.MemoryConfigChangeLog.init(std.testing.allocator);
    defer change_log.deinit();
    var side_effects = framework.MemoryConfigSideEffectSink.init(std.testing.allocator);
    defer side_effects.deinit();

    var runtime = try ConfigRuntime.init(std.testing.allocator, .{
        .store = store.asConfigStore(),
        .change_log = change_log.asChangeLog(),
        .side_effect = side_effects.asSideEffect(),
    }, .{
        .current_dir = project_dir,
        .global_config_path = global_path,
        .custom_config_path = custom_path,
    });
    defer runtime.deinit();

    try runtime.load();

    var effective = try runtime.effective(std.testing.allocator);
    defer effective.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("plan", effective.default_agent);
    try std.testing.expectEqual(@as(u16, 9191), effective.server.port.?);
    try std.testing.expect(std.mem.endsWith(u8, effective.session.store_path, "data\\sessions") or std.mem.endsWith(u8, effective.session.store_path, "data/sessions"));
}

test "config runtime write fields override file-backed effective config" {
    var store = framework.MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();
    var memory_sink = framework.MemorySink.init(std.testing.allocator, 64);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var runtime = try ConfigRuntime.init(std.testing.allocator, .{
        .store = store.asConfigStore(),
        .logger = &logger,
    }, .{});
    defer runtime.deinit();

    const updates = [_]framework.ValidationField{
        .{ .key = schema.keys.agent_default, .value = .{ .string = "explore" } },
    };

    var attempt = try runtime.writeFields(updates[0..], false);
    defer attempt.deinit();

    try std.testing.expect(attempt.applied());

    var effective = try runtime.effective(std.testing.allocator);
    defer effective.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("explore", effective.default_agent);
    try std.testing.expect(findLogMessage(&memory_sink, "runtime config write applied"));
    try std.testing.expect(findLogMessage(&memory_sink, "Step started"));
}

test "config runtime emits discovery and summary logs during load" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const project_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "workspace" });
    defer std.testing.allocator.free(project_dir);
    _ = std.c.mkdir(@ptrCast(project_dir.ptr), 0o755);

    const project_config = try std.fs.path.join(std.testing.allocator, &.{ project_dir, "zopcode.json" });
    defer std.testing.allocator.free(project_config);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), project_config, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "{\"agent\":{\"default\":\"plan\"}}");

    const missing_global = try std.fs.path.join(std.testing.allocator, &.{ root_path, "missing-global.json" });
    defer std.testing.allocator.free(missing_global);

    var store = framework.MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();
    var memory_sink = framework.MemorySink.init(std.testing.allocator, 64);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var runtime = try ConfigRuntime.init(std.testing.allocator, .{
        .store = store.asConfigStore(),
        .logger = &logger,
    }, .{
        .current_dir = project_dir,
        .global_config_path = missing_global,
    });
    defer runtime.deinit();

    try runtime.load();

    try std.testing.expect(findLogMessage(&memory_sink, "config layers discovered"));
    try std.testing.expect(findLogMessage(&memory_sink, "effective config resolved"));
}

test "config runtime loads explicit lsp server definitions from project config" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const project_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "workspace" });
    defer std.testing.allocator.free(project_dir);
    _ = std.c.mkdir(@ptrCast(project_dir.ptr), 0o755);

    const project_config = try std.fs.path.join(std.testing.allocator, &.{ project_dir, "zopcode.json" });
    defer std.testing.allocator.free(project_config);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), project_config, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), 
        \\{
        \\  "lsp": {
        \\    "enabled": true,
        \\    "servers": [
        \\      {
        \\        "id": "zls",
        \\        "command": ["zls"],
        \\        "extensions": [".zig", ".zon"],
        \\        "root_markers": ["build.zig"],
        \\        "initialization_json": "{}"
        \\      }
        \\    ]
        \\  }
        \\}
    );

    var store = framework.MemoryConfigStore.init(std.testing.allocator);
    defer store.deinit();

    var runtime = try ConfigRuntime.init(std.testing.allocator, .{
        .store = store.asConfigStore(),
    }, .{
        .current_dir = project_dir,
    });
    defer runtime.deinit();

    try runtime.load();

    var effective = try runtime.effective(std.testing.allocator);
    defer effective.deinit(std.testing.allocator);

    try std.testing.expect(effective.lsp.enabled);
    try std.testing.expectEqual(@as(usize, 1), effective.lsp.servers.len);
    try std.testing.expectEqualStrings("zls", effective.lsp.servers[0].id);
    try std.testing.expectEqual(@as(usize, 2), effective.lsp.servers[0].extensions.len);
}

fn findLogMessage(sink: *framework.MemorySink, message: []const u8) bool {
    for (0..sink.count()) |index| {
        const record = sink.recordAt(index) orelse continue;
        if (std.mem.eql(u8, record.message, message)) return true;
    }
    return false;
}
