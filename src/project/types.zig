const std = @import("std");

pub const VcsStatus = struct {
    available: bool,
    branch: ?[]const u8 = null,
    dirty: bool = false,
    changed_file_count: u32 = 0,

    pub fn clone(self: VcsStatus, allocator: std.mem.Allocator) !VcsStatus {
        return .{
            .available = self.available,
            .branch = if (self.branch) |value| try allocator.dupe(u8, value) else null,
            .dirty = self.dirty,
            .changed_file_count = self.changed_file_count,
        };
    }

    pub fn deinit(self: *VcsStatus, allocator: std.mem.Allocator) void {
        if (self.branch) |value| allocator.free(value);
    }
};

pub const ProjectInfo = struct {
    name: []const u8,
    workspace_dir: []const u8,
    project_root: []const u8,
    vcs: VcsStatus,

    pub fn clone(self: ProjectInfo, allocator: std.mem.Allocator) !ProjectInfo {
        return .{
            .name = try allocator.dupe(u8, self.name),
            .workspace_dir = try allocator.dupe(u8, self.workspace_dir),
            .project_root = try allocator.dupe(u8, self.project_root),
            .vcs = try self.vcs.clone(allocator),
        };
    }

    pub fn deinit(self: *ProjectInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.workspace_dir);
        allocator.free(self.project_root);
        self.vcs.deinit(allocator);
    }
};

pub const WorkspaceInfo = struct {
    id: []const u8,
    name: []const u8,
    path: []const u8,
    created_at_ms: i64,

    pub fn clone(self: WorkspaceInfo, allocator: std.mem.Allocator) !WorkspaceInfo {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .name = try allocator.dupe(u8, self.name),
            .path = try allocator.dupe(u8, self.path),
            .created_at_ms = self.created_at_ms,
        };
    }

    pub fn deinit(self: *WorkspaceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        allocator.free(self.path);
    }
};

pub fn freeWorkspaces(allocator: std.mem.Allocator, items: []WorkspaceInfo) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}
