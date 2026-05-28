const std = @import("std");
const session = @import("../session/root.zig");

pub fn latestAssistantSummary(
    allocator: std.mem.Allocator,
    runtime: *session.SessionRuntime,
    session_id: session.SessionId,
) ![]u8 {
    const history = try runtime.listHistory(allocator, session_id);
    defer {
        for (history) |*message| message.deinit(allocator);
        allocator.free(history);
    }

    var idx: usize = history.len;
    while (idx > 0) {
        idx -= 1;
        const message = history[idx];
        if (message.info.role != .assistant) continue;
        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
        for (message.parts) |part| {
            if (part == .text) try out.appendSlice(allocator, part.text.text);
        }
        return allocator.dupe(u8, out.items);
    }

    return allocator.dupe(u8, "");
}
