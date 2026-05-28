const std = @import("std");
const effects = @import("../effects/root.zig");

pub const ScriptRequest = struct {
    tool_id: []const u8,
    request_id: []const u8,
    trace_id: ?[]const u8 = null,
    params_json: []const u8,
};

pub const ScriptResult = struct {
    ok: bool,
    output_json: ?[]u8 = null,
    error_code: ?[]u8 = null,
    error_message: ?[]u8 = null,

    pub fn deinit(self: *ScriptResult, allocator: std.mem.Allocator) void {
        if (self.output_json) |value| allocator.free(value);
        if (self.error_code) |value| allocator.free(value);
        if (self.error_message) |value| allocator.free(value);
    }
};

pub const ScriptSpec = struct {
    program: []const u8,
    args: []const []const u8 = &.{},
    cwd: ?[]const u8 = null,
    env: []const effects.ProcessEnvVar = &.{},
    timeout_ms: ?u32 = null,
    expects_json_stdout: bool = true,
};


