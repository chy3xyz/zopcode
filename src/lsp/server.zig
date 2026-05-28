const std = @import("std");
const config = @import("../config/root.zig");

pub fn matchesFile(server: config.LspServerConfig, file_path: []const u8) bool {
    const extension = std.fs.path.extension(file_path);
    const basename = std.fs.path.basename(file_path);
    for (server.extensions) |item| {
        if (item.len == 0) continue;
        if (item[0] == '.' and std.mem.eql(u8, extension, item)) return true;
        if (std.mem.eql(u8, basename, item)) return true;
    }
    return false;
}

pub fn resolveRoot(
    allocator: std.mem.Allocator,
    workspace_dir: []const u8,
    server: config.LspServerConfig,
    file_path: []const u8,
) ![]u8 {
    if (server.root_markers.len == 0) {
        return allocator.dupe(u8, workspace_dir);
    }

    const start_dir = std.fs.path.dirname(file_path) orelse workspace_dir;
    var current = try allocator.dupe(u8, start_dir);
    defer allocator.free(current);

    while (true) {
        if (containsAnyMarker(allocator, current, server.root_markers)) {
            return allocator.dupe(u8, current);
        }
        if (std.mem.eql(u8, current, workspace_dir)) break;

        const parent = std.fs.path.dirname(current) orelse break;
        if (std.mem.eql(u8, parent, current)) break;

        const next = try allocator.dupe(u8, parent);
        allocator.free(current);
        current = next;
    }

    return allocator.dupe(u8, workspace_dir);
}

fn containsAnyMarker(allocator: std.mem.Allocator, directory: []const u8, markers: [][]const u8) bool {
    for (markers) |marker| {
        const candidate = std.fs.path.join(allocator, &.{ directory, marker }) catch return false;
        defer allocator.free(candidate);
        std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.*.io(), candidate, .{}) catch continue;
        return true;
    }
    return false;
}

test "server config matches extensions and resolves roots" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const project_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "project" });
    defer std.testing.allocator.free(project_dir);
    const nested_dir = try std.fs.path.join(std.testing.allocator, &.{ project_dir, "src" });
    defer std.testing.allocator.free(nested_dir);
    _ = std.c.mkdir(@ptrCast(nested_dir.ptr), 0o755);

    const marker_path = try std.fs.path.join(std.testing.allocator, &.{ project_dir, "build.zig" });
    defer std.testing.allocator.free(marker_path);
    var marker_file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), marker_path, .{});
    defer marker_file.close(std.Io.Threaded.global_single_threaded.*.io());
    try marker_file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "test");

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ nested_dir, "main.zig" });
    defer std.testing.allocator.free(file_path);
    const command_items = [_][]const u8{};
    const extension_items = [_][]const u8{".zig"};
    const marker_items = [_][]const u8{"build.zig"};
    const cfg = config.LspServerConfig{
        .id = "zls",
        .command = @constCast(command_items[0..]),
        .extensions = @constCast(extension_items[0..]),
        .root_markers = @constCast(marker_items[0..]),
    };

    try std.testing.expect(matchesFile(cfg, file_path));
    const resolved = try resolveRoot(std.testing.allocator, root_path, cfg, file_path);
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings(project_dir, resolved);
}
