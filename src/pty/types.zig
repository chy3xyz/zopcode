const std = @import("std");

pub const StatusKind = enum {
    running,
    exited,
    failed,

    pub fn asText(self: StatusKind) []const u8 {
        return switch (self) {
            .running => "running",
            .exited => "exited",
            .failed => "failed",
        };
    }
};

pub const StreamKind = enum {
    stdout,
    stderr,

    pub fn asText(self: StreamKind) []const u8 {
        return switch (self) {
            .stdout => "stdout",
            .stderr => "stderr",
        };
    }
};

pub const PtyInfo = struct {
    id: []const u8,
    cwd: []const u8,
    shell: []const u8,
    status: StatusKind,
    created_at_ms: i64,
    updated_at_ms: i64,
    exit_code: ?i32 = null,

    pub fn clone(self: PtyInfo, allocator: std.mem.Allocator) !PtyInfo {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .cwd = try allocator.dupe(u8, self.cwd),
            .shell = try allocator.dupe(u8, self.shell),
            .status = self.status,
            .created_at_ms = self.created_at_ms,
            .updated_at_ms = self.updated_at_ms,
            .exit_code = self.exit_code,
        };
    }

    pub fn deinit(self: *PtyInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.cwd);
        allocator.free(self.shell);
    }
};

pub const OutputChunk = struct {
    seq: u64,
    pty_id: []const u8,
    stream: StreamKind,
    data: []const u8,
    ts_unix_ms: i64,

    pub fn clone(self: OutputChunk, allocator: std.mem.Allocator) !OutputChunk {
        return .{
            .seq = self.seq,
            .pty_id = try allocator.dupe(u8, self.pty_id),
            .stream = self.stream,
            .data = try allocator.dupe(u8, self.data),
            .ts_unix_ms = self.ts_unix_ms,
        };
    }

    pub fn deinit(self: *OutputChunk, allocator: std.mem.Allocator) void {
        allocator.free(self.pty_id);
        allocator.free(self.data);
    }
};

pub fn freeInfos(allocator: std.mem.Allocator, items: []PtyInfo) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

pub fn freeChunks(allocator: std.mem.Allocator, items: []OutputChunk) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}
