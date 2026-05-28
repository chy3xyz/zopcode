const std = @import("std");
const framework = @import("framework");
const schema = @import("schema.zig");

pub const SnapshotRecord = struct {
    id: schema.SnapshotId,
    session_id: schema.SessionId,
    path: []const u8,
    existed_before: bool,
    created_at_ms: i64,
    content_rel_path: ?[]const u8 = null,

    pub fn deinit(self: *SnapshotRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        allocator.free(self.path);
        if (self.content_rel_path) |value| allocator.free(value);
    }
};

pub const RevertResult = struct {
    restored_count: u32,
    restored_paths: [][]const u8,

    pub fn deinit(self: *RevertResult, allocator: std.mem.Allocator) void {
        for (self.restored_paths) |path| allocator.free(path);
        allocator.free(self.restored_paths);
    }
};

pub const FileSnapshotStore = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, root_path: []const u8) !Self {
        _ = std.c.mkdir(@ptrCast(root_path.ptr), 0o755);
        return .{
            .allocator = allocator,
            .root_path = try allocator.dupe(u8, root_path),
        };
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.root_path);
    }

    pub fn recordBeforeMutation(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId, path: []const u8) !SnapshotRecord {
        const snapshot_id = try schema.nextSnapshotId(allocator);
        errdefer allocator.free(snapshot_id);
        const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds();

        const session_dir = try self.sessionDirPath(allocator, session_id);
        defer allocator.free(session_dir);
        _ = std.c.mkdir(@ptrCast(session_dir.ptr), 0o755);

        const contents = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => return err,
        };
        defer if (contents) |value| allocator.free(value);

        const content_rel_path = if (contents != null)
            try std.fmt.allocPrint(allocator, "{s}.bin", .{snapshot_id})
        else
            null;
        defer if (content_rel_path) |value| allocator.free(value);

        if (contents) |bytes| {
            const content_path = try std.fs.path.join(allocator, &.{ session_dir, content_rel_path.? });
            defer allocator.free(content_path);
            var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), content_path, .{ .truncate = true });
            defer file.close(std.Io.Threaded.global_single_threaded.*.io());
            try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), bytes);
        }

        const record = SnapshotRecord{
            .id = snapshot_id,
            .session_id = try allocator.dupe(u8, session_id),
            .path = try allocator.dupe(u8, path),
            .existed_before = contents != null,
            .created_at_ms = now,
            .content_rel_path = if (content_rel_path) |value| try allocator.dupe(u8, value) else null,
        };
        errdefer {
            var owned = record;
            owned.deinit(allocator);
        }

        const meta_path = try self.metaPath(allocator, session_id, snapshot_id);
        defer allocator.free(meta_path);
        try writeJsonFile(allocator, meta_path, snapshotRecordToJson(record));
        return record;
    }

    pub fn listSession(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) ![]SnapshotRecord {
        const session_dir = try self.sessionDirPath(allocator, session_id);
        defer allocator.free(session_dir);

        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.*.io(), session_dir, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc(SnapshotRecord, 0),
            else => return err,
        };
        defer dir.close(std.Io.Threaded.global_single_threaded.*.io());

        var items: std.ArrayListUnmanaged(SnapshotRecord) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        var iterator = dir.iterate();
        while (try iterator.next(std.Io.Threaded.global_single_threaded.*.io())) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            const full_path = try std.fs.path.join(allocator, &.{ session_dir, entry.name });
            defer allocator.free(full_path);
            const contents = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), full_path, allocator, .limited(max_file_bytes));
            defer allocator.free(contents);
            const parsed = try std.json.parseFromSlice(SnapshotRecordJson, allocator, contents, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            try items.append(allocator, try snapshotRecordFromJson(allocator, parsed.value));
        }

        std.sort.block(SnapshotRecord, items.items, {}, struct {
            fn lessThan(_: void, lhs: SnapshotRecord, rhs: SnapshotRecord) bool {
                return lhs.created_at_ms > rhs.created_at_ms;
            }
        }.lessThan);

        return try items.toOwnedSlice(allocator);
    }

    fn sessionDirPath(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId) ![]u8 {
        return std.fs.path.join(allocator, &.{ self.root_path, session_id });
    }

    fn metaPath(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId, snapshot_id: schema.SnapshotId) ![]u8 {
        const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{snapshot_id});
        defer allocator.free(file_name);
        return std.fs.path.join(allocator, &.{ self.root_path, session_id, file_name });
    }
};

pub const SnapshotService = struct {
    allocator: std.mem.Allocator,
    logger: ?*framework.Logger,
    store: *FileSnapshotStore,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, logger: ?*framework.Logger, store: *FileSnapshotStore) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
            .store = store,
        };
    }

    pub fn recordFileBeforeMutation(self: *Self, session_id: ?schema.SessionId, path: []const u8) !void {
        const owned_session_id = session_id orelse return;
        var record = try self.store.recordBeforeMutation(self.allocator, owned_session_id, path);
        defer record.deinit(self.allocator);
        if (self.logger) |logger| {
            logger.child("session").child("snapshot").info("snapshot recorded", &.{
                framework.LogField.string("session_id", owned_session_id),
                framework.LogField.string("path", path),
                framework.LogField.boolean("existed_before", record.existed_before),
            });
        }
    }

    pub fn revertLatest(self: *Self, allocator: std.mem.Allocator, session_id: schema.SessionId, paths: []const []const u8) !RevertResult {
        const records = try self.store.listSession(allocator, session_id);
        defer {
            for (records) |*record| record.deinit(allocator);
            allocator.free(records);
        }

        var restored_paths: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (restored_paths.items) |path| allocator.free(path);
            restored_paths.deinit(allocator);
        }

        for (paths) |path| {
            const match = findLatestForPath(records, path) orelse continue;
            try restoreRecord(allocator, self.store.root_path, match);
            try restored_paths.append(allocator, try allocator.dupe(u8, path));
        }

        if (self.logger) |logger| {
            logger.child("session").child("snapshot").info("snapshot revert applied", &.{
                framework.LogField.string("session_id", session_id),
                framework.LogField.int("restored_count", @intCast(restored_paths.items.len)),
            });
        }

        return .{
            .restored_count = @intCast(restored_paths.items.len),
            .restored_paths = try restored_paths.toOwnedSlice(allocator),
        };
    }
};

fn findLatestForPath(records: []const SnapshotRecord, path: []const u8) ?SnapshotRecord {
    for (records) |record| {
        if (std.mem.eql(u8, record.path, path)) return record;
    }
    return null;
}

fn restoreRecord(allocator: std.mem.Allocator, root_path: []const u8, record: SnapshotRecord) !void {
    if (!record.existed_before) {
        std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.*.io(), record.path) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
        return;
    }

    const session_dir = try std.fs.path.join(allocator, &.{ root_path, record.session_id });
    defer allocator.free(session_dir);
    const content_path = try std.fs.path.join(allocator, &.{ session_dir, record.content_rel_path.? });
    defer allocator.free(content_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), content_path, allocator, .limited(max_file_bytes));
    defer allocator.free(content);

    if (std.fs.path.dirname(record.path)) |dir_name| _ = std.c.mkdir(@ptrCast(dir_name.ptr), 0o755);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), record.path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), content);
}

const SnapshotRecordJson = struct {
    id: []const u8,
    session_id: []const u8,
    path: []const u8,
    existed_before: bool,
    created_at_ms: i64,
    content_rel_path: ?[]const u8 = null,
};

fn snapshotRecordToJson(record: SnapshotRecord) SnapshotRecordJson {
    return .{
        .id = record.id,
        .session_id = record.session_id,
        .path = record.path,
        .existed_before = record.existed_before,
        .created_at_ms = record.created_at_ms,
        .content_rel_path = record.content_rel_path,
    };
}

fn snapshotRecordFromJson(allocator: std.mem.Allocator, value: SnapshotRecordJson) !SnapshotRecord {
    return .{
        .id = try allocator.dupe(u8, value.id),
        .session_id = try allocator.dupe(u8, value.session_id),
        .path = try allocator.dupe(u8, value.path),
        .existed_before = value.existed_before,
        .created_at_ms = value.created_at_ms,
        .content_rel_path = if (value.content_rel_path) |item| try allocator.dupe(u8, item) else null,
    };
}

fn writeJsonFile(allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    defer rendered.deinit(allocator);
    try rendered.print(allocator, "{f}", .{std.json.fmt(value, .{})});

    if (std.fs.path.dirname(path)) |dir_name| _ = std.c.mkdir(@ptrCast(dir_name.ptr), 0o755);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), rendered.items);
}

const max_file_bytes = 4 * 1024 * 1024;

test "snapshot service records and reverts tracked files" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try std.testing.allocator.dupe(u8, ".");
    defer std.testing.allocator.free(root_path);
    const snapshot_root = try std.fs.path.join(std.testing.allocator, &.{ root_path, "snapshots" });
    defer std.testing.allocator.free(snapshot_root);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sample.txt" });
    defer std.testing.allocator.free(target_path);

    {
        var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), target_path, .{ .truncate = true });
        defer file.close(std.Io.Threaded.global_single_threaded.*.io());
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "before");
    }

    var store = try FileSnapshotStore.init(std.testing.allocator, snapshot_root);
    defer store.deinit();
    var service = SnapshotService.init(std.testing.allocator, null, &store);

    try service.recordFileBeforeMutation("session_01", target_path);
    {
        var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), target_path, .{ .truncate = true });
        defer file.close(std.Io.Threaded.global_single_threaded.*.io());
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "after");
    }

    var result = try service.revertLatest(std.testing.allocator, "session_01", &.{target_path});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), result.restored_count);

    const reverted = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), std.testing.allocator, target_path, .limited(1024));
    defer std.testing.allocator.free(reverted);
    try std.testing.expectEqualStrings("before", reverted);
}
