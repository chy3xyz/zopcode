const std = @import("std");
const framework = @import("framework");
const types = @import("types.zig");

pub const WorkspaceCreateRequest = struct {
    name: []const u8,
};

pub const RunOutput = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,

    pub fn deinit(self: *RunOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const VcsExecutor = struct {
    ptr: *anyopaque,
    run_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, cwd: []const u8, argv: [][]const u8) anyerror!RunOutput,
};

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    current_dir: []const u8,
    workspace_root: []const u8,
    vcs_executor: ?VcsExecutor = null,
};

pub const ProjectRuntime = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    current_dir: []u8,
    workspace_root: []u8,
    vcs_executor: VcsExecutor,

    const Self = @This();

    pub fn init(deps: Dependencies) !*Self {
        const self = try deps.allocator.create(Self);
        errdefer deps.allocator.destroy(self);
        _ = std.c.mkdir(@ptrCast(deps.workspace_root.ptr), 0o755);
        self.* = .{
            .allocator = deps.allocator,
            .logger = deps.logger,
            .current_dir = try deps.allocator.dupe(u8, deps.current_dir),
            .workspace_root = try deps.allocator.dupe(u8, deps.workspace_root),
            .vcs_executor = deps.vcs_executor orelse .{ .ptr = undefined, .run_fn = runProcess },
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.current_dir);
        self.allocator.free(self.workspace_root);
    }

    pub fn currentProject(self: *Self, allocator: std.mem.Allocator) !types.ProjectInfo {
        const vcs = try self.vcsStatus(allocator);
        errdefer {
            var owned_vcs = vcs;
            owned_vcs.deinit(allocator);
        }

        const project_root = if (vcs.available)
            try gitRoot(self, allocator, self.current_dir)
        else
            try allocator.dupe(u8, self.current_dir);
        errdefer allocator.free(project_root);

        const base_name = std.fs.path.basename(project_root);
        return .{
            .name = try allocator.dupe(u8, if (base_name.len == 0) self.current_dir else base_name),
            .workspace_dir = try allocator.dupe(u8, self.current_dir),
            .project_root = project_root,
            .vcs = vcs,
        };
    }

    pub fn vcsStatus(self: *Self, allocator: std.mem.Allocator) !types.VcsStatus {
        const git_root_result = self.runGit(allocator, self.current_dir, &.{ "git", "rev-parse", "--show-toplevel" }) catch |err| switch (err) {
            error.FileNotFound, error.ProcessNotFound => return .{ .available = false },
            else => return .{ .available = false },
        };
        defer {
            var owned = git_root_result;
            owned.deinit(allocator);
        }
        if (git_root_result.exit_code != 0) return .{ .available = false };

        const root = std.mem.trim(u8, git_root_result.stdout, " \r\n");
        const branch_result = try self.runGit(allocator, root, &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" });
        defer {
            var owned = branch_result;
            owned.deinit(allocator);
        }
        const status_result = try self.runGit(allocator, root, &.{ "git", "status", "--porcelain" });
        defer {
            var owned = status_result;
            owned.deinit(allocator);
        }

        const branch = if (branch_result.exit_code == 0)
            try allocator.dupe(u8, std.mem.trim(u8, branch_result.stdout, " \r\n"))
        else
            null;
        const changed_count = countNonEmptyLines(status_result.stdout);
        return .{
            .available = true,
            .branch = branch,
            .dirty = changed_count > 0,
            .changed_file_count = @intCast(changed_count),
        };
    }

    pub fn listWorkspaces(self: *Self, allocator: std.mem.Allocator) ![]types.WorkspaceInfo {
        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.*.io(), self.workspace_root, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc(types.WorkspaceInfo, 0),
            else => return err,
        };
        defer dir.close(std.Io.Threaded.global_single_threaded.*.io());

        var items: std.ArrayListUnmanaged(types.WorkspaceInfo) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        var it = dir.iterate();
        while (try it.next(std.Io.Threaded.global_single_threaded.*.io())) |entry| {
            if (entry.kind != .directory) continue;
            const meta_path = try std.fs.path.join(allocator, &.{ self.workspace_root, entry.name, "workspace.json" });
            defer allocator.free(meta_path);
            const contents = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), meta_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer allocator.free(contents);
            const parsed = try std.json.parseFromSlice(WorkspaceInfoJson, allocator, contents, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try items.append(allocator, try workspaceInfoFromJson(allocator, parsed.value));
        }

        return try items.toOwnedSlice(allocator);
    }

    pub fn createWorkspace(self: *Self, allocator: std.mem.Allocator, request: WorkspaceCreateRequest) !types.WorkspaceInfo {
        const id = try nextWorkspaceId(allocator);
        errdefer allocator.free(id);
        const path = try std.fs.path.join(allocator, &.{ self.workspace_root, id });
        errdefer allocator.free(path);
        _ = std.c.mkdir(@ptrCast(path.ptr), 0o755);

        const info = types.WorkspaceInfo{
            .id = id,
            .name = try allocator.dupe(u8, request.name),
            .path = path,
            .created_at_ms = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds(),
        };
        errdefer {
            var owned = info;
            owned.deinit(allocator);
        }

        const meta_path = try std.fs.path.join(allocator, &.{ path, "workspace.json" });
        defer allocator.free(meta_path);
        try writeJsonFile(allocator, meta_path, workspaceInfoToJson(info));
        return info;
    }

    pub fn removeWorkspace(self: *Self, workspace_id: []const u8) !bool {
        const path = try std.fs.path.join(self.allocator, &.{ self.workspace_root, workspace_id });
        defer self.allocator.free(path);
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.*.io(), path, .{}) catch return false;
        try std.Io.Dir.cwd().deleteTree(std.Io.Threaded.global_single_threaded.*.io(), path);
        return true;
    }

    fn runGit(self: *Self, allocator: std.mem.Allocator, cwd: []const u8, argv: []const []const u8) !RunOutput {
        const cloned = try cloneArgv(allocator, argv);
        defer freeArgv(allocator, cloned);
        return self.vcs_executor.run_fn(self.vcs_executor.ptr, allocator, cwd, cloned);
    }
};

fn gitRoot(self: *ProjectRuntime, allocator: std.mem.Allocator, cwd: []const u8) ![]u8 {
    var result = try self.runGit(allocator, cwd, &.{ "git", "rev-parse", "--show-toplevel" });
    defer result.deinit(allocator);
    if (result.exit_code != 0) return allocator.dupe(u8, cwd);
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n"));
}

fn runProcess(_: *anyopaque, allocator: std.mem.Allocator, cwd: []const u8, argv: [][]const u8) anyerror!RunOutput {
    const result = try std.process.run(allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(512 * 1024), .stderr_limit = .limited(512 * 1024)
    });
    const exit_code: i32 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}

fn cloneArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![][]const u8 {
    const items = try allocator.alloc([]const u8, argv.len);
    errdefer allocator.free(items);
    for (argv, 0..) |item, index| {
        items[index] = try allocator.dupe(u8, item);
    }
    return items;
}

fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |item| allocator.free(item);
    allocator.free(argv);
}

fn countNonEmptyLines(text: []const u8) usize {
    var total: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len > 0) total += 1;
    }
    return total;
}

const WorkspaceInfoJson = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    created_at_ms: i64,
};

fn workspaceInfoToJson(info: types.WorkspaceInfo) WorkspaceInfoJson {
    return .{
        .id = info.id,
        .name = info.name,
        .path = info.path,
        .created_at_ms = info.created_at_ms,
    };
}

fn workspaceInfoFromJson(allocator: std.mem.Allocator, value: WorkspaceInfoJson) !types.WorkspaceInfo {
    return .{
        .id = try allocator.dupe(u8, value.id),
        .name = try allocator.dupe(u8, value.name),
        .path = try allocator.dupe(u8, value.path),
        .created_at_ms = value.created_at_ms,
    };
}

fn writeJsonFile(allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "{f}", .{std.json.fmt(value, .{})});
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), out.items);
}

fn nextWorkspaceId(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "workspace_{d}_{d}", .{ std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds(), 0 });
}

test "project runtime resolves project identity and vcs status" {
    const MockGit = struct {
        fn run(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, argv: [][]const u8) anyerror!RunOutput {
            if (std.mem.eql(u8, argv[2], "--show-toplevel")) {
                return .{
                    .stdout = try allocator.dupe(u8, "E:/repo\n"),
                    .stderr = try allocator.alloc(u8, 0),
                    .exit_code = 0,
                };
            }
            if (std.mem.eql(u8, argv[2], "--abbrev-ref")) {
                return .{
                    .stdout = try allocator.dupe(u8, "main\n"),
                    .stderr = try allocator.alloc(u8, 0),
                    .exit_code = 0,
                };
            }
            return .{
                .stdout = try allocator.dupe(u8, " M src/app.zig\n?? temp.txt\n"),
                .stderr = try allocator.alloc(u8, 0),
                .exit_code = 0,
            };
        }
    };

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 16);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const workspace_root = try std.fs.path.join(std.testing.allocator, &.{ root_path, "workspaces" });
    defer std.testing.allocator.free(workspace_root);

    const runtime = try ProjectRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .current_dir = root_path,
        .workspace_root = workspace_root,
        .vcs_executor = .{ .ptr = undefined, .run_fn = MockGit.run },
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    var project = try runtime.currentProject(std.testing.allocator);
    defer project.deinit(std.testing.allocator);
    try std.testing.expect(project.vcs.available);
    try std.testing.expectEqualStrings("main", project.vcs.branch.?);
    try std.testing.expect(project.vcs.dirty);
    try std.testing.expectEqual(@as(u32, 2), project.vcs.changed_file_count);
}

test "project runtime workspace lifecycle create list remove works" {
    var memory_sink = framework.MemorySink.init(std.testing.allocator, 16);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const workspace_root = try std.fs.path.join(std.testing.allocator, &.{ root_path, "workspaces" });
    defer std.testing.allocator.free(workspace_root);

    const runtime = try ProjectRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .current_dir = root_path,
        .workspace_root = workspace_root,
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    var created = try runtime.createWorkspace(std.testing.allocator, .{ .name = "demo" });
    defer created.deinit(std.testing.allocator);

    const listed = try runtime.listWorkspaces(std.testing.allocator);
    defer types.freeWorkspaces(std.testing.allocator, listed);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqualStrings("demo", listed[0].name);

    try std.testing.expect(try runtime.removeWorkspace(created.id));
    const listed_after = try runtime.listWorkspaces(std.testing.allocator);
    defer types.freeWorkspaces(std.testing.allocator, listed_after);
    try std.testing.expectEqual(@as(usize, 0), listed_after.len);
}
