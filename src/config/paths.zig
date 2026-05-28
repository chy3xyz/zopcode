const std = @import("std");

pub const RuntimeOptions = struct {
    current_dir: ?[]const u8 = null,
    workspace_root: ?[]const u8 = null,
    global_config_path: ?[]const u8 = null,
    custom_config_path: ?[]const u8 = null,
    env_pairs: ?[]const EnvPair = null,
    env_prefix: []const u8 = "zig_opencode",
};

pub const EnvPair = struct {
    name: []const u8,
    value: []const u8,
};

pub const ResolvedPaths = struct {
    current_dir: []u8,
    workspace_root: ?[]u8 = null,
    global_config_path: ?[]u8 = null,
    custom_config_path: ?[]u8 = null,
    project_config_path: ?[]u8 = null,

    pub fn deinit(self: *ResolvedPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.current_dir);
        if (self.workspace_root) |workspace_root| allocator.free(workspace_root);
        if (self.global_config_path) |global| allocator.free(global);
        if (self.custom_config_path) |custom| allocator.free(custom);
        if (self.project_config_path) |project| allocator.free(project);
    }
};

pub fn resolve(allocator: std.mem.Allocator, options: RuntimeOptions) !ResolvedPaths {
    const current_dir = if (options.current_dir) |current_dir|
        try allocator.dupe(u8, current_dir)
    else
        try allocator.dupe(u8, ".");

    var resolved = ResolvedPaths{
        .current_dir = current_dir,
        .workspace_root = if (options.workspace_root) |workspace_root| try allocator.dupe(u8, workspace_root) else null,
        .global_config_path = if (options.global_config_path) |global| try allocator.dupe(u8, global) else try defaultGlobalConfigPath(allocator),
        .custom_config_path = if (options.custom_config_path) |custom| try allocator.dupe(u8, custom) else try customConfigPathFromEnv(allocator, options.env_pairs),
        .project_config_path = null,
    };
    errdefer resolved.deinit(allocator);

    resolved.project_config_path = try findProjectConfigPath(allocator, resolved.current_dir, resolved.workspace_root);
    return resolved;
}

pub fn resolveRelativeToBase(allocator: std.mem.Allocator, base_path: []const u8, raw_path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(raw_path)) {
        return allocator.dupe(u8, raw_path);
    }
    return std.fs.path.join(allocator, &.{ base_path, raw_path });
}

fn defaultGlobalConfigPath(allocator: std.mem.Allocator) !?[]u8 {
    const raw = std.c.getenv("HOME") orelse std.c.getenv("USERPROFILE") orelse return null;
    const home = std.mem.sliceTo(raw, 0);
    return try std.fs.path.join(allocator, &.{ home, ".config", "zig-opencode", "opencode.json" });
}

fn customConfigPathFromEnv(allocator: std.mem.Allocator, env_pairs: ?[]const EnvPair) !?[]u8 {
    if (env_pairs) |pairs| {
        for (pairs) |pair| {
            if (std.mem.eql(u8, pair.name, "OPENCODE_CONFIG")) {
                return @as(?[]u8, try allocator.dupe(u8, pair.value));
            }
        }
        return null;
    }

    const r = std.c.getenv("OPENCODE_CONFIG") orelse return null;
    return try allocator.dupe(u8, std.mem.sliceTo(r, 0));
}

fn findProjectConfigPath(
    allocator: std.mem.Allocator,
    start_dir: []const u8,
    workspace_root: ?[]const u8,
) !?[]u8 {
    var current = try allocator.dupe(u8, start_dir);
    defer allocator.free(current);

    while (true) {
        const candidate = try std.fs.path.join(allocator, &.{ current, "opencode.json" });
        if (fileExists(candidate)) {
            return candidate;
        }
        allocator.free(candidate);

        const at_workspace_root = if (workspace_root) |root| std.mem.eql(u8, current, root) else false;
        const git_root = try isGitRoot(allocator, current);
        if (at_workspace_root or git_root) return null;

        const parent = std.fs.path.dirname(current) orelse return null;
        if (std.mem.eql(u8, parent, current)) return null;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }
}

fn isGitRoot(allocator: std.mem.Allocator, path: []const u8) !bool {
    const git_path = try std.fs.path.join(allocator, &.{ path, ".git" });
    defer allocator.free(git_path);
    return fileExists(git_path) or dirExists(git_path);
}

fn fileExists(path: []const u8) bool {
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.*.io(), path, .{}) catch return false;
    return true;
}

fn dirExists(path: []const u8) bool {
    var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.*.io(), path, .{}) catch return false;
    dir.close(std.Io.Threaded.global_single_threaded.*.io());
    return true;
}

test "resolved paths can discover project config from current workspace" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const project_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "project", "nested" });
    defer std.testing.allocator.free(project_dir);
    _ = std.c.mkdir(@ptrCast(project_dir.ptr), 0o755);

    const config_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "project", "opencode.json" });
    defer std.testing.allocator.free(config_path);
    var file = try std.Io.Dir.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll("{}");

    var resolved = try resolve(std.testing.allocator, .{
        .current_dir = project_dir,
    });
    defer resolved.deinit(std.testing.allocator);

    try std.testing.expect(resolved.project_config_path != null);
}
