const std = @import("std");
const framework = @import("framework");

pub const HookInfo = struct {
    name: []const u8,

    pub fn clone(self: HookInfo, allocator: std.mem.Allocator) !HookInfo {
        return .{ .name = try allocator.dupe(u8, self.name) };
    }

    pub fn deinit(self: *HookInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const PluginInfo = struct {
    id: []const u8,
    path: []const u8,
    description: ?[]const u8 = null,
    enabled: bool = true,
    hooks: []HookInfo,

    pub fn clone(self: PluginInfo, allocator: std.mem.Allocator) !PluginInfo {
        const hooks = try allocator.alloc(HookInfo, self.hooks.len);
        errdefer allocator.free(hooks);
        for (self.hooks, 0..) |item, index| {
            hooks[index] = try item.clone(allocator);
            errdefer hooks[index].deinit(allocator);
        }
        return .{
            .id = try allocator.dupe(u8, self.id),
            .path = try allocator.dupe(u8, self.path),
            .description = if (self.description) |value| try allocator.dupe(u8, value) else null,
            .enabled = self.enabled,
            .hooks = hooks,
        };
    }

    pub fn deinit(self: *PluginInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.path);
        if (self.description) |value| allocator.free(value);
        for (self.hooks) |*item| item.deinit(allocator);
        allocator.free(self.hooks);
    }
};

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    current_dir: []const u8,
};

pub const PluginRuntime = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    plugins_root: []u8,
    plugins: []PluginInfo = &.{},

    const Self = @This();

    pub fn init(deps: Dependencies) !*Self {
        const self = try deps.allocator.create(Self);
        errdefer deps.allocator.destroy(self);
        const plugins_root = try std.fs.path.join(deps.allocator, &.{ deps.current_dir, "plugins" });
        errdefer deps.allocator.free(plugins_root);
        self.* = .{
            .allocator = deps.allocator,
            .logger = deps.logger,
            .plugins_root = plugins_root,
        };
        try self.refresh();
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.plugins) |*item| item.deinit(self.allocator);
        if (self.plugins.len > 0) self.allocator.free(self.plugins);
        self.allocator.free(self.plugins_root);
    }

    pub fn refresh(self: *Self) !void {
        for (self.plugins) |*item| item.deinit(self.allocator);
        if (self.plugins.len > 0) self.allocator.free(self.plugins);
        self.plugins = try discoverPlugins(self.allocator, self.plugins_root);
    }

    pub fn list(self: *Self, allocator: std.mem.Allocator) ![]PluginInfo {
        const items = try allocator.alloc(PluginInfo, self.plugins.len);
        errdefer allocator.free(items);
        for (self.plugins, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return items;
    }

    pub fn triggerHook(self: *Self, hook_name: []const u8, payload_json: []const u8) !usize {
        var count: usize = 0;
        for (self.plugins) |plugin| {
            if (!plugin.enabled) continue;
            for (plugin.hooks) |hook| {
                if (!std.mem.eql(u8, hook.name, hook_name)) continue;
                count += 1;
                self.logger.child("plugin").info("plugin hook triggered", &.{
                    framework.LogField.string("plugin_id", plugin.id),
                    framework.LogField.string("hook_name", hook_name),
                    framework.LogField.string("payload_json", payload_json),
                });
            }
        }
        return count;
    }
};

const ManifestJson = struct {
    id: []const u8,
    description: ?[]const u8 = null,
    enabled: ?bool = null,
    hooks: []const []const u8,
};

fn discoverPlugins(allocator: std.mem.Allocator, root: []const u8) ![]PluginInfo {
    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.*.io(), root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return allocator.alloc(PluginInfo, 0),
        else => return err,
    };
    defer dir.close(std.Io.Threaded.global_single_threaded.*.io());

    var items: std.ArrayListUnmanaged(PluginInfo) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    var it = dir.iterate();
    while (try it.next(std.Io.Threaded.global_single_threaded.*.io())) |entry| {
        if (entry.kind != .directory) continue;
        const manifest_path = try std.fs.path.join(allocator, &.{ root, entry.name, "plugin.json" });
        defer allocator.free(manifest_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), manifest_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer allocator.free(bytes);

        const parsed = try std.json.parseFromSlice(ManifestJson, allocator, bytes, .{});
        defer parsed.deinit();

        const hooks = try allocator.alloc(HookInfo, parsed.value.hooks.len);
        errdefer allocator.free(hooks);
        for (parsed.value.hooks, 0..) |hook, index| {
            hooks[index] = .{ .name = try allocator.dupe(u8, hook) };
            errdefer hooks[index].deinit(allocator);
        }

        try items.append(allocator, .{
            .id = try allocator.dupe(u8, parsed.value.id),
            .path = try allocator.dupe(u8, manifest_path),
            .description = if (parsed.value.description) |value| try allocator.dupe(u8, value) else null,
            .enabled = parsed.value.enabled orelse true,
            .hooks = hooks,
        });
    }

    return try items.toOwnedSlice(allocator);
}

test "plugin runtime loads local plugins and triggers hooks" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const plugins_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "plugins", "demo" });
    defer std.testing.allocator.free(plugins_dir);
    _ = std.c.mkdir(@ptrCast(plugins_dir.ptr), 0o755);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ plugins_dir, "plugin.json" });
    defer std.testing.allocator.free(manifest_path);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), manifest_path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "{\"id\":\"demo\",\"hooks\":[\"tool.before\",\"tool.after\"]}");

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 16);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    const runtime = try PluginRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .current_dir = root_path,
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    const plugins = try runtime.list(std.testing.allocator);
    defer {
        for (plugins) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(plugins);
    }
    try std.testing.expectEqual(@as(usize, 1), plugins.len);
    try std.testing.expectEqualStrings("demo", plugins[0].id);
    try std.testing.expectEqual(@as(usize, 1), try runtime.triggerHook("tool.before", "{}"));
}
