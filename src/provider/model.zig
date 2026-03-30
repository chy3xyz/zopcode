const std = @import("std");

pub const ModelRef = struct {
    provider_id: []const u8,
    model_id: []const u8,

    pub fn clone(self: ModelRef, allocator: std.mem.Allocator) !ModelRef {
        return .{
            .provider_id = try allocator.dupe(u8, self.provider_id),
            .model_id = try allocator.dupe(u8, self.model_id),
        };
    }

    pub fn deinit(self: *ModelRef, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model_id);
    }
};

pub const ModelInfo = struct {
    provider_id: []const u8,
    model_id: []const u8,
    display_name: []const u8,

    pub fn clone(self: ModelInfo, allocator: std.mem.Allocator) !ModelInfo {
        return .{
            .provider_id = try allocator.dupe(u8, self.provider_id),
            .model_id = try allocator.dupe(u8, self.model_id),
            .display_name = try allocator.dupe(u8, self.display_name),
        };
    }

    pub fn deinit(self: *ModelInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_id);
        allocator.free(self.model_id);
        allocator.free(self.display_name);
    }
};

pub const ProviderMessageRole = enum {
    user,
    assistant,

    pub fn asText(self: ProviderMessageRole) []const u8 {
        return switch (self) {
            .user => "user",
            .assistant => "assistant",
        };
    }
};

pub const ProviderMessage = struct {
    role: ProviderMessageRole,
    content: []const u8,
};

pub const ProviderToolDefinition = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,
};

test "provider message role text values are stable" {
    try std.testing.expectEqualStrings("user", ProviderMessageRole.user.asText());
    try std.testing.expectEqualStrings("assistant", ProviderMessageRole.assistant.asText());
}
