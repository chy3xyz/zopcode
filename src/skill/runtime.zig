const std = @import("std");
const framework = @import("framework");

pub const SkillInfo = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    summary: []const u8,

    pub fn clone(self: SkillInfo, allocator: std.mem.Allocator) !SkillInfo {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .name = try allocator.dupe(u8, self.name),
            .path = try allocator.dupe(u8, self.path),
            .summary = try allocator.dupe(u8, self.summary),
        };
    }

    pub fn deinit(self: *SkillInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.summary);
    }
};

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    current_dir: []const u8,
};

pub const SkillRuntime = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    directories: [][]const u8,
    skills: []SkillInfo = &.{},

    const Self = @This();

    pub fn init(deps: Dependencies) !*Self {
        const self = try deps.allocator.create(Self);
        errdefer deps.allocator.destroy(self);

        const directories = try deps.allocator.alloc([]const u8, 2);
        errdefer deps.allocator.free(directories);
        directories[0] = try std.fs.path.join(deps.allocator, &.{ deps.current_dir, "skills" });
        directories[1] = try std.fs.path.join(deps.allocator, &.{ deps.current_dir, ".codex", "skills" });

        self.* = .{
            .allocator = deps.allocator,
            .logger = deps.logger,
            .directories = directories,
        };
        try self.refresh();
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.directories) |item| self.allocator.free(item);
        self.allocator.free(self.directories);
        for (self.skills) |*item| item.deinit(self.allocator);
        if (self.skills.len > 0) self.allocator.free(self.skills);
    }

    pub fn refresh(self: *Self) !void {
        for (self.skills) |*item| item.deinit(self.allocator);
        if (self.skills.len > 0) self.allocator.free(self.skills);
        self.skills = try discoverSkills(self.allocator, self.directories);
    }

    pub fn list(self: *Self, allocator: std.mem.Allocator) ![]SkillInfo {
        const items = try allocator.alloc(SkillInfo, self.skills.len);
        errdefer allocator.free(items);
        for (self.skills, 0..) |item, index| {
            items[index] = try item.clone(allocator);
            errdefer items[index].deinit(allocator);
        }
        return items;
    }

    pub fn load(self: *Self, allocator: std.mem.Allocator, skill_id: []const u8) !?[]u8 {
        for (self.skills) |item| {
            if (!std.mem.eql(u8, item.id, skill_id)) continue;
            return try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), item.path, allocator, .limited(1024 * 1024));
        }
        return null;
    }
};

fn discoverSkills(allocator: std.mem.Allocator, directories: [][]const u8) ![]SkillInfo {
    var items: std.ArrayListUnmanaged(SkillInfo) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    for (directories) |dir_path| {
        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.*.io(), dir_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        defer dir.close(std.Io.Threaded.global_single_threaded.*.io());

        var it = dir.iterate();
        while (try it.next(std.Io.Threaded.global_single_threaded.*.io())) |entry| {
            if (entry.kind != .directory) continue;
            const skill_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name, "SKILL.md" });
            defer allocator.free(skill_path);
            const bytes = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), skill_path, allocator, .limited(1024 * 1024)) catch |err| switch (err) {
                error.FileNotFound => continue,
                else => return err,
            };
            defer allocator.free(bytes);
            const parsed = parseSkillMarkdown(bytes);
            try items.append(allocator, .{
                .id = try allocator.dupe(u8, entry.name),
                .name = try allocator.dupe(u8, parsed.name),
                .path = try allocator.dupe(u8, skill_path),
                .summary = try allocator.dupe(u8, parsed.summary),
            });
        }
    }
    return try items.toOwnedSlice(allocator);
}

fn parseSkillMarkdown(text: []const u8) struct { name: []const u8, summary: []const u8 } {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var name: []const u8 = "skill";
    var summary: []const u8 = "";
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "# ")) {
            name = trimmed[2..];
            continue;
        }
        summary = trimmed;
        break;
    }
    return .{ .name = name, .summary = summary };
}

test "skill runtime discovers local skills and can load markdown" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const skill_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "skills", "demo-skill" });
    defer std.testing.allocator.free(skill_dir);
    _ = std.c.mkdir(@ptrCast(skill_dir.ptr), 0o755);
    const skill_path = try std.fs.path.join(std.testing.allocator, &.{ skill_dir, "SKILL.md" });
    defer std.testing.allocator.free(skill_path);
    var file = try std.Io.Dir.cwd().createFile(skill_path, .{ .truncate = true });
    defer file.close();
    try file.writeAll("# Demo Skill\nA sample skill.");

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 16);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    const runtime = try SkillRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .current_dir = root_path,
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    const skills = try runtime.list(std.testing.allocator);
    defer {
        for (skills) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(skills);
    }
    try std.testing.expectEqual(@as(usize, 1), skills.len);
    try std.testing.expectEqualStrings("demo-skill", skills[0].id);

    const loaded = (try runtime.load(std.testing.allocator, "demo-skill")).?;
    defer std.testing.allocator.free(loaded);
    try std.testing.expect(std.mem.indexOf(u8, loaded, "Demo Skill") != null);
}
