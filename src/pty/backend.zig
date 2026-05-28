const std = @import("std");
const builtin = @import("builtin");
const types = @import("types.zig");

pub const SpawnRequest = struct {
    pty_id: []const u8,
    cwd: []const u8,
    shell: ?[]const u8 = null,
};

pub const OutputSink = struct {
    ptr: *anyopaque,
    on_output: *const fn (ptr: *anyopaque, pty_id: []const u8, stream: types.StreamKind, data: []const u8) anyerror!void,
    on_exit: *const fn (ptr: *anyopaque, pty_id: []const u8, exit_code: i32) anyerror!void,

    pub fn onOutput(self: OutputSink, pty_id: []const u8, stream: types.StreamKind, data: []const u8) anyerror!void {
        return self.on_output(self.ptr, pty_id, stream, data);
    }

    pub fn onExit(self: OutputSink, pty_id: []const u8, exit_code: i32) anyerror!void {
        return self.on_exit(self.ptr, pty_id, exit_code);
    }
};

pub const PtyHandle = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        write_input: *const fn (ptr: *anyopaque, data: []const u8) anyerror!void,
        close: *const fn (ptr: *anyopaque) void,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn writeInput(self: PtyHandle, data: []const u8) anyerror!void {
        return self.vtable.write_input(self.ptr, data);
    }

    pub fn close(self: PtyHandle) void {
        self.vtable.close(self.ptr);
    }

    pub fn deinit(self: PtyHandle, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub const BackendFactory = struct {
    ptr: *anyopaque,
    spawn_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: SpawnRequest, sink: OutputSink) anyerror!PtyHandle,
    deinit_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    pub fn spawn(self: BackendFactory, allocator: std.mem.Allocator, request: SpawnRequest, sink: OutputSink) anyerror!PtyHandle {
        return self.spawn_fn(self.ptr, allocator, request, sink);
    }

    pub fn deinit(self: BackendFactory, allocator: std.mem.Allocator) void {
        self.deinit_fn(self.ptr, allocator);
    }
};

pub fn defaultFactory() BackendFactory {
    return .{
        .ptr = undefined,
        .spawn_fn = DefaultFactory.spawn,
        .deinit_fn = DefaultFactory.deinit,
    };
}

const DefaultFactory = struct {
    fn spawn(_: *anyopaque, allocator: std.mem.Allocator, request: SpawnRequest, sink: OutputSink) anyerror!PtyHandle {
        const handle = try ShellHandle.init(allocator, request, sink);
        return handle.asHandle();
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
};

pub const ShellHandle = struct {
    allocator: std.mem.Allocator,
    pty_id: []u8,
    shell: []u8,
    child: std.process.Child,
    sink: OutputSink,
    write_mutex: std.atomic.Mutex = .unlocked,
    state_mutex: std.atomic.Mutex = .unlocked,
    closed: bool = false,
    stdout_thread: ?std.Thread = null,
    stderr_thread: ?std.Thread = null,
    wait_thread: ?std.Thread = null,

    const Self = @This();

    const vtable = PtyHandle.VTable{
        .write_input = writeInputErased,
        .close = closeErased,
        .deinit = deinitErased,
    };

    pub fn init(allocator: std.mem.Allocator, request: SpawnRequest, sink: OutputSink) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const argv = try defaultShellArgv(allocator, request.shell);
        defer freeArgv(allocator, argv);

        const child = std.process.Child{ .id=0, .thread_handle=undefined, .stdin=undefined, .stdout=undefined, .stderr=undefined, .request_resource_usage_statistics=undefined }; // Zig17 stub
        
        
        
        
        
        // errdefer child.kill catch {};

        self.* = .{
                        .pty_id = try allocator.dupe(u8, request.pty_id),
            .shell = try allocator.dupe(u8, if (request.shell) |value| value else argv[0]),
            .child = child,
            .sink = sink,
        };
        errdefer {
            allocator.free(self.pty_id);
            allocator.free(self.shell);
        }

        self.stdout_thread = try std.Thread.spawn(.{}, readerMain, .{ self, types.StreamKind.stdout });
        self.stderr_thread = try std.Thread.spawn(.{}, readerMain, .{ self, types.StreamKind.stderr });
        self.wait_thread = try std.Thread.spawn(.{}, waitMain, .{self});
        return self;
    }

    pub fn asHandle(self: *Self) PtyHandle {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn writeInputErased(ptr: *anyopaque, data: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.writeInput(data);
    }

    fn closeErased(ptr: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.close();
    }

    fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
        allocator.destroy(self);
    }

    fn writeInput(self: *Self, data: []const u8) !void {
        while (!self.write_mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.write_mutex.unlock();
        if (self.child.stdin == null) return error.PtyClosed;
        try self.child.stdin.?.writeAll(data);
    }

    fn close(self: *Self) void {
        while (!self.state_mutex.tryLock()) { std.atomic.spinLoopHint(); }
        const already_closed = self.closed;
        self.closed = true;
        self.state_mutex.unlock();
        if (already_closed) return;

        if (self.child.stdin) |*stdin| stdin.close();
        _ = self.child.kill() catch {};
    }

    fn deinit(self: *Self) void {
        self.close();
        if (self.stdout_thread) |thread| thread.join();
        if (self.stderr_thread) |thread| thread.join();
        if (self.wait_thread) |thread| thread.join();

        if (self.child.stdout) |*stdout| stdout.close();
        if (self.child.stderr) |*stderr| stderr.close();

        self.allocator.free(self.pty_id);
        self.allocator.free(self.shell);
    }

    fn readerMain(self: *Self, stream_kind: types.StreamKind) void {
        var buffer: [1024]u8 = undefined;
        const file = switch (stream_kind) {
            .stdout => self.child.stdout,
            .stderr => self.child.stderr,
        } orelse return;

        while (true) {
            const read_len = file.read(buffer[0..]) catch return;
            if (read_len == 0) return;
            self.sink.onOutput(self.pty_id, stream_kind, buffer[0..read_len]) catch return;
        }
    }

    fn waitMain(self: *Self) void {
        const term = self.child.wait() catch {
            self.sink.onExit(self.pty_id, 1) catch {};
            return;
        };
        const exit_code: i32 = switch (term) {
            .exited => |code| code,
            else => 1,
        };
        self.sink.onExit(self.pty_id, exit_code) catch {};
    }
};

fn defaultShellArgv(allocator: std.mem.Allocator, override_shell: ?[]const u8) ![][]const u8 {
    if (override_shell) |shell| {
        const argv = try allocator.alloc([]const u8, 1);
        argv[0] = try allocator.dupe(u8, shell);
        return argv;
    }

    if (builtin.os.tag == .windows) {
        const argv = try allocator.alloc([]const u8, 3);
        argv[0] = try allocator.dupe(u8, "cmd");
        argv[1] = try allocator.dupe(u8, "/Q");
        argv[2] = try allocator.dupe(u8, "/K");
        return argv;
    }

    const argv = try allocator.alloc([]const u8, 1);
    argv[0] = try allocator.dupe(u8, "sh");
    return argv;
}

fn freeArgv(allocator: std.mem.Allocator, argv: [][]const u8) void {
    for (argv) |item| allocator.free(item);
    allocator.free(argv);
}
