const std = @import("std");
const builtin = @import("builtin");
const framework = @import("framework");
const backend = @import("backend.zig");
const types = @import("types.zig");

pub const PTY_OUTPUT_EVENT_TOPIC = "pty.output";
pub const PTY_STATUS_EVENT_TOPIC = "pty.status";

pub const CreateRequest = struct {
    cwd: []const u8,
    shell: ?[]const u8 = null,
};

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    workspace_dir: []const u8,
    backend_factory: ?backend.BackendFactory = null,
};

pub const PtyRuntime = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    workspace_dir: []u8,
    backend_factory: backend.BackendFactory,
    entries: std.ArrayListUnmanaged(*Record) = .empty,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const Record = struct {
        info: types.PtyInfo,
        handle: ?backend.PtyHandle = null,
        chunks: std.ArrayListUnmanaged(types.OutputChunk) = .empty,
        next_seq: u64 = 1,
        condition: std.Io.Condition = .init,
        removed: bool = false,

        fn deinit(self: *Record, allocator: std.mem.Allocator) void {
            if (self.handle) |handle| handle.deinit(allocator);
            for (self.chunks.items) |*chunk| chunk.deinit(allocator);
            self.chunks.deinit(allocator);
            self.info.deinit(allocator);
        }
    };

    pub fn init(deps: Dependencies) !*Self {
        const self = try deps.allocator.create(Self);
        errdefer deps.allocator.destroy(self);
        self.* = .{
            .allocator = deps.allocator,
            .logger = deps.logger,
            .event_bus = deps.event_bus,
            .workspace_dir = try deps.allocator.dupe(u8, deps.workspace_dir),
            .backend_factory = deps.backend_factory orelse backend.defaultFactory(),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
        self.backend_factory.deinit(self.allocator);
        self.allocator.free(self.workspace_dir);
    }

    pub fn create(self: *Self, request: CreateRequest) !types.PtyInfo {
        const pty_id = try nextPtyId(self.allocator);
        errdefer self.allocator.free(pty_id);
        const cwd = try self.allocator.dupe(u8, request.cwd);
        errdefer self.allocator.free(cwd);
        const shell_name = try self.allocator.dupe(u8, request.shell orelse defaultShellName());
        errdefer self.allocator.free(shell_name);
        const now = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds();

        const record = try self.allocator.create(Record);
        errdefer self.allocator.destroy(record);
        record.* = .{
            .info = .{
                .id = pty_id,
                .cwd = .{ .path = cwd },
                .shell = shell_name,
                .status = .running,
                .created_at_ms = now,
                .updated_at_ms = now,
            },
        };
        errdefer record.info.deinit(self.allocator);

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        try self.entries.append(self.allocator, record);
        self.mutex.unlock();

        const sink = backend.OutputSink{
            .ptr = @ptrCast(self),
            .on_output = onOutputThunk,
            .on_exit = onExitThunk,
        };

        const handle = self.backend_factory.spawn(self.allocator, .{
            .pty_id = record.info.id,
            .cwd = record.info.cwd,
            .shell = request.shell,
        }, sink) catch |err| {
            while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
            record.info.status = .failed;
            record.info.updated_at_ms = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds();
            record.info.exit_code = 1;
            self.mutex.unlock();
            try self.publishStatus(record.info.id, .failed, 1);
            return err;
        };

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        record.handle = handle;
        self.mutex.unlock();
        try self.publishStatus(record.info.id, .running, null);
        return try record.info.clone(self.allocator);
    }

    pub fn get(self: *Self, allocator: std.mem.Allocator, pty_id: []const u8) !?types.PtyInfo {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        const record = self.findRecordLocked(pty_id) orelse return null;
        if (record.removed) return null;
        return try record.info.clone(allocator);
    }

    pub fn list(self: *Self, allocator: std.mem.Allocator) ![]types.PtyInfo {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        var count: usize = 0;
        for (self.entries.items) |record| {
            if (!record.removed) count += 1;
        }
        const items = try allocator.alloc(types.PtyInfo, count);
        errdefer allocator.free(items);

        var index: usize = 0;
        for (self.entries.items) |record| {
            if (record.removed) continue;
            items[index] = try record.info.clone(allocator);
            index += 1;
        }
        return items;
    }

    pub fn remove(self: *Self, pty_id: []const u8) !bool {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        const record = self.findRecordLocked(pty_id) orelse {
            self.mutex.unlock();
            return false;
        };
        if (record.removed) {
            self.mutex.unlock();
            return false;
        }
        record.removed = true;
        const handle = record.handle;
        record.handle = null;
        record.condition.broadcast(std.Io.Threaded.global_single_threaded.*.io());
        self.mutex.unlock();

        if (handle) |item| item.deinit(self.allocator);
        return true;
    }

    pub fn writeInput(self: *Self, pty_id: []const u8, data: []const u8) !bool {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        const record = self.findRecordLocked(pty_id) orelse {
            self.mutex.unlock();
            return false;
        };
        if (record.removed or record.handle == null) {
            self.mutex.unlock();
            return false;
        }
        const handle = record.handle.?;
        self.mutex.unlock();
        try handle.writeInput(data);
        return true;
    }

    pub fn readOutput(self: *Self, allocator: std.mem.Allocator, pty_id: []const u8, after_seq: u64, limit: usize, follow_ms: u64) ![]types.OutputChunk {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const record = self.findRecordLocked(pty_id) orelse return allocator.alloc(types.OutputChunk, 0);
        const started_at = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds();

        while (true) {
            var available: usize = 0;
            for (record.chunks.items) |chunk| {
                if (chunk.seq > after_seq) available += 1;
            }
            if (available > 0 or follow_ms == 0 or record.removed or record.info.status != .running) break;

            const elapsed_ms: u64 = @intCast(@max(std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds() - started_at, 0));
            if (elapsed_ms >= follow_ms) break;
            const wait_ms = follow_ms - elapsed_ms;
            recordnull catch break;
        }

        var count: usize = 0;
        for (record.chunks.items) |chunk| {
            if (chunk.seq > after_seq) count += 1;
        }
        if (limit != 0 and count > limit) count = limit;

        const items = try allocator.alloc(types.OutputChunk, count);
        errdefer allocator.free(items);

        var index: usize = 0;
        for (record.chunks.items) |chunk| {
            if (chunk.seq <= after_seq) continue;
            if (limit != 0 and index >= limit) break;
            items[index] = try chunk.clone(allocator);
            index += 1;
        }
        return items;
    }

    fn onOutput(self: *Self, pty_id: []const u8, stream: types.StreamKind, data: []const u8) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        const record = self.findRecordLocked(pty_id) orelse return;
        if (record.removed) return;

        try record.chunks.append(self.allocator, .{
            .seq = record.next_seq,
            .pty_id = try self.allocator.dupe(u8, pty_id),
            .stream = stream,
            .data = try self.allocator.dupe(u8, data),
            .ts_unix_ms = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds(),
        });
        record.next_seq += 1;
        record.info.updated_at_ms = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds();
        record.condition.broadcast(std.Io.Threaded.global_single_threaded.*.io());
    }

    fn onExit(self: *Self, pty_id: []const u8, exit_code: i32) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        const record = self.findRecordLocked(pty_id) orelse return;
        record.info.status = .exited;
        record.info.exit_code = exit_code;
        record.info.updated_at_ms = std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds();
        record.condition.broadcast(std.Io.Threaded.global_single_threaded.*.io());
    }

    fn publishStatus(self: *Self, pty_id: []const u8, status: types.StatusKind, exit_code: ?i32) !void {
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(self.allocator);
            try out.appendSlice(allocator, "{\"pty_id\":");
        try out.print(allocator, "{f}", .{std.json.fmt(pty_id, .{})});
        try out.appendSlice(allocator, ",\"status\":");
        try out.print(allocator, "{f}", .{std.json.fmt(status.asText(), .{})});
        try out.appendSlice(allocator, ",\"exit_code\":");
        if (exit_code) |code| {
            try out.print(allocator, "{d}", .{code});
        } else {
            try out.appendSlice(allocator, "null");
        }
        try out.append(allocator, '}');
        const payload = try self.allocator.dupe(u8, out.items);
        defer self.allocator.free(payload);
        _ = try self.event_bus.publish(PTY_STATUS_EVENT_TOPIC, payload);
    }

    fn findRecordLocked(self: *Self, pty_id: []const u8) ?*Record {
        for (self.entries.items) |record| {
            if (std.mem.eql(u8, record.info.id, pty_id)) return record;
        }
        return null;
    }

    fn onOutputThunk(ptr: *anyopaque, pty_id: []const u8, stream: types.StreamKind, data: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.onOutput(pty_id, stream, data);
    }

    fn onExitThunk(ptr: *anyopaque, pty_id: []const u8, exit_code: i32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.onExit(pty_id, exit_code);
    }
};

fn nextPtyId(allocator: std.mem.Allocator) ![]u8 {
    return std.fmt.allocPrint(allocator, "pty_{d}_{d}", .{ std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds(), 0 });
}

fn defaultShellName() []const u8 {
    return if (builtin.os.tag == .windows) "cmd" else "sh";
}

test "pty runtime lifecycle create get list remove works" {
    const MockFactory = struct {
        const MockHandle = struct {
            const vtable = backend.PtyHandle.VTable{
                .write_input = writeInputErased,
                .close = closeErased,
                .deinit = deinitErased,
            };

            fn asHandle(self: *@This()) backend.PtyHandle {
                return .{ .ptr = @ptrCast(self), .vtable = &vtable };
            }
            fn writeInputErased(_: *anyopaque, _: []const u8) anyerror!void {}
            fn closeErased(_: *anyopaque) void {}
            fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                allocator.destroy(self);
            }
        };

        fn spawn(_: *anyopaque, allocator: std.mem.Allocator, request: backend.SpawnRequest, _: backend.OutputSink) anyerror!backend.PtyHandle {
            _ = request;
            const handle = try allocator.create(MockHandle);
            handle.* = .{};
            return handle.asHandle();
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 16);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    const runtime = try PtyRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
        .workspace_dir = ".",
        .backend_factory = .{
            .ptr = undefined,
            .spawn_fn = MockFactory.spawn,
            .deinit_fn = MockFactory.deinit,
        },
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    var created = try runtime.create(.{ .cwd = "." });
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(types.StatusKind.running, created.status);

    var loaded = (try runtime.get(std.testing.allocator, created.id)).?;
    defer loaded.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(created.id, loaded.id);

    const items = try runtime.list(std.testing.allocator);
    defer types.freeInfos(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);

    try std.testing.expect(try runtime.remove(created.id));
    try std.testing.expect((try runtime.get(std.testing.allocator, created.id)) == null);
}

test "pty runtime interactive shell data flow works with mock backend" {
    const MockFactory = struct {
        const State = struct {
            sink: ?backend.OutputSink = null,
            pty_id: ?[]const u8 = null,
        };

        const MockHandle = struct {
            allocator: std.mem.Allocator,
            state: *State,
            const vtable = backend.PtyHandle.VTable{
                .write_input = writeInputErased,
                .close = closeErased,
                .deinit = deinitErased,
            };
            fn asHandle(self: *@This()) backend.PtyHandle {
                return .{ .ptr = @ptrCast(self), .vtable = &vtable };
            }
            fn writeInputErased(ptr: *anyopaque, data: []const u8) anyerror!void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                try self.state.sink.?.onOutput(self.state.pty_id.?, .stdout, data);
            }
            fn closeErased(ptr: *anyopaque) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                self.state.sink.?.onExit(self.state.pty_id.?, 0) catch {};
            }
            fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                allocator.destroy(self);
            }
        };

        fn spawn(ptr: *anyopaque, allocator: std.mem.Allocator, request: backend.SpawnRequest, sink: backend.OutputSink) anyerror!backend.PtyHandle {
            const state: *State = @ptrCast(@alignCast(ptr));
            state.sink = sink;
            state.pty_id = request.pty_id;
            const handle = try allocator.create(MockHandle);
            handle.* = .{ .allocator = allocator, .state = state };
            return handle.asHandle();
        }
        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var state = MockFactory.State{};
    var memory_sink = framework.MemorySink.init(std.testing.allocator, 16);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    const runtime = try PtyRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
        .workspace_dir = ".",
        .backend_factory = .{
            .ptr = @ptrCast(&state),
            .spawn_fn = MockFactory.spawn,
            .deinit_fn = MockFactory.deinit,
        },
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    var created = try runtime.create(.{ .cwd = "." });
    defer created.deinit(std.testing.allocator);

    try std.testing.expect(try runtime.writeInput(created.id, "echo hello\n"));
    const chunks = try runtime.readOutput(std.testing.allocator, created.id, 0, 16, 0);
    defer types.freeChunks(std.testing.allocator, chunks);
    try std.testing.expectEqual(@as(usize, 1), chunks.len);
    try std.testing.expectEqualStrings("echo hello\n", chunks[0].data);
}
