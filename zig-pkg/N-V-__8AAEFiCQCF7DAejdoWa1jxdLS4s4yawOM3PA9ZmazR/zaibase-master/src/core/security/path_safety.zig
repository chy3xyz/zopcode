const std = @import("std");

pub const PathError = error{UnsafePath};

pub fn resolveSafePath(base: []const u8, requested: []const u8) (PathError || error{OutOfMemory})![]const u8 {
    if (std.mem.indexOf(u8, requested, "..") != null) return PathError.UnsafePath;
    if (std.mem.indexOfScalar(u8, requested, 0) != null) return PathError.UnsafePath;
    if (requested.len > 0 and requested[0] == '/') {
        if (!std.mem.startsWith(u8, requested, base)) return PathError.UnsafePath;
        return requested;
    }
    return requested;
}

test "rejects .." {
    try std.testing.expectError(PathError.UnsafePath, resolveSafePath("/home/user", "../etc/passwd"));
}

test "allows safe relative path" {
    const result = try resolveSafePath("/home/user", "docs/file.txt");
    try std.testing.expectEqualStrings("docs/file.txt", result);
}
