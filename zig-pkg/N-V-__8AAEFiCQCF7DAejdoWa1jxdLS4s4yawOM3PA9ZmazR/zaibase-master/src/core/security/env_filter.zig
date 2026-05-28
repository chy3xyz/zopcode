const std = @import("std");

const SENSITIVE_SUBSTRINGS = [_][]const u8{
    "PASSWORD", "SECRET", "TOKEN", "CREDENTIAL", "API_KEY", "PRIVATE_KEY",
};

pub fn isSensitiveKey(key: []const u8) bool {
    var buf: [256]u8 = undefined;
    const len = @min(key.len, buf.len);
    @memcpy(buf[0..len], key[0..len]);
    for (buf[0..len]) |*c| {
        if (c.* >= 'a' and c.* <= 'z') c.* = c.* - 32;
    }
    const upper = buf[0..len];
    for (&SENSITIVE_SUBSTRINGS) |s| {
        if (std.mem.indexOf(u8, upper, s) != null) return true;
    }
    return false;
}

test "detects sensitive keys" {
    try std.testing.expect(isSensitiveKey("DB_PASSWORD"));
    try std.testing.expect(isSensitiveKey("AUTH_TOKEN"));
    try std.testing.expect(isSensitiveKey("my_secret_key"));
}

test "allows safe keys" {
    try std.testing.expect(!isSensitiveKey("HOME"));
    try std.testing.expect(!isSensitiveKey("PATH"));
}
