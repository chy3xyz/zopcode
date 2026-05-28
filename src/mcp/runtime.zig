const std = @import("std");
const framework = @import("framework");
const config = @import("../config/root.zig");
const transport = @import("transport.zig");
const types = @import("types.zig");

pub const MCP_UPDATED_EVENT_TOPIC = "mcp.updated";

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    workspace_dir: []const u8,
    mcp: config.McpConfig,
    client_factory: ?transport.ClientFactory = null,
};

pub const McpRuntime = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    workspace_dir: []u8,
    servers: []config.McpServerConfig,
    client_factory: transport.ClientFactory,
    entries: std.ArrayListUnmanaged(*Record) = .empty,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const Record = struct {
        server_id: []u8,
        transport_name: []u8,
        status: types.StatusKind,
        error_message: ?[]u8 = null,
        client: ?transport.McpClient = null,
        tools: []types.ToolInfo,
        resources: []types.ResourceInfo,

        fn deinit(self: *Record, allocator: std.mem.Allocator) void {
            allocator.free(self.server_id);
            allocator.free(self.transport_name);
            if (self.error_message) |value| allocator.free(value);
            if (self.client) |client| client.deinit(allocator);
            types.freeTools(allocator, self.tools);
            types.freeResources(allocator, self.resources);
        }
    };

    pub fn init(deps: Dependencies) !*Self {
        const self = try deps.allocator.create(Self);
        errdefer deps.allocator.destroy(self);

        self.* = .{
            .allocator = deps.allocator,
            .logger = deps.logger,
            .event_bus = deps.event_bus,
            .workspace_dir = try deps.allocator.dupe(u8, deps.workspace_dir),
            .servers = try cloneServers(deps.allocator, deps.mcp.servers),
            .client_factory = deps.client_factory orelse transport.defaultFactory(),
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        self.client_factory.deinit(self.allocator);
        self.allocator.free(self.workspace_dir);
        for (self.servers) |*server| server.deinit(self.allocator);
        self.allocator.free(self.servers);
        for (self.entries.items) |entry| {
            entry.deinit(self.allocator);
            self.allocator.destroy(entry);
        }
        self.entries.deinit(self.allocator);
    }

    pub fn connectAll(self: *Self) !void {
        for (self.servers) |server| {
            if (server.disabled) continue;
            _ = try self.ensureRecord(server);
        }
    }

    pub fn connect(self: *Self, server_id: []const u8) !bool {
        for (self.servers) |server| {
            if (!std.mem.eql(u8, server.id, server_id)) continue;
            if (server.disabled) return false;
            try self.removeRecord(server_id);
            _ = try self.ensureRecord(server);
            return true;
        }
        return false;
    }

    pub fn disconnect(self: *Self, server_id: []const u8) !bool {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const record = self.recordByIdLocked(server_id) orelse return false;
        if (record.client) |client| client.deinit(self.allocator);
        record.client = null;
        types.freeTools(self.allocator, record.tools);
        types.freeResources(self.allocator, record.resources);
        record.tools = try self.allocator.alloc(types.ToolInfo, 0);
        record.resources = try self.allocator.alloc(types.ResourceInfo, 0);
        if (record.error_message) |value| self.allocator.free(value);
        record.error_message = null;
        record.status = .disabled;
        try self.publishStatusEventLocked(record);
        return true;
    }

    pub fn status(self: *Self, allocator: std.mem.Allocator) ![]types.Status {
        try self.connectAll();

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        var items: std.ArrayListUnmanaged(types.Status) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        for (self.servers) |server| {
            if (server.disabled) {
                try items.append(allocator, .{
                    .id = try allocator.dupe(u8, server.id),
                    .transport = try allocator.dupe(u8, server.transport.asText()),
                    .status = .disabled,
                });
                continue;
            }

            if (self.recordByIdLocked(server.id)) |record| {
                try items.append(allocator, .{
                    .id = try allocator.dupe(u8, record.server_id),
                    .transport = try allocator.dupe(u8, record.transport_name),
                    .status = record.status,
                    .error_message = if (record.error_message) |value| try allocator.dupe(u8, value) else null,
                    .tool_count = @intCast(record.tools.len),
                    .resource_count = @intCast(record.resources.len),
                });
            }
        }

        return try items.toOwnedSlice(allocator);
    }

    pub fn listTools(self: *Self, allocator: std.mem.Allocator) ![]types.ToolInfo {
        try self.connectAll();

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        var items: std.ArrayListUnmanaged(types.ToolInfo) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        for (self.entries.items) |record| {
            if (record.status != .connected) continue;
            for (record.tools) |tool| try items.append(allocator, try tool.clone(allocator));
        }

        return try items.toOwnedSlice(allocator);
    }

    pub fn listResources(self: *Self, allocator: std.mem.Allocator, server_id: ?[]const u8) ![]types.ResourceInfo {
        try self.connectAll();

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        var items: std.ArrayListUnmanaged(types.ResourceInfo) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        for (self.entries.items) |record| {
            if (record.status != .connected) continue;
            if (server_id) |id| {
                if (!std.mem.eql(u8, record.server_id, id)) continue;
            }
            for (record.resources) |item| try items.append(allocator, try item.clone(allocator));
        }

        return try items.toOwnedSlice(allocator);
    }

    pub fn readResource(self: *Self, allocator: std.mem.Allocator, server_id: []const u8, uri: []const u8) !types.ResourceContent {
        const record = try self.connectedRecord(server_id);
        return record.client.?.readResource(allocator, uri);
    }

    pub fn callTool(self: *Self, allocator: std.mem.Allocator, server_id: []const u8, tool_name: []const u8, input_json: []const u8) !types.ToolCallResult {
        const record = try self.connectedRecord(server_id);
        return record.client.?.callTool(allocator, tool_name, input_json);
    }

    fn connectedRecord(self: *Self, server_id: []const u8) !*Record {
        try self.connectAll();

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const record = self.recordByIdLocked(server_id) orelse return error.McpServerNotFound;
        if (record.status != .connected or record.client == null) return error.McpServerUnavailable;
        return record;
    }

    fn ensureRecord(self: *Self, server: config.McpServerConfig) !*Record {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        if (self.recordByIdLocked(server.id)) |existing| {
            self.mutex.unlock();
            return existing;
        }
        self.mutex.unlock();

        const record = try self.allocator.create(Record);
        errdefer self.allocator.destroy(record);
        record.* = .{
            .server_id = try self.allocator.dupe(u8, server.id),
            .transport_name = try self.allocator.dupe(u8, server.transport.asText()),
            .status = .failed,
            .client = null,
            .tools = try self.allocator.alloc(types.ToolInfo, 0),
            .resources = try self.allocator.alloc(types.ResourceInfo, 0),
        };
        errdefer {
            self.allocator.free(record.server_id);
            self.allocator.free(record.transport_name);
            self.allocator.free(record.tools);
            self.allocator.free(record.resources);
        }

        const client = self.client_factory.connect(self.allocator, server, self.workspace_dir) catch |err| {
            record.error_message = try self.allocator.dupe(u8, @errorName(err));
            record.status = .failed;
            try self.appendRecord(record);
            try self.publishStatusEvent(record);
            return record;
        };

        record.client = client;
        record.status = .connected;

        const tools = client.listTools(self.allocator) catch |err| {
            if (record.client) |connected| connected.deinit(self.allocator);
            record.client = null;
            if (record.error_message) |value| self.allocator.free(value);
            record.error_message = try self.allocator.dupe(u8, @errorName(err));
            record.status = .failed;
            try self.appendRecord(record);
            try self.publishStatusEvent(record);
            return record;
        };

        const resources = client.listResources(self.allocator) catch |err| {
            types.freeTools(self.allocator, tools);
            if (record.client) |connected| connected.deinit(self.allocator);
            record.client = null;
            if (record.error_message) |value| self.allocator.free(value);
            record.error_message = try self.allocator.dupe(u8, @errorName(err));
            record.status = .failed;
            try self.appendRecord(record);
            try self.publishStatusEvent(record);
            return record;
        };

        types.freeTools(self.allocator, record.tools);
        types.freeResources(self.allocator, record.resources);
        record.tools = tools;
        record.resources = resources;
        try self.appendRecord(record);
        try self.publishStatusEvent(record);
        return record;
    }

    fn appendRecord(self: *Self, record: *Record) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        try self.entries.append(self.allocator, record);
    }

    fn removeRecord(self: *Self, server_id: []const u8) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        for (self.entries.items, 0..) |entry, index| {
            if (!std.mem.eql(u8, entry.server_id, server_id)) continue;
            const removed = self.entries.orderedRemove(index);
            removed.deinit(self.allocator);
            self.allocator.destroy(removed);
            return;
        }
    }

    fn recordByIdLocked(self: *Self, server_id: []const u8) ?*Record {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.server_id, server_id)) return entry;
        }
        return null;
    }

    fn publishStatusEvent(self: *Self, record: *Record) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        try self.publishStatusEventLocked(record);
    }

    fn publishStatusEventLocked(self: *Self, record: *Record) !void {
        const payload = try encodeJsonAlloc(self.allocator, .{
            .server_id = record.server_id,
            .transport = record.transport_name,
            .status = record.status.asText(),
            .@"error" = record.error_message,
            .tool_count = record.tools.len,
            .resource_count = record.resources.len,
        });
        defer self.allocator.free(payload);
        _ = try self.event_bus.publish(MCP_UPDATED_EVENT_TOPIC, payload);
    }
};

fn cloneServers(allocator: std.mem.Allocator, input: []const config.McpServerConfig) ![]config.McpServerConfig {
    const cloned = try allocator.alloc(config.McpServerConfig, input.len);
    errdefer allocator.free(cloned);
    for (input, 0..) |server, index| {
        cloned[index] = .{
            .id = try allocator.dupe(u8, server.id),
            .transport = server.transport,
            .disabled = server.disabled,
            .command = try cloneStringSlice(allocator, server.command),
            .url = if (server.url) |value| try allocator.dupe(u8, value) else null,
            .timeout_ms = server.timeout_ms,
        };
        errdefer cloned[index].deinit(allocator);
    }
    return cloned;
}

fn cloneStringSlice(allocator: std.mem.Allocator, input: [][]const u8) ![][]const u8 {
    const cloned = try allocator.alloc([]const u8, input.len);
    errdefer allocator.free(cloned);
    for (input, 0..) |item, index| cloned[index] = try allocator.dupe(u8, item);
    return cloned;
}

fn encodeJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.print("{f}", .{std.json.fmt(value, .{})});
    return allocator.dupe(u8, out.items);
}

test "mcp runtime tracks connected disabled and failed server states" {
    const MockFactory = struct {
        const MockClient = struct {
            server_id: []u8,

            const vtable = transport.McpClient.VTable{
                .list_tools = listToolsErased,
                .call_tool = callToolErased,
                .list_resources = listResourcesErased,
                .read_resource = readResourceErased,
                .deinit = deinitErased,
            };

            fn asClient(self: *@This()) transport.McpClient {
                return .{ .ptr = @ptrCast(self), .vtable = &vtable };
            }

            fn listToolsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ToolInfo {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const items = try allocator.alloc(types.ToolInfo, 1);
                items[0] = .{
                    .server_id = try allocator.dupe(u8, self.server_id),
                    .name = try allocator.dupe(u8, "echo"),
                    .description = try allocator.dupe(u8, "Echo"),
                    .input_schema_json = try allocator.dupe(u8, "{\"type\":\"object\"}"),
                };
                return items;
            }

            fn callToolErased(_: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8, input_json: []const u8) anyerror!types.ToolCallResult {
                return .{
                    .output_text = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ tool_name, input_json }),
                    .metadata_json = try allocator.dupe(u8, "{\"ok\":true}"),
                };
            }

            fn listResourcesErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ResourceInfo {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                const items = try allocator.alloc(types.ResourceInfo, 1);
                items[0] = .{
                    .server_id = try allocator.dupe(u8, self.server_id),
                    .uri = try allocator.dupe(u8, "mcp://docs/readme"),
                    .name = try allocator.dupe(u8, "README"),
                };
                return items;
            }

            fn readResourceErased(ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror!types.ResourceContent {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                return .{
                    .server_id = try allocator.dupe(u8, self.server_id),
                    .uri = try allocator.dupe(u8, uri),
                    .text = try allocator.dupe(u8, "resource text"),
                };
            }

            fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                allocator.free(self.server_id);
                allocator.destroy(self);
            }
        };

        fn connect(_: *anyopaque, allocator: std.mem.Allocator, server: config.McpServerConfig, _: []const u8) anyerror!transport.McpClient {
            if (std.mem.eql(u8, server.id, "broken")) return error.MockMcpConnectFailed;
            const client = try allocator.create(MockClient);
            client.* = .{
                .server_id = try allocator.dupe(u8, server.id),
            };
            return client.asClient();
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 64);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    const local_cmd = [_][]const u8{"mock"};
    const servers = [_]config.McpServerConfig{
        .{ .id = "docs", .transport = .local, .command = @constCast(local_cmd[0..]) },
        .{ .id = "disabled", .transport = .remote, .disabled = true, .command = &.{}, .url = "http://example.invalid" },
        .{ .id = "broken", .transport = .local, .command = @constCast(local_cmd[0..]) },
    };

    const runtime = try McpRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
        .workspace_dir = ".",
        .mcp = .{ .servers = @constCast(servers[0..]) },
        .client_factory = .{
            .ptr = undefined,
            .connect_fn = MockFactory.connect,
            .deinit_fn = MockFactory.deinit,
        },
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    const statuses = try runtime.status(std.testing.allocator);
    defer types.freeStatuses(std.testing.allocator, statuses);
    try std.testing.expectEqual(@as(usize, 3), statuses.len);
}

test "mcp runtime exposes connected tools and resource reads" {
    const MockFactory = struct {
        const MockClient = struct {
            const vtable = transport.McpClient.VTable{
                .list_tools = listToolsErased,
                .call_tool = callToolErased,
                .list_resources = listResourcesErased,
                .read_resource = readResourceErased,
                .deinit = deinitErased,
            };

            fn asClient(self: *@This()) transport.McpClient {
                return .{ .ptr = @ptrCast(self), .vtable = &vtable };
            }

            fn listToolsErased(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ToolInfo {
                const items = try allocator.alloc(types.ToolInfo, 1);
                items[0] = .{
                    .server_id = try allocator.dupe(u8, "docs"),
                    .name = try allocator.dupe(u8, "echo"),
                    .description = try allocator.dupe(u8, "Echo"),
                    .input_schema_json = try allocator.dupe(u8, "{\"type\":\"object\"}"),
                };
                return items;
            }

            fn callToolErased(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!types.ToolCallResult {
                return .{
                    .output_text = try allocator.dupe(u8, "tool output"),
                    .metadata_json = try allocator.dupe(u8, "{\"ok\":true}"),
                };
            }

            fn listResourcesErased(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ResourceInfo {
                const items = try allocator.alloc(types.ResourceInfo, 1);
                items[0] = .{
                    .server_id = try allocator.dupe(u8, "docs"),
                    .uri = try allocator.dupe(u8, "mcp://docs/readme"),
                    .name = try allocator.dupe(u8, "README"),
                };
                return items;
            }

            fn readResourceErased(_: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror!types.ResourceContent {
                return .{
                    .server_id = try allocator.dupe(u8, "docs"),
                    .uri = try allocator.dupe(u8, uri),
                    .text = try allocator.dupe(u8, "hello from resource"),
                };
            }

            fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                allocator.destroy(self);
            }
        };

        fn connect(_: *anyopaque, allocator: std.mem.Allocator, _: config.McpServerConfig, _: []const u8) anyerror!transport.McpClient {
            const client = try allocator.create(MockClient);
            client.* = .{};
            return client.asClient();
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 64);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    const local_cmd = [_][]const u8{"mock"};
    const servers = [_]config.McpServerConfig{
        .{ .id = "docs", .transport = .local, .command = @constCast(local_cmd[0..]) },
    };

    const runtime = try McpRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
        .workspace_dir = ".",
        .mcp = .{ .servers = @constCast(servers[0..]) },
        .client_factory = .{
            .ptr = undefined,
            .connect_fn = MockFactory.connect,
            .deinit_fn = MockFactory.deinit,
        },
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    const tools_list = try runtime.listTools(std.testing.allocator);
    defer types.freeTools(std.testing.allocator, tools_list);
    try std.testing.expectEqual(@as(usize, 1), tools_list.len);

    const resources_list = try runtime.listResources(std.testing.allocator, null);
    defer types.freeResources(std.testing.allocator, resources_list);
    try std.testing.expectEqual(@as(usize, 1), resources_list.len);

    var content = try runtime.readResource(std.testing.allocator, "docs", "mcp://docs/readme");
    defer content.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("hello from resource", content.text);
}

test "mcp runtime disconnect updates status to disabled" {
    const MockFactory = struct {
        const MockClient = struct {
            const vtable = transport.McpClient.VTable{
                .list_tools = listToolsErased,
                .call_tool = callToolErased,
                .list_resources = listResourcesErased,
                .read_resource = readResourceErased,
                .deinit = deinitErased,
            };

            fn asClient(self: *@This()) transport.McpClient {
                return .{ .ptr = @ptrCast(self), .vtable = &vtable };
            }

            fn listToolsErased(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ToolInfo {
                return allocator.alloc(types.ToolInfo, 0);
            }

            fn callToolErased(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, _: []const u8) anyerror!types.ToolCallResult {
                return .{
                    .output_text = try allocator.dupe(u8, ""),
                    .metadata_json = try allocator.dupe(u8, "{}"),
                };
            }

            fn listResourcesErased(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ResourceInfo {
                return allocator.alloc(types.ResourceInfo, 0);
            }

            fn readResourceErased(_: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror!types.ResourceContent {
                return .{
                    .server_id = try allocator.dupe(u8, "docs"),
                    .uri = try allocator.dupe(u8, uri),
                    .text = try allocator.dupe(u8, ""),
                };
            }

            fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                allocator.destroy(self);
            }
        };

        fn connect(_: *anyopaque, allocator: std.mem.Allocator, _: config.McpServerConfig, _: []const u8) anyerror!transport.McpClient {
            const client = try allocator.create(MockClient);
            client.* = .{};
            return client.asClient();
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 64);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    const local_cmd = [_][]const u8{"mock"};
    const servers = [_]config.McpServerConfig{
        .{ .id = "docs", .transport = .local, .command = @constCast(local_cmd[0..]) },
    };

    const runtime = try McpRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
        .workspace_dir = ".",
        .mcp = .{ .servers = @constCast(servers[0..]) },
        .client_factory = .{
            .ptr = undefined,
            .connect_fn = MockFactory.connect,
            .deinit_fn = MockFactory.deinit,
        },
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    const initial_statuses = try runtime.status(std.testing.allocator);
    types.freeStatuses(std.testing.allocator, initial_statuses);
    try std.testing.expect(try runtime.disconnect("docs"));

    {
        const statuses = try runtime.status(std.testing.allocator);
        defer types.freeStatuses(std.testing.allocator, statuses);
        try std.testing.expectEqual(types.StatusKind.disabled, statuses[0].status);
    }

    try std.testing.expect(try runtime.connect("docs"));
    {
        const statuses = try runtime.status(std.testing.allocator);
        defer types.freeStatuses(std.testing.allocator, statuses);
        try std.testing.expectEqual(types.StatusKind.connected, statuses[0].status);
    }
}
