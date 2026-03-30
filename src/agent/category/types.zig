const std = @import("std");
const provider = @import("../../provider/root.zig");

pub const CategoryId = enum {
    quick,
    deep,
    visual,
    ultrabrain,

    pub fn asText(self: CategoryId) []const u8 {
        return @tagName(self);
    }
};

pub const CategoryPolicy = struct {
    id: CategoryId,
    description: []const u8,
    preferred_model: provider.ModelRef,
    variant: ?[]const u8 = null,
    prompt_append: ?[]const u8 = null,
    fallback_chain: []const provider.ModelRef = &.{},

    pub fn clone(self: CategoryPolicy, allocator: std.mem.Allocator) !CategoryPolicy {
        const fallbacks = try allocator.alloc(provider.ModelRef, self.fallback_chain.len);
        errdefer allocator.free(fallbacks);
        for (self.fallback_chain, 0..) |item, index| {
            fallbacks[index] = try item.clone(allocator);
        }

        return .{
            .id = self.id,
            .description = try allocator.dupe(u8, self.description),
            .preferred_model = try self.preferred_model.clone(allocator),
            .variant = if (self.variant) |variant| try allocator.dupe(u8, variant) else null,
            .prompt_append = if (self.prompt_append) |prompt_append| try allocator.dupe(u8, prompt_append) else null,
            .fallback_chain = fallbacks,
        };
    }

    pub fn deinit(self: *CategoryPolicy, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        self.preferred_model.deinit(allocator);
        if (self.variant) |variant| allocator.free(variant);
        if (self.prompt_append) |prompt_append| allocator.free(prompt_append);
        for (self.fallback_chain) |*item| {
            var mutable = item.*;
            mutable.deinit(allocator);
        }
        allocator.free(self.fallback_chain);
    }
};

pub const CategoryExecutionPlan = struct {
    category_id: CategoryId,
    selected_model: provider.ModelRef,
    selected_variant: ?[]const u8 = null,
    prompt_append: ?[]const u8 = null,
    fallback_chain: []provider.ModelRef = &.{},

    pub fn deinit(self: *CategoryExecutionPlan, allocator: std.mem.Allocator) void {
        self.selected_model.deinit(allocator);
        if (self.selected_variant) |variant| allocator.free(variant);
        if (self.prompt_append) |prompt_append| allocator.free(prompt_append);
        for (self.fallback_chain) |*item| {
            var mutable = item.*;
            mutable.deinit(allocator);
        }
        allocator.free(self.fallback_chain);
    }
};

test "category ids expose stable names" {
    try std.testing.expectEqualStrings("quick", CategoryId.quick.asText());
    try std.testing.expectEqualStrings("ultrabrain", CategoryId.ultrabrain.asText());
}
