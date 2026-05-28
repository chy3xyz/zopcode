const std = @import("std");

pub const MODULE_NAME = "app";
pub const command_types = @import("command_types.zig");
pub const command_context = @import("command_context.zig");
pub const command_registry = @import("command_registry.zig");
pub const command_dispatcher = @import("command_dispatcher.zig");

pub const Authority = command_types.Authority;
pub const RequestSource = command_types.RequestSource;
pub const CommandExecutionMode = command_types.CommandExecutionMode;
pub const CommandRequest = command_types.CommandRequest;
pub const RequestContext = command_types.RequestContext;
pub const CommandContext = command_context.CommandContext;
pub const SyncCommandHandler = command_registry.SyncCommandHandler;
pub const AsyncCommandHandler = command_registry.AsyncCommandHandler;
pub const CommandDefinition = command_registry.CommandDefinition;
pub const CommandRegistry = command_registry.CommandRegistry;
pub const CommandSchema = command_dispatcher.CommandSchema;
pub const CommandDispatchResult = command_dispatcher.CommandDispatchResult;
pub const CommandEnvelope = command_dispatcher.CommandEnvelope;
pub const CommandDispatcher = command_dispatcher.CommandDispatcher;

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test "app scaffold exports are stable" {
    try std.testing.expectEqualStrings("app", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);
    try std.testing.expectEqualStrings("cli", @tagName(RequestSource.cli));
    try std.testing.expectEqualStrings("public", Authority.public.asText());
}


