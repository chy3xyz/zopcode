const std = @import("std");

pub const SessionId = []const u8;
pub const MessageId = []const u8;
pub const PartId = []const u8;
pub const SnapshotId = []const u8;

var id_mutex: std.atomic.Mutex = .unlocked;
var next_suffix: u64 = 1;

pub fn nextSessionId(allocator: std.mem.Allocator) !SessionId {
    return nextId(allocator, "session");
}

pub fn nextMessageId(allocator: std.mem.Allocator) !MessageId {
    return nextId(allocator, "message");
}

pub fn nextPartId(allocator: std.mem.Allocator) !PartId {
    return nextId(allocator, "part");
}

pub fn nextSnapshotId(allocator: std.mem.Allocator) !SnapshotId {
    return nextId(allocator, "snapshot");
}

fn nextId(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    id_mutex.lock();
    const suffix = next_suffix;
    next_suffix += 1;
    id_mutex.unlock();

    return std.fmt.allocPrint(allocator, "{s}_{d}_{d}", .{
        prefix,
        std.Io.Timestamp.now(std.Io.Threaded.global_single_threaded.*.io(), .real).toMilliseconds(),
        suffix,
    });
}

test "generated ids are prefixed by domain kind" {
    const session_id = try nextSessionId(std.testing.allocator);
    defer std.testing.allocator.free(session_id);

    const message_id = try nextMessageId(std.testing.allocator);
    defer std.testing.allocator.free(message_id);

    const part_id = try nextPartId(std.testing.allocator);
    defer std.testing.allocator.free(part_id);

    try std.testing.expect(std.mem.startsWith(u8, session_id, "session_"));
    try std.testing.expect(std.mem.startsWith(u8, message_id, "message_"));
    try std.testing.expect(std.mem.startsWith(u8, part_id, "part_"));
}
