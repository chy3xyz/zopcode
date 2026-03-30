const std = @import("std");
const constants = @import("constants.zig");

const hash_space = std.math.pow(usize, constants.hash_alphabet.len, constants.hash_len);

pub fn normalizeLine(line: []const u8) []const u8 {
    return std.mem.trimRight(u8, std.mem.trimRight(u8, line, "\r"), " \t");
}

pub fn compute(line: []const u8) [constants.hash_len]u8 {
    const normalized = normalizeLine(line);
    var hasher = std.hash.Fnv1a_32.init();
    hasher.update(normalized);
    var value: usize = @intCast(hasher.final() % hash_space);

    var out: [constants.hash_len]u8 = undefined;
    var index: usize = constants.hash_len;
    while (index > 0) {
        index -= 1;
        out[index] = constants.hash_alphabet[value % constants.hash_alphabet.len];
        value /= constants.hash_alphabet.len;
    }
    return out;
}

test "hashline hash is stable for equal normalized content" {
    const first = compute("hello  \r");
    const second = compute("hello");
    try std.testing.expectEqualSlices(u8, first[0..], second[0..]);
}
