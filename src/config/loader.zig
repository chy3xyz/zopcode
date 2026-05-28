const std = @import("std");
const framework = @import("framework");
const schema = @import("schema.zig");
const paths = @import("paths.zig");

pub const EnvPair = paths.EnvPair;

pub const ConfigLayers = struct {
    global: []framework.ValidationField,
    custom: []framework.ValidationField,
    project: []framework.ValidationField,
    env: []framework.ValidationField,

    pub fn deinit(self: *ConfigLayers, allocator: std.mem.Allocator) void {
        freeFields(allocator, self.global);
        freeFields(allocator, self.custom);
        freeFields(allocator, self.project);
        freeFields(allocator, self.env);
    }
};

pub fn loadLayers(
    allocator: std.mem.Allocator,
    resolved_paths: *const paths.ResolvedPaths,
    env_pairs: ?[]const EnvPair,
    env_prefix: []const u8,
) !ConfigLayers {
    return .{
        .global = try loadFileFields(allocator, resolved_paths.global_config_path),
        .custom = try loadFileFields(allocator, resolved_paths.custom_config_path),
        .project = try loadFileFields(allocator, resolved_paths.project_config_path),
        .env = try loadEnvFields(allocator, env_pairs, env_prefix),
    };
}

pub fn loadFileFields(allocator: std.mem.Allocator, file_path: ?[]const u8) ![]framework.ValidationField {
    const path = file_path orelse return allocator.alloc(framework.ValidationField, 0);
    return framework.ConfigLoader.loadSnapshotFile(allocator, path, schema.fieldDefinitions()) catch |err| switch (err) {
        error.FileNotFound => allocator.alloc(framework.ValidationField, 0),
        else => err,
    };
}

pub fn loadEnvFields(
    allocator: std.mem.Allocator,
    env_pairs: ?[]const EnvPair,
    env_prefix: []const u8,
) ![]framework.ValidationField {
    if (env_pairs) |pairs| {
        const framework_pairs = try allocator.alloc(framework.config.loader.EnvPair, pairs.len);
        defer allocator.free(framework_pairs);
        for (pairs, 0..) |pair, index| {
            framework_pairs[index] = .{
                .name = pair.name,
                .value = pair.value,
            };
        }
        return framework.ConfigLoader.loadEnvOverridesFromPairs(allocator, schema.fieldDefinitions(), env_prefix, framework_pairs);
    }

    return framework.ConfigLoader.loadEnvOverrides(allocator, schema.fieldDefinitions(), env_prefix);
}

pub fn freeFields(allocator: std.mem.Allocator, fields: []framework.ValidationField) void {
    for (fields) |field| field.deinit(allocator);
    allocator.free(fields);
}

test "loader can parse nested json config into flat fields" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const config_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "opencode.json" });
    defer std.testing.allocator.free(config_path);

    var file = try std.Io.Dir.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll(
        \\{
        \\  "model": { "default": "anthropic/claude-sonnet-4-5" },
        \\  "server": { "port": 9191 }
        \\}
    );

    const fields = try loadFileFields(std.testing.allocator, config_path);
    defer freeFields(std.testing.allocator, fields);

    try std.testing.expectEqual(@as(usize, 2), fields.len);
}
