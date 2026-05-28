const std = @import("std");
const types = @import("types.zig");
const provider = @import("../provider/root.zig");

pub const LoopStateStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        put: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, state: types.LoopState) anyerror!void,
        get: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, loop_id: []const u8) anyerror!?types.LoopState,
        list_active: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.LoopState,
    };

    pub fn put(self: LoopStateStore, allocator: std.mem.Allocator, state: types.LoopState) anyerror!void {
        return self.vtable.put(self.ptr, allocator, state);
    }

    pub fn get(self: LoopStateStore, allocator: std.mem.Allocator, loop_id: []const u8) anyerror!?types.LoopState {
        return self.vtable.get(self.ptr, allocator, loop_id);
    }

    pub fn listActive(self: LoopStateStore, allocator: std.mem.Allocator) anyerror![]types.LoopState {
        return self.vtable.list_active(self.ptr, allocator);
    }
};

pub const FileLoopStateStore = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const vtable = LoopStateStore.VTable{
        .put = putErased,
        .get = getErased,
        .list_active = listActiveErased,
    };

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

    pub fn asLoopStateStore(self: *Self) LoopStateStore {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn put(self: *Self, allocator: std.mem.Allocator, state: types.LoopState) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const path = try self.statePath(allocator, state.loop_id);
        defer allocator.free(path);
        try writeJsonFile(self.allocator, path, toJson(state));
    }

    pub fn get(self: *Self, allocator: std.mem.Allocator, loop_id: []const u8) !?types.LoopState {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const path = try self.statePath(allocator, loop_id);
        defer allocator.free(path);
        const contents = std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), path, allocator, .limited(max_file_bytes)) catch |err| switch (err) {
            error.FileNotFound => return null,
            else => return err,
        };
        defer allocator.free(contents);

        const parsed = try std.json.parseFromSlice(LoopStateJson, allocator, contents, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();
        return try fromJson(allocator, parsed.value);
    }

    pub fn listActive(self: *Self, allocator: std.mem.Allocator) ![]types.LoopState {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const io = std.Io.Threaded.global_single_threaded.*.io();
        var dir = std.Io.Dir.cwd().openDir(io, self.root_path, .{ .iterate = true }) catch |err| switch (err) {
            error.FileNotFound => return allocator.alloc(types.LoopState, 0),
            else => return err,
        };
        defer dir.close(io);

        var results: std.ArrayListUnmanaged(types.LoopState) = .empty;
        errdefer {
            for (results.items) |*item| item.deinit(allocator);
            results.deinit(allocator);
        }

        var iterator = dir.iterate();
        while (try iterator.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;

            const path = try std.fs.path.join(allocator, &.{ self.root_path, entry.name });
            defer allocator.free(path);
            const contents = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_file_bytes));
            defer allocator.free(contents);

            const parsed = try std.json.parseFromSlice(LoopStateJson, allocator, contents, .{
                .ignore_unknown_fields = true,
            });
            defer parsed.deinit();
            const loaded = try fromJson(allocator, parsed.value);
            if (loaded.active) {
                try results.append(allocator, loaded);
            } else {
                var inactive = loaded;
                inactive.deinit(allocator);
            }
        }

        return try results.toOwnedSlice(allocator);
    }

    fn statePath(self: *Self, allocator: std.mem.Allocator, loop_id: []const u8) ![]u8 {
        const file_name = try std.fmt.allocPrint(allocator, "{s}.json", .{loop_id});
        defer allocator.free(file_name);
        return std.fs.path.join(allocator, &.{ self.root_path, file_name });
    }

    fn putErased(ptr: *anyopaque, allocator: std.mem.Allocator, state: types.LoopState) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.put(allocator, state);
    }

    fn getErased(ptr: *anyopaque, allocator: std.mem.Allocator, loop_id: []const u8) anyerror!?types.LoopState {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.get(allocator, loop_id);
    }

    fn listActiveErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.LoopState {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.listActive(allocator);
    }
};

const LoopStateJson = struct {
    loop_id: []const u8,
    root_session_id: []const u8,
    current_session_id: []const u8,
    agent_id: ?[]const u8 = null,
    category: ?[]const u8 = null,
    model_provider_id: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    continuation_prompt: []const u8,
    completion_signal: []const u8,
    strategy: []const u8,
    iteration: u32,
    max_iterations: ?u32 = null,
    active: bool,
    phase: []const u8,
    ultrawork: bool,
    verification_pending: bool,
    verification_signal: []const u8,
    oracle_profile_id: []const u8,
    verification_session_id: ?[]const u8 = null,
    verification_attempt_id: ?[]const u8 = null,
    started_at_ms: i64,
    updated_at_ms: i64,
};

fn toJson(state: types.LoopState) LoopStateJson {
    return .{
        .loop_id = state.loop_id,
        .root_session_id = state.root_session_id,
        .current_session_id = state.current_session_id,
        .agent_id = state.agent_id,
        .category = state.category,
        .model_provider_id = if (state.model) |model| model.provider_id else null,
        .model_id = if (state.model) |model| model.model_id else null,
        .continuation_prompt = state.continuation_prompt,
        .completion_signal = state.completion_signal,
        .strategy = state.strategy.asText(),
        .iteration = state.iteration,
        .max_iterations = state.max_iterations,
        .active = state.active,
        .phase = state.phase.asText(),
        .ultrawork = state.ultrawork,
        .verification_pending = state.verification_pending,
        .verification_signal = state.verification_signal,
        .oracle_profile_id = state.oracle_profile_id,
        .verification_session_id = state.verification_session_id,
        .verification_attempt_id = state.verification_attempt_id,
        .started_at_ms = state.started_at_ms,
        .updated_at_ms = state.updated_at_ms,
    };
}

fn fromJson(allocator: std.mem.Allocator, value: LoopStateJson) !types.LoopState {
    return .{
        .loop_id = try allocator.dupe(u8, value.loop_id),
        .root_session_id = try allocator.dupe(u8, value.root_session_id),
        .current_session_id = try allocator.dupe(u8, value.current_session_id),
        .agent_id = if (value.agent_id) |item| try allocator.dupe(u8, item) else null,
        .category = if (value.category) |item| try allocator.dupe(u8, item) else null,
        .model = if (value.model_provider_id != null and value.model_id != null) provider.ModelRef{
            .provider_id = try allocator.dupe(u8, value.model_provider_id.?),
            .model_id = try allocator.dupe(u8, value.model_id.?),
        } else null,
        .continuation_prompt = try allocator.dupe(u8, value.continuation_prompt),
        .completion_signal = try allocator.dupe(u8, value.completion_signal),
        .strategy = types.LoopStrategy.fromText(value.strategy) orelse return error.InvalidLoopStrategy,
        .iteration = value.iteration,
        .max_iterations = value.max_iterations,
        .active = value.active,
        .phase = types.LoopPhase.fromText(value.phase) orelse return error.InvalidLoopPhase,
        .ultrawork = value.ultrawork,
        .verification_pending = value.verification_pending,
        .verification_signal = try allocator.dupe(u8, value.verification_signal),
        .oracle_profile_id = try allocator.dupe(u8, value.oracle_profile_id),
        .verification_session_id = if (value.verification_session_id) |item| try allocator.dupe(u8, item) else null,
        .verification_attempt_id = if (value.verification_attempt_id) |item| try allocator.dupe(u8, item) else null,
        .started_at_ms = value.started_at_ms,
        .updated_at_ms = value.updated_at_ms,
    };
}

fn writeJsonFile(allocator: std.mem.Allocator, path: []const u8, value: anytype) !void {
    var rendered: std.ArrayListUnmanaged(u8) = .empty;
    defer rendered.deinit(allocator);

    try rendered.print(allocator, "{f}", .{std.json.fmt(value, .{})});

    if (std.fs.path.dirname(path)) |dir_name| {
        _ = std.c.mkdir(@ptrCast(dir_name.ptr), 0o755);
    }
    const io = std.Io.Threaded.global_single_threaded.*.io();
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
    defer file.close(io);
    try file.writeStreamingAll(io, rendered.items);
}

const max_file_bytes = 1024 * 1024;

test "file loop state store persists and reloads active loops" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try std.testing.allocator.dupe(u8, ".");
    defer std.testing.allocator.free(root_path);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "loops" });
    defer std.testing.allocator.free(store_path);

    {
        var store = try FileLoopStateStore.init(std.testing.allocator, store_path);
        defer store.deinit();

        var state = types.LoopState{
            .loop_id = try std.testing.allocator.dupe(u8, "loop_01"),
            .root_session_id = try std.testing.allocator.dupe(u8, "session_root"),
            .current_session_id = try std.testing.allocator.dupe(u8, "session_current"),
            .continuation_prompt = try std.testing.allocator.dupe(u8, "continue"),
            .completion_signal = try std.testing.allocator.dupe(u8, "DONE"),
            .strategy = .continue_same_session,
            .iteration = 1,
            .active = true,
            .phase = .running,
            .ultrawork = false,
            .verification_pending = false,
            .verification_signal = try std.testing.allocator.dupe(u8, "VERIFIED"),
            .oracle_profile_id = try std.testing.allocator.dupe(u8, "oracle"),
            .started_at_ms = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds(),
            .updated_at_ms = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds(),
        };
        defer state.deinit(std.testing.allocator);

        try store.put(std.testing.allocator, state);

        var loaded = (try store.get(std.testing.allocator, "loop_01")).?;
        defer loaded.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("session_current", loaded.current_session_id);
    }

    var reopened = try FileLoopStateStore.init(std.testing.allocator, store_path);
    defer reopened.deinit();
    const active = try reopened.listActive(std.testing.allocator);
    defer {
        for (active) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(active);
    }
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqualStrings("loop_01", active[0].loop_id);
}
