const std = @import("std");
const zig_opencode = @import("zig_opencode");

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len > 1 and std.mem.eql(u8, args[1], "tui")) {
        if (args.len > 3 and std.mem.eql(u8, args[2], "--attach")) {
            try zig_opencode.tui.runAttached(allocator, args[3]);
            return;
        }

        var app_context = try zig_opencode.AppContext.init(std.heap.page_allocator, .{
            .console_log_enabled = false,
        });
        defer app_context.deinit();
        try zig_opencode.tui.runLocal(allocator, &app_context);
        return;
    }

    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) {
        var app_context = try zig_opencode.AppContext.init(std.heap.page_allocator, .{
            .console_log_enabled = false,
        });
        defer app_context.deinit();

        const port: u16 = if (args.len > 2) try std.fmt.parseInt(u16, args[2], 10) else 4096;
        const listener = try zig_opencode.server.ServerListener.init(allocator, &app_context, .{
            .host = "127.0.0.1",
            .port = port,
        });
        defer listener.deinit();

        const url = try listener.urlAlloc(allocator);
        defer allocator.free(url);
        try std.fs.File.stdout().writeAll(url);
        try std.fs.File.stdout().writeAll("\n");

        while (true) {
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
    }

    try std.fs.File.stdout().writeAll("zig-opencode bootstrap ready\n");
}
