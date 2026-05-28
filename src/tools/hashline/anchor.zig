const std = @import("std");
const constants = @import("constants.zig");
const hash = @import("hash.zig");
const framework = @import("framework");
const json = @import("../json.zig");

pub const Anchor = struct {
    line_no: usize,
    hash_text: [constants.hash_len]u8,
};

pub fn formatAnchor(allocator: std.mem.Allocator, line_no: usize, line: []const u8) ![]u8 {
    const hash_text = hash.compute(line);
    return std.fmt.allocPrint(allocator, "{d}{c}{s}", .{ line_no, constants.anchor_separator, hash_text[0..] });
}

pub fn formatReadLine(allocator: std.mem.Allocator, line_no: usize, line: []const u8) ![]u8 {
    const anchor = try formatAnchor(allocator, line_no, line);
    defer allocator.free(anchor);
    return std.fmt.allocPrint(allocator, "{s}{c}{s}", .{ anchor, constants.content_separator, line });
}

pub fn normalizeAnchorText(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var trimmed = std.mem.trim(u8, raw, " \t\r\n");
    while (trimmed.len > 0 and (trimmed[0] == '>' or trimmed[0] == '+' or trimmed[0] == '-' or trimmed[0] == ' ')) {
        trimmed = std.mem.trimStart(u8, trimmed[1..], " \t");
    }
    if (std.mem.indexOfScalar(u8, trimmed, constants.content_separator)) |index| {
        trimmed = trimmed[0..index];
    }
    return allocator.dupe(u8, trimmed);
}

pub fn parseAnchor(raw: []const u8) !Anchor {
    const hash_index = std.mem.indexOfScalar(u8, raw, constants.anchor_separator) orelse return error.InvalidHashlineAnchor;
    const line_part = raw[0..hash_index];
    const hash_part = raw[hash_index + 1 ..];

    if (hash_part.len != constants.hash_len) return error.InvalidHashlineAnchor;
    for (hash_part) |ch| {
        if (std.mem.indexOfScalar(u8, constants.hash_alphabet, ch) == null) return error.InvalidHashlineAnchor;
    }

    var anchor: Anchor = .{
        .line_no = try std.fmt.parseInt(usize, line_part, 10),
        .hash_text = undefined,
    };
    @memcpy(anchor.hash_text[0..], hash_part);
    return anchor;
}

pub fn validateAnchor(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    anchor_text: []const u8,
) !void {
    _ = allocator;
    const anchor = try parseAnchor(anchor_text);
    if (anchor.line_no == 0 or anchor.line_no > lines.len) return error.HashlineOutOfBounds;
    const actual = hash.compute(lines[anchor.line_no - 1]);
    if (!std.mem.eql(u8, actual[0..], anchor.hash_text[0..])) return error.HashMismatch;
}

pub fn mismatchReport(
    allocator: std.mem.Allocator,
    lines: []const []const u8,
    raw_anchor: []const u8,
) !framework.ValidationReport {
    const normalized = try normalizeAnchorText(allocator, raw_anchor);
    defer allocator.free(normalized);
    const anchor = try parseAnchor(normalized);

    var report = framework.ValidationReport.init(allocator);
    errdefer report.deinit();

    const start_index = if (anchor.line_no > constants.context_radius + 1) anchor.line_no - constants.context_radius - 1 else 0;
    const end_index = @min(lines.len, anchor.line_no + constants.context_radius);

    var refreshed_context: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (refreshed_context.items) |item| allocator.free(item);
        refreshed_context.deinit(allocator);
    }
    for (start_index..end_index, 0..) |line_index, idx| {
        const formatted = try formatReadLine(allocator, line_index + 1, lines[line_index]);
        errdefer allocator.free(formatted);
        try refreshed_context.append(allocator, formatted);
        _ = idx;
    }

    const actual_anchor = if (anchor.line_no >= 1 and anchor.line_no <= lines.len)
        try formatAnchor(allocator, anchor.line_no, lines[anchor.line_no - 1])
    else
        try allocator.dupe(u8, "out_of_bounds");
    defer allocator.free(actual_anchor);

    const details_json = try json.stringifyAlloc(allocator, .{
        .expected = normalized,
        .actual = actual_anchor,
        .line = anchor.line_no,
        .refreshed_context = refreshed_context.items,
    });
    defer allocator.free(details_json);

    try report.addIssue(
        framework.core.validation.ValidationIssue
            .init("edits.anchor", constants.mismatch_code, "Hash anchor does not match current file content", .@"error")
            .withHint("re-read the file and retry with refreshed anchors")
            .withDetailsJson(details_json)
            .withRetryable(true),
    );

    return report;
}

test "anchor normalization accepts copied read output and mismatch prefixes" {
    const first = try normalizeAnchorText(std.testing.allocator, "12#ABC|hello");
    defer std.testing.allocator.free(first);
    const second = try normalizeAnchorText(std.testing.allocator, ">>> 12#ABC|hello");
    defer std.testing.allocator.free(second);

    try std.testing.expectEqualStrings("12#ABC", first);
    try std.testing.expectEqualStrings("12#ABC", second);
}
