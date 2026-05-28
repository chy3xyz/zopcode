const std = @import("std");

pub fn isPrivateAddress(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost")) return true;
    if (std.mem.startsWith(u8, host, "127.")) return true;
    if (std.mem.startsWith(u8, host, "10.")) return true;
    if (std.mem.startsWith(u8, host, "192.168.")) return true;
    if (std.mem.startsWith(u8, host, "172.")) {
        const after = host[4..];
        const dot = std.mem.indexOfScalar(u8, after, '.') orelse return false;
        const second = std.fmt.parseInt(u8, after[0..dot], 10) catch return false;
        return second >= 16 and second <= 31;
    }
    return false;
}

test "detects private addresses" {
    try std.testing.expect(isPrivateAddress("localhost"));
    try std.testing.expect(isPrivateAddress("127.0.0.1"));
    try std.testing.expect(isPrivateAddress("10.0.0.1"));
    try std.testing.expect(isPrivateAddress("192.168.1.1"));
    try std.testing.expect(isPrivateAddress("172.16.0.1"));
    try std.testing.expect(isPrivateAddress("172.31.255.1"));
}

test "rejects public addresses" {
    try std.testing.expect(!isPrivateAddress("8.8.8.8"));
    try std.testing.expect(!isPrivateAddress("example.com"));
    try std.testing.expect(!isPrivateAddress("172.32.0.1"));
    try std.testing.expect(!isPrivateAddress("172.15.0.1"));
}
