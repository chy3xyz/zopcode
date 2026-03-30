const std = @import("std");
const framework = @import("framework");
const auth_model = @import("auth.zig");
const provider_model = @import("model.zig");
const provider_info_model = @import("provider.zig");
const provider_client_model = @import("client.zig");
const anthropic_builtin = @import("builtin/anthropic.zig");

pub const ProviderRegistry = struct {
    allocator: std.mem.Allocator,
    logger: ?*framework.Logger = null,
    event_bus: ?framework.EventBus = null,
    auth_runtime: ?*auth_model.ProviderAuthRuntime = null,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Self = @This();

    pub const ProviderCreateContext = struct {
        logger: ?*framework.Logger = null,
        event_bus: ?framework.EventBus = null,
        api_key: ?[]const u8 = null,
    };

    pub const ProviderCatalogEntry = struct {
        id: []const u8,
        display_name: []const u8,
        auth_kind: provider_info_model.AuthKind,
        has_credentials: bool,
        status: []const u8,
        default_model: provider_model.ModelRef,
        models: []provider_model.ModelInfo,

        pub fn deinit(self: *ProviderCatalogEntry, allocator: std.mem.Allocator) void {
            allocator.free(self.id);
            allocator.free(self.display_name);
            allocator.free(self.status);
            self.default_model.deinit(allocator);
            for (self.models) |*item| item.deinit(allocator);
            allocator.free(self.models);
        }
    };

    const Entry = struct {
        info: provider_info_model.ProviderInfo,
        create_client: *const fn (allocator: std.mem.Allocator, ctx: ProviderCreateContext) anyerror!provider_client_model.ProviderClient,
    };

    pub fn init(allocator: std.mem.Allocator, logger: ?*framework.Logger, event_bus: ?framework.EventBus) Self {
        return .{
            .allocator = allocator,
            .logger = logger,
            .event_bus = event_bus,
        };
    }

    pub fn setAuthRuntime(self: *Self, auth_runtime: *auth_model.ProviderAuthRuntime) void {
        self.auth_runtime = auth_runtime;
    }

    pub fn deinit(self: *Self) void {
        self.entries.deinit(self.allocator);
    }

    pub fn registerProvider(
        self: *Self,
        info: provider_info_model.ProviderInfo,
        create_client: *const fn (allocator: std.mem.Allocator, ctx: ProviderCreateContext) anyerror!provider_client_model.ProviderClient,
    ) !void {
        if (self.getProvider(info.id) != null) return error.DuplicateProviderId;
        try self.entries.append(self.allocator, .{
            .info = info,
            .create_client = create_client,
        });
    }

    pub fn registerAnthropic(self: *Self) !void {
        if (self.getProvider("anthropic") != null) return;

        try self.registerProvider(.{
            .id = "anthropic",
            .display_name = "Anthropic",
            .default_model = .{
                .provider_id = "anthropic",
                .model_id = "claude-sonnet-4-5",
            },
            .models = &.{
                .{ .provider_id = "anthropic", .model_id = "claude-sonnet-4-5", .display_name = "Claude Sonnet 4.5" },
                .{ .provider_id = "anthropic", .model_id = "claude-haiku-4-5", .display_name = "Claude Haiku 4.5" },
            },
            .auth_kind = .api_key,
        }, anthropic_builtin.createClient);
    }

    pub fn getProvider(self: *const Self, id: []const u8) ?provider_info_model.ProviderInfo {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.info.id, id)) return entry.info;
        }
        return null;
    }

    pub fn defaultModel(self: *const Self) ?provider_model.ModelRef {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[0].info.default_model;
    }

    pub fn catalog(self: *const Self, allocator: std.mem.Allocator) ![]ProviderCatalogEntry {
        const items = try allocator.alloc(ProviderCatalogEntry, self.entries.items.len);
        errdefer allocator.free(items);

        for (self.entries.items, 0..) |entry, index| {
            const has_credentials = switch (entry.info.auth_kind) {
                .none => true,
                .api_key => if (self.auth_runtime) |runtime| runtime.hasApiKey(entry.info.id) else false,
            };
            const status_text = if (has_credentials) "ready" else "needs_auth";

            const models_source = if (entry.info.models.len > 0) entry.info.models else &.{
                provider_model.ModelInfo{
                    .provider_id = entry.info.default_model.provider_id,
                    .model_id = entry.info.default_model.model_id,
                    .display_name = entry.info.default_model.model_id,
                },
            };
            const models = try allocator.alloc(provider_model.ModelInfo, models_source.len);
            errdefer allocator.free(models);
            for (models_source, 0..) |item, model_index| {
                models[model_index] = try item.clone(allocator);
                errdefer models[model_index].deinit(allocator);
            }

            items[index] = .{
                .id = try allocator.dupe(u8, entry.info.id),
                .display_name = try allocator.dupe(u8, entry.info.display_name),
                .auth_kind = entry.info.auth_kind,
                .has_credentials = has_credentials,
                .status = try allocator.dupe(u8, status_text),
                .default_model = try entry.info.default_model.clone(allocator),
                .models = models,
            };
            errdefer items[index].deinit(allocator);
        }

        return items;
    }

    pub fn makeClient(self: *const Self, ref: provider_model.ModelRef) !?provider_client_model.ProviderClient {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.info.id, ref.provider_id)) {
                const api_key = if (self.auth_runtime) |runtime| try runtime.getApiKeyDup(self.allocator, ref.provider_id) else null;
                defer if (api_key) |value| self.allocator.free(value);
                return try entry.create_client(self.allocator, .{
                    .logger = self.logger,
                    .event_bus = self.event_bus,
                    .api_key = api_key,
                });
            }
        }
        return null;
    }
};

test "provider registry can register anthropic as first concrete provider" {
    var registry = ProviderRegistry.init(std.testing.allocator, null, null);
    defer registry.deinit();

    try registry.registerAnthropic();

    const info = registry.getProvider("anthropic").?;
    try std.testing.expectEqualStrings("anthropic", info.id);
    try std.testing.expectEqualStrings("claude-sonnet-4-5", info.default_model.model_id);
    try std.testing.expectEqual(provider_info_model.AuthKind.api_key, info.auth_kind);
}

test "provider registry catalog reflects auth status" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const auth_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "provider-auth.json" });
    defer std.testing.allocator.free(auth_path);

    var auth_runtime = try auth_model.ProviderAuthRuntime.init(std.testing.allocator, null, auth_path);
    defer {
        auth_runtime.deinit();
        std.testing.allocator.destroy(auth_runtime);
    }

    var registry = ProviderRegistry.init(std.testing.allocator, null, null);
    defer registry.deinit();
    registry.setAuthRuntime(auth_runtime);
    try registry.registerAnthropic();

    {
        const catalog = try registry.catalog(std.testing.allocator);
        defer {
            for (catalog) |*item| item.deinit(std.testing.allocator);
            std.testing.allocator.free(catalog);
        }
        try std.testing.expectEqualStrings("needs_auth", catalog[0].status);
    }

    try auth_runtime.setApiKey("anthropic", "secret");
    {
        const catalog = try registry.catalog(std.testing.allocator);
        defer {
            for (catalog) |*item| item.deinit(std.testing.allocator);
            std.testing.allocator.free(catalog);
        }
        try std.testing.expectEqualStrings("ready", catalog[0].status);
    }
}

test "provider registry passes persisted api key into client creation context" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const auth_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "provider-auth.json" });
    defer std.testing.allocator.free(auth_path);

    var auth_runtime = try auth_model.ProviderAuthRuntime.init(std.testing.allocator, null, auth_path);
    defer {
        auth_runtime.deinit();
        std.testing.allocator.destroy(auth_runtime);
    }
    try auth_runtime.setApiKey("mock", "secret");

    const State = struct {
        var saw_api_key = false;
    };

    const MockProvider = struct {
        fn createClient(allocator: std.mem.Allocator, ctx: ProviderRegistry.ProviderCreateContext) anyerror!provider_client_model.ProviderClient {
            if (ctx.api_key) |api_key| {
                State.saw_api_key = std.mem.eql(u8, api_key, "secret");
            }
            const Client = struct {
                const vtable = provider_client_model.ProviderClient.VTable{
                    .stream = streamErased,
                    .deinit = deinitErased,
                };
                fn asClient(self: *@This()) provider_client_model.ProviderClient {
                    return .{ .ptr = @ptrCast(self), .vtable = &vtable };
                }
                fn stream(_: *@This(), _: provider_client_model.ProviderExecutionContext, _: provider_client_model.ProviderRequest, sink: provider_client_model.LlmEventSink) !void {
                    try sink.onEvent(&.{ .completed = .{} });
                }
                fn streamErased(ptr: *anyopaque, exec_ctx: provider_client_model.ProviderExecutionContext, request: provider_client_model.ProviderRequest, sink: provider_client_model.LlmEventSink) anyerror!void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    try self.stream(exec_ctx, request, sink);
                }
                fn deinitErased(ptr: *anyopaque, arena: std.mem.Allocator) void {
                    const self: *@This() = @ptrCast(@alignCast(ptr));
                    arena.destroy(self);
                }
            };

            const client = try allocator.create(Client);
            client.* = .{};
            return client.asClient();
        }
    };

    var registry = ProviderRegistry.init(std.testing.allocator, null, null);
    defer registry.deinit();
    registry.setAuthRuntime(auth_runtime);
    try registry.registerProvider(.{
        .id = "mock",
        .display_name = "Mock",
        .default_model = .{ .provider_id = "mock", .model_id = "mock-model" },
        .auth_kind = .api_key,
    }, MockProvider.createClient);

    const maybe_client = try registry.makeClient(.{ .provider_id = "mock", .model_id = "mock-model" });
    try std.testing.expect(maybe_client != null);
    maybe_client.?.deinit(std.testing.allocator);
    try std.testing.expect(State.saw_api_key);
}
