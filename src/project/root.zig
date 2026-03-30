const std = @import("std");

pub const MODULE_NAME = "project";

pub const types = @import("types.zig");
pub const runtime = @import("runtime.zig");

pub const ProjectInfo = types.ProjectInfo;
pub const VcsStatus = types.VcsStatus;
pub const WorkspaceInfo = types.WorkspaceInfo;
pub const freeWorkspaces = types.freeWorkspaces;
pub const ProjectRuntime = runtime.ProjectRuntime;
pub const WorkspaceCreateRequest = runtime.WorkspaceCreateRequest;
pub const ProjectRuntimeDependencies = runtime.Dependencies;
pub const VcsExecutor = runtime.VcsExecutor;

test "project module exports are available" {
    try std.testing.expectEqualStrings("project", MODULE_NAME);
}
