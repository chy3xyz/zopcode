const std = @import("std");
const core = @import("../core/root.zig");
const command_types = @import("command_types.zig");
const command_context = @import("command_context.zig");

pub const FieldDefinition = core.validation.FieldDefinition;
pub const Authority = command_types.Authority;
pub const RequestSource = command_types.RequestSource;
pub const CommandExecutionMode = command_types.CommandExecutionMode;
pub const CommandContext = command_context.CommandContext;

pub const SyncCommandHandler = *const fn (ctx: *const CommandContext) anyerror![]const u8;
pub const AsyncCommandHandler = *const fn (ctx: *const CommandContext) anyerror![]const u8;

const ALL_SOURCES = &.{ RequestSource.cli, RequestSource.bridge, RequestSource.http, RequestSource.service, RequestSource.@"test" };

pub const CommandDefinition = struct {
    id: []const u8,
    method: []const u8,
    description: []const u8 = "",
    authority: Authority = .public,
    allowed_sources: []const RequestSource = ALL_SOURCES,
    execution_mode: CommandExecutionMode = .sync,
    params: []const FieldDefinition = &.{},
    handler: ?SyncCommandHandler = null,
    async_handler: ?AsyncCommandHandler = null,
    user_data: ?*anyopaque = null,

    pub fn clone(self: CommandDefinition, allocator: std.mem.Allocator) !CommandDefinition {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .method = try allocator.dupe(u8, self.method),
            .description = try allocator.dupe(u8, self.description),
            .authority = self.authority,
            .allowed_sources = try allocator.dupe(RequestSource, self.allowed_sources),
            .execution_mode = self.execution_mode,
            .params = self.params,
            .handler = self.handler,
            .async_handler = self.async_handler,
            .user_data = self.user_data,
        };
    }

    pub fn deinit(self: *CommandDefinition, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.method);
        allocator.free(self.description);
        allocator.free(self.allowed_sources);
    }
};

pub const CommandRegistry = struct {
    allocator: std.mem.Allocator,
    commands: std.ArrayListUnmanaged(CommandDefinition) = .empty,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Self) void {
        for (self.commands.items) |*command| {
            command.deinit(self.allocator);
        }
        self.commands.deinit(self.allocator);
    }

    pub fn register(self: *Self, definition: CommandDefinition) !void {
        if (self.findByMethod(definition.method) != null) {
            return error.DuplicateCommandMethod;
        }
        try self.commands.append(self.allocator, try definition.clone(self.allocator));
    }

    pub fn findByMethod(self: *const Self, method: []const u8) ?*const CommandDefinition {
        for (self.commands.items) |*command| {
            if (std.mem.eql(u8, command.method, method)) {
                return command;
            }
        }
        return null;
    }

    pub fn count(self: *const Self) usize {
        return self.commands.items.len;
    }
};

test "command registry registers and finds commands" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{
        .id = "app.meta",
        .method = "app.meta",
    });

    try std.testing.expectEqual(@as(usize, 1), registry.count());
    try std.testing.expect(registry.findByMethod("app.meta") != null);
    try std.testing.expect(registry.findByMethod("missing") == null);
}

test "command registry rejects duplicate method" {
    var registry = CommandRegistry.init(std.testing.allocator);
    defer registry.deinit();

    try registry.register(.{
        .id = "app.meta",
        .method = "app.meta",
    });

    try std.testing.expectError(error.DuplicateCommandMethod, registry.register(.{
        .id = "app.meta.dup",
        .method = "app.meta",
    }));
}


