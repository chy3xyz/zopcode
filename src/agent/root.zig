const std = @import("std");

pub const MODULE_NAME = "agent";

pub const profile = @import("profile.zig");
pub const registry = @import("registry.zig");
pub const builtin = @import("builtin.zig");
pub const category = @import("category/root.zig");

pub const AgentMode = profile.AgentMode;
pub const AgentProfile = profile.AgentProfile;
pub const AgentRegistry = registry.AgentRegistry;
pub const CategoryId = category.CategoryId;
pub const CategoryPolicy = category.CategoryPolicy;
pub const CategoryExecutionPlan = category.CategoryExecutionPlan;
pub const CategoryResolver = category.CategoryResolver;
pub const builtins = builtin.builtins;
pub const registerBuiltins = builtin.registerBuiltins;

pub const ModuleStage = enum {
    registry,
};

pub const MODULE_STAGE: ModuleStage = .registry;

test "agent module exports built-in registry surface" {
    var registry_instance = AgentRegistry.init(std.testing.allocator);
    defer registry_instance.deinit();

    try registerBuiltins(&registry_instance);
    try std.testing.expectEqualStrings("agent", MODULE_NAME);
    try std.testing.expect(registry_instance.get("build") != null);
    try std.testing.expect(registry_instance.get("plan") != null);
    try std.testing.expect(registry_instance.get("explore") != null);
    try std.testing.expect(registry_instance.get("oracle") != null);
    var provider_registry = @import("../provider/root.zig").ProviderRegistry.init(std.testing.allocator, null, null);
    defer provider_registry.deinit();
    try provider_registry.registerAnthropic();
    var resolver = CategoryResolver.init(std.testing.allocator, &provider_registry);
    var plan = try resolver.resolve(.quick);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expect(plan.prompt_append != null);
}
