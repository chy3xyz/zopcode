const std = @import("std");
const backend = @import("backend.zig");
const types = @import("types.zig");

pub const State = struct {
    sink: ?backend.OutputSink = null,
    pty_id: ?[]const u8 = null,
};

pub fn factory(state: *State) backend.BackendFactory {
    return .{
        .ptr = @ptrCast(state),
        .spawn_fn = spawn,
        .deinit_fn = deinit,
    };
}

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
    handle.* = .{
                .state = state,
    };
    return handle.asHandle();
}

fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}

test "mock pty backend echoes written input as stdout output" {
    var state = State{};
    const f = factory(&state);
    var saw_output = false;

    const Sink = struct {
        fn onOutput(ptr: *anyopaque, _: []const u8, stream: types.StreamKind, data: []const u8) !void {
            const flag: *bool = @ptrCast(@alignCast(ptr));
            flag.* = stream == .stdout and std.mem.eql(u8, data, "hello");
        }
        fn onExit(_: *anyopaque, _: []const u8, _: i32) !void {}
    };

    const handle = try f.spawn(std.testing.allocator, .{
        .pty_id = "pty_01",
        .cwd = ".",
    }, .{
        .ptr = @ptrCast(&saw_output),
        .on_output = Sink.onOutput,
        .on_exit = Sink.onExit,
    });
    defer handle.deinit(std.testing.allocator);

    try handle.writeInput("hello");
    try std.testing.expect(saw_output);
}
