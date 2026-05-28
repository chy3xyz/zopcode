const std = @import("std");

pub const EnvProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get_optional: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8,
        get_required: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror![]u8,
        has: *const fn (ptr: *anyopaque, key: []const u8) bool,
        name: *const fn (ptr: *anyopaque) []const u8,
        deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
    };

    pub fn getOptional(self: EnvProvider, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
        return self.vtable.get_optional(self.ptr, allocator, key);
    }

    pub fn getRequired(self: EnvProvider, allocator: std.mem.Allocator, key: []const u8) anyerror![]u8 {
        return self.vtable.get_required(self.ptr, allocator, key);
    }

    pub fn has(self: EnvProvider, key: []const u8) bool {
        return self.vtable.has(self.ptr, key);
    }

    pub fn name(self: EnvProvider) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn deinit(self: EnvProvider, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |deinit_fn| deinit_fn(self.ptr, allocator);
    }
};

pub const NativeEnvProvider = struct {
    const vtable = EnvProvider.VTable{
        .get_optional = getOptionalErased,
        .get_required = getRequiredErased,
        .has = hasErased,
        .name = nameErased,
        .deinit = null,
    };

    pub fn init() NativeEnvProvider {
        return .{};
    }

    pub fn provider(self: *NativeEnvProvider) EnvProvider {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn providerName() []const u8 {
        return "native";
    }

    pub fn getOptional(_: *NativeEnvProvider, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        return std.Io.Threaded.global_single_threaded.environ.process_environ.getAlloc(allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => null,
            else => err,
        };
    }

    pub fn getRequired(self: *NativeEnvProvider, allocator: std.mem.Allocator, key: []const u8) ![]u8 {
        return (try self.getOptional(allocator, key)) orelse error.EnvironmentVariableNotFound;
    }

    pub fn has(_: *NativeEnvProvider, key: []const u8) bool {
        const value = std.Io.Threaded.global_single_threaded.environ.process_environ.getAlloc(std.heap.page_allocator, key) catch |err| switch (err) {
            error.EnvironmentVariableMissing => return false,
            else => return false,
        };
        defer std.heap.page_allocator.free(value);
        return true;
    }

    fn getOptionalErased(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror!?[]u8 {
        const self: *NativeEnvProvider = @ptrCast(@alignCast(ptr));
        return self.getOptional(allocator, key);
    }

    fn getRequiredErased(ptr: *anyopaque, allocator: std.mem.Allocator, key: []const u8) anyerror![]u8 {
        const self: *NativeEnvProvider = @ptrCast(@alignCast(ptr));
        return self.getRequired(allocator, key);
    }

    fn hasErased(ptr: *anyopaque, key: []const u8) bool {
        const self: *NativeEnvProvider = @ptrCast(@alignCast(ptr));
        return self.has(key);
    }

    fn nameErased(_: *anyopaque) []const u8 {
        return providerName();
    }
};

test "native env provider returns null for missing variables" {
    var provider = NativeEnvProvider.init();
    const missing = try provider.getOptional(std.testing.allocator, "FRAMEWORK_MISSING_ENV_PROVIDER_VALUE");
    try std.testing.expect(missing == null);
}

test "native env provider supports required and has queries" {
    const key = "PATH";

    var provider = NativeEnvProvider.init();
    const value = try provider.getRequired(std.testing.allocator, key);
    defer std.testing.allocator.free(value);

    try std.testing.expect(value.len > 0);
    try std.testing.expect(provider.has(key));
}


