const std = @import("std");
const model = @import("model.zig");

pub fn normalizeSystemPrompt(system_prompt: ?[]const u8) []const u8 {
    return system_prompt orelse "";
}

pub fn toolCount(tools: []const model.ProviderToolDefinition) usize {
    return tools.len;
}

test "transform helpers are minimal and stable" {
    try std.testing.expectEqualStrings("", normalizeSystemPrompt(null));
    try std.testing.expectEqual(@as(usize, 0), toolCount(&.{}));
}
