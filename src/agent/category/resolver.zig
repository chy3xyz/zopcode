const std = @import("std");
const provider = @import("../../provider/root.zig");
const builtin = @import("builtin.zig");
const types = @import("types.zig");

pub const CategoryResolver = struct {
    allocator: std.mem.Allocator,
    registry: *const provider.ProviderRegistry,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, registry: *const provider.ProviderRegistry) Self {
        return .{
            .allocator = allocator,
            .registry = registry,
        };
    }

    pub fn resolve(self: *const Self, category_id: types.CategoryId) !types.CategoryExecutionPlan {
        const policy = findPolicy(category_id) orelse return error.UnknownCategory;
        return self.resolvePolicy(policy);
    }

    pub fn resolveByName(self: *const Self, category_name: []const u8) !types.CategoryExecutionPlan {
        const category_id = std.meta.stringToEnum(types.CategoryId, category_name) orelse return error.UnknownCategory;
        return self.resolve(category_id);
    }

    fn resolvePolicy(self: *const Self, policy: types.CategoryPolicy) !types.CategoryExecutionPlan {
        const selected = if (self.isModelAvailable(policy.preferred_model))
            try policy.preferred_model.clone(self.allocator)
        else
            try self.resolveFallbackModel(policy);

        const fallbacks = try self.allocator.alloc(provider.ModelRef, policy.fallback_chain.len);
        errdefer self.allocator.free(fallbacks);
        for (policy.fallback_chain, 0..) |item, index| {
            fallbacks[index] = try item.clone(self.allocator);
        }

        return .{
            .category_id = policy.id,
            .selected_model = selected,
            .selected_variant = if (policy.variant) |variant| try self.allocator.dupe(u8, variant) else null,
            .prompt_append = if (policy.prompt_append) |prompt_append| try self.allocator.dupe(u8, prompt_append) else null,
            .fallback_chain = fallbacks,
        };
    }

    fn resolveFallbackModel(self: *const Self, policy: types.CategoryPolicy) !provider.ModelRef {
        for (policy.fallback_chain) |fallback| {
            if (self.isModelAvailable(fallback)) {
                return fallback.clone(self.allocator);
            }
        }

        if (self.registry.defaultModel()) |default_model| {
            return default_model.clone(self.allocator);
        }
        return error.NoFallbackModelAvailable;
    }

    fn isModelAvailable(self: *const Self, model_ref: provider.ModelRef) bool {
        return self.registry.isModelReady(model_ref);
    }
};

fn findPolicy(category_id: types.CategoryId) ?types.CategoryPolicy {
    for (builtin.all()) |policy| {
        if (policy.id == category_id) return policy;
    }
    return null;
}

test "all built-in categories resolve successfully" {
    var registry = provider.ProviderRegistry.init(std.testing.allocator, null, null);
    defer registry.deinit();
    try registry.registerAnthropic();

    const resolver = CategoryResolver.init(std.testing.allocator, &registry);

    inline for ([_]types.CategoryId{ .quick, .deep, .visual, .ultrabrain }) |category_id| {
        var plan = try resolver.resolve(category_id);
        defer plan.deinit(std.testing.allocator);
        try std.testing.expect(plan.prompt_append != null);
    }
}

test "category resolver falls back when preferred provider is unavailable" {
    var registry = provider.ProviderRegistry.init(std.testing.allocator, null, null);
    defer registry.deinit();
    try registry.registerAnthropic();

    const resolver = CategoryResolver.init(std.testing.allocator, &registry);
    var plan = try resolver.resolve(.visual);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("anthropic", plan.selected_model.provider_id);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", plan.selected_model.model_id);
}

test "category execution plan includes prompt append and variant data" {
    var registry = provider.ProviderRegistry.init(std.testing.allocator, null, null);
    defer registry.deinit();
    try registry.registerAnthropic();

    const resolver = CategoryResolver.init(std.testing.allocator, &registry);
    var plan = try resolver.resolve(.deep);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expect(plan.selected_variant != null);
    try std.testing.expect(plan.prompt_append != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.prompt_append.?, "deeper analysis") != null);
}

test "category resolver selects openai when credentials are ready" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root_path = try std.testing.allocator.dupe(u8, ".");
    defer std.testing.allocator.free(root_path);
    const auth_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "provider-auth.json" });
    defer std.testing.allocator.free(auth_path);

    var auth_runtime = try provider.ProviderAuthRuntime.init(std.testing.allocator, null, auth_path);
    defer {
        auth_runtime.deinit();
        std.testing.allocator.destroy(auth_runtime);
    }
    try auth_runtime.setApiKey("anthropic", "anthropic-secret");
    try auth_runtime.setApiKey("openai", "openai-secret");

    var registry = provider.ProviderRegistry.init(std.testing.allocator, null, null);
    defer registry.deinit();
    registry.setAuthRuntime(auth_runtime);
    try registry.registerAnthropic();
    try registry.registerOpenAI();

    const resolver = CategoryResolver.init(std.testing.allocator, &registry);
    var plan = try resolver.resolve(.visual);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("openai", plan.selected_model.provider_id);
}

test "category resolver falls back to anthropic when openai is unready" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root_path = try std.testing.allocator.dupe(u8, ".");
    defer std.testing.allocator.free(root_path);
    const auth_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "provider-auth.json" });
    defer std.testing.allocator.free(auth_path);

    var auth_runtime = try provider.ProviderAuthRuntime.init(std.testing.allocator, null, auth_path);
    defer {
        auth_runtime.deinit();
        std.testing.allocator.destroy(auth_runtime);
    }
    try auth_runtime.setApiKey("anthropic", "anthropic-secret");

    var registry = provider.ProviderRegistry.init(std.testing.allocator, null, null);
    defer registry.deinit();
    registry.setAuthRuntime(auth_runtime);
    try registry.registerAnthropic();
    try registry.registerOpenAI();

    const resolver = CategoryResolver.init(std.testing.allocator, &registry);
    var plan = try resolver.resolve(.visual);
    defer plan.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("anthropic", plan.selected_model.provider_id);
}
