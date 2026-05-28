const std = @import("std");

pub const ByteSink = struct {
    ptr: *anyopaque,
    write_all: *const fn (ptr: *anyopaque, bytes: []const u8) anyerror!void,
    flush_fn: *const fn (ptr: *anyopaque) anyerror!void,

    pub fn writeAll(self: ByteSink, bytes: []const u8) anyerror!void {
        try self.write_all(self.ptr, bytes);
    }

    pub fn flush(self: ByteSink) anyerror!void {
        try self.flush_fn(self.ptr);
    }
};

pub const ArrayListSink = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayListUnmanaged(u8) = .empty,
    flush_count: usize = 0,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn asByteSink(self: *Self) ByteSink {
        return .{
            .ptr = @ptrCast(self),
            .write_all = writeAllErased,
            .flush_fn = flushErased,
        };
    }

    pub fn toOwnedSlice(self: *Self) anyerror![]u8 {
        return self.allocator.dupe(u8, self.buffer.items);
    }

    fn writeAllErased(ptr: *anyopaque, bytes: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    fn flushErased(ptr: *anyopaque) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.flush_count += 1;
    }
};

pub fn netStreamSink(stream: *std.Io.net.Stream) ByteSink {
    return .{
        .ptr = @ptrCast(stream),
        .write_all = writeNetStream,
        .flush_fn = flushNetStream,
    };
}

pub fn fileSink(file: *std.Io.File) ByteSink {
    return .{
        .ptr = @ptrCast(file),
        .write_all = writeFile,
        .flush_fn = flushFile,
    };
}

fn writeNetStream(ptr: *anyopaque, bytes: []const u8) anyerror!void {
    const stream: *std.Io.net.Stream = @ptrCast(@alignCast(ptr));
    const io = std.Io.Threaded.global_single_threaded.*.io();
    var buf: [4096]u8 = undefined;
    var w = stream.writer(io, &buf);
    try w.interface.writeAll(bytes);
    try w.interface.flush();
}

fn flushNetStream(_: *anyopaque) anyerror!void {}

fn writeFile(ptr: *anyopaque, bytes: []const u8) anyerror!void {
    const file: *std.Io.File = @ptrCast(@alignCast(ptr));
    const io = std.Io.Threaded.global_single_threaded.*.io();
    try file.writeStreamingAll(io, bytes);
}

fn flushFile(_: *anyopaque) anyerror!void {}

test "array list sink records writes and flushes" {
    var sink = ArrayListSink.init(std.testing.allocator);
    defer sink.deinit();

    const writer = sink.asByteSink();
    try writer.writeAll("hello");
    try writer.flush();

    const output = try sink.toOwnedSlice();
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("hello", output);
    try std.testing.expectEqual(@as(usize, 1), sink.flush_count);
}


