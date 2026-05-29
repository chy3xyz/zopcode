const std = @import("std");
const zopcode = @import("zopcode");

pub fn main(ctx: std.process.Init.Minimal) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const args = try ctx.args.toSlice(allocator);
    defer allocator.free(args);

    if (args.len > 1 and std.mem.eql(u8, args[1], "tui")) {
        if (args.len > 3 and std.mem.eql(u8, args[2], "--attach")) {
            try zopcode.tui.runAttached(allocator, args[3]);
            return;
        }
        var app_context = try zopcode.AppContext.init(std.heap.page_allocator, .{ .console_log_enabled = false });
        defer app_context.deinit();
        try zopcode.tui.runLocal(allocator, &app_context);
        return;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) {
        var app_context = try zopcode.AppContext.init(std.heap.page_allocator, .{ .console_log_enabled = false });
        defer app_context.deinit();
        const port: u16 = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 4096;
        const listener = try zopcode.server.ServerListener.init(allocator, &app_context, .{ .host = "127.0.0.1", .port = port });
        defer listener.deinit();
        const url = try listener.urlAlloc(allocator);
        defer allocator.free(url);
        const sio = std.Io.Threaded.global_single_threaded.*.io();
        try std.Io.File.stdout().writeStreamingAll(sio, url);
        try std.Io.File.stdout().writeStreamingAll(sio, "\n");
        while (true) { const ts = std.c.timespec{ .sec = 1, .nsec = 0 }; _ = std.c.nanosleep(&ts, null); }
    }

    // No subcommand — default to TUI mode
    {
        var app_context = try zopcode.AppContext.init(std.heap.page_allocator, .{ .console_log_enabled = false });
        defer app_context.deinit();
        try zopcode.tui.runLocal(allocator, &app_context);
        return;
    }
}
