const std = @import("std");

pub fn writeMessage(file: std.Io.File, io: std.Io, json_text: []const u8) !void {
    const header = try std.fmt.allocPrint(std.heap.page_allocator, "Content-Length: {d}\r\n\r\n", .{json_text.len});
    defer std.heap.page_allocator.free(header);
    try file.writeStreamingAll(io, header);
    try file.writeStreamingAll(io, json_text);
}

pub fn readMessageAlloc(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io) ![]u8 {
    var content_length: ?usize = null;
    while (true) {
        const line = try readLineAlloc(allocator, file, io);
        defer allocator.free(line);
        if (line.len == 0) break;
        if (std.mem.startsWith(u8, line, "Content-Length:")) {
            const raw_value = std.mem.trim(u8, line["Content-Length:".len..], " ");
            content_length = try std.fmt.parseInt(usize, raw_value, 10);
        }
    }

    const body_len = content_length orelse return error.MissingContentLength;
    const body = try allocator.alloc(u8, body_len);
    errdefer allocator.free(body);

    var read_index: usize = 0;
    while (read_index < body.len) {
        const amount = try file.readStreaming(io, &.{body[read_index..]});
        if (amount == 0) return error.EndOfStream;
        read_index += amount;
    }
    return body;
}

fn readLineAlloc(allocator: std.mem.Allocator, file: std.Io.File, io: std.Io) ![]u8 {
    var line: std.ArrayListUnmanaged(u8) = .empty;
    errdefer line.deinit(allocator);

    while (true) {
        var buf: [1]u8 = undefined;
        const amount = try file.readStreaming(io, &.{&buf});
        if (amount == 0) {
            if (line.items.len == 0) return error.EndOfStream;
            break;
        }
        const byte = buf[0];
        if (byte == '\n') break;
        if (byte == '\r') continue;
        try line.append(allocator, byte);
    }
    return try line.toOwnedSlice(allocator);
}

test "protocol writes and reads content-length framed messages" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try std.testing.allocator.dupe(u8, ".");
    defer std.testing.allocator.free(path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ path, "protocol.txt" });
    defer std.testing.allocator.free(file_path);

    {
        var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), file_path, .{ .truncate = true });
        defer file.close(std.Io.Threaded.global_single_threaded.*.io());
        try writeMessage(file, "{\"jsonrpc\":\"2.0\"}");
    }

    var file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.*.io(), file_path, .{ .mode = .read_only });
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    const body = try readMessageAlloc(std.testing.allocator, file);
    defer std.testing.allocator.free(body);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\"}", body);
}
