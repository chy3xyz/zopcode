const std = @import("std");
const framework = @import("framework");
const config = @import("../config/root.zig");
const client_model = @import("client.zig");
const server_model = @import("server.zig");
const types = @import("types.zig");

pub const LSP_UPDATED_EVENT_TOPIC = "lsp.updated";
pub const LSP_DIAGNOSTICS_UPDATED_EVENT_TOPIC = "lsp.diagnostics.updated";

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    workspace_dir: []const u8,
    lsp: config.LspConfig,
    client_factory: ?client_model.ClientFactory = null,
};

pub const LspRuntime = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    event_bus: framework.EventBus,
    workspace_dir: []u8,
    enabled: bool,
    servers: []config.LspServerConfig,
    client_factory: client_model.ClientFactory,
    entries: std.ArrayListUnmanaged(*ClientRecord) = .empty,
    diagnostics_by_file: std.StringHashMapUnmanaged([]types.Diagnostic) = .empty,
    mutex: std.atomic.Mutex = .unlocked,

    const Self = @This();

    const ClientRecord = struct {
        server_id: []u8,
        root_path: []u8,
        status: types.StatusKind,
        error_message: ?[]u8 = null,
        client: ?client_model.LspClient = null,

        fn deinit(self: *ClientRecord, allocator: std.mem.Allocator) void {
            allocator.free(self.server_id);
            allocator.free(self.root_path);
            if (self.error_message) |value| allocator.free(value);
            if (self.client) |client| client.deinit(allocator);
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
            .enabled = deps.lsp.enabled,
            .servers = try cloneServers(deps.allocator, deps.lsp.servers),
            .client_factory = deps.client_factory orelse client_model.stdioFactory(),
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
        var iterator = self.diagnostics_by_file.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            types.freeDiagnostics(self.allocator, entry.value_ptr.*);
        }
        self.diagnostics_by_file.deinit(self.allocator);
    }

    pub fn hasServerForFile(self: *Self, file_path: []const u8) bool {
        if (!self.enabled) return false;
        for (self.servers) |server| {
            if (server.disabled) continue;
            if (server_model.matchesFile(server, file_path)) return true;
        }
        return false;
    }

    pub fn touchFile(self: *Self, allocator: std.mem.Allocator, file_path: []const u8, wait_for_diagnostics: bool) ![]types.Diagnostic {
        const record = (try self.ensureClientForFile(file_path)) orelse return allocator.alloc(types.Diagnostic, 0);
        if (record.client) |client| {
            client.touchFile(allocator, file_path, wait_for_diagnostics) catch |err| {
                try self.markRecordError(record, @errorName(err));
                return err;
            };
        } else {
            return allocator.alloc(types.Diagnostic, 0);
        }
        return self.diagnosticsForFile(allocator, file_path);
    }

    pub fn requestOperation(self: *Self, allocator: std.mem.Allocator, request: types.OperationRequest) ![]u8 {
        return switch (request.operation) {
            .workspace_symbols => {
                const record = (try self.ensureAnyClient()) orelse return error.LspServerUnavailable;
                const query = request.query orelse "";
                const params_json = try std.fmt.allocPrint(allocator, "{{\"query\":{f}}}", .{std.json.fmt(query, .{})});
                defer allocator.free(params_json);
                return self.performRequest(allocator, record, "workspace/symbol", params_json);
            },
            .document_symbols => {
                const file_path = request.file_path orelse return error.MissingLspFilePath;
                const record = (try self.ensureClientForFile(file_path)) orelse return error.LspServerUnavailable;
                const uri = try fileUriFromPath(allocator, file_path);
                defer allocator.free(uri);
                const params_json = try std.fmt.allocPrint(allocator, "{{\"textDocument\":{{\"uri\":\"{s}\"}}}}", .{uri});
                defer allocator.free(params_json);
                return self.performRequest(allocator, record, "textDocument/documentSymbol", params_json);
            },
            .hover, .go_to_definition, .find_references, .go_to_implementation => {
                const file_path = request.file_path orelse return error.MissingLspFilePath;
                const line = request.line orelse return error.MissingLspLine;
                const character = request.character orelse return error.MissingLspCharacter;
                const record = (try self.ensureClientForFile(file_path)) orelse return error.LspServerUnavailable;
                const uri = try fileUriFromPath(allocator, file_path);
                defer allocator.free(uri);
                const params_json = if (request.operation == .find_references)
                    try std.fmt.allocPrint(
                        allocator,
                        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}},\"context\":{{\"includeDeclaration\":true}}}}",
                        .{ uri, line, character },
                    )
                else
                    try std.fmt.allocPrint(
                        allocator,
                        "{{\"textDocument\":{{\"uri\":\"{s}\"}},\"position\":{{\"line\":{d},\"character\":{d}}}}}",
                        .{ uri, line, character },
                    );
                defer allocator.free(params_json);
                const method = switch (request.operation) {
                    .hover => "textDocument/hover",
                    .go_to_definition => "textDocument/definition",
                    .find_references => "textDocument/references",
                    .go_to_implementation => "textDocument/implementation",
                    else => unreachable,
                };
                return self.performRequest(allocator, record, method, params_json);
            },
        };
    }

    pub fn diagnosticsForFile(self: *Self, allocator: std.mem.Allocator, file_path: []const u8) ![]types.Diagnostic {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const existing = self.diagnostics_by_file.get(file_path) orelse return allocator.alloc(types.Diagnostic, 0);
        const cloned = try allocator.alloc(types.Diagnostic, existing.len);
        errdefer allocator.free(cloned);
        for (existing, 0..) |item, index| {
            cloned[index] = try item.clone(allocator);
            errdefer cloned[index].deinit(allocator);
        }
        return cloned;
    }

    pub fn renderDiagnosticsSummary(
        self: *Self,
        allocator: std.mem.Allocator,
        file_path: []const u8,
        diagnostics: []const types.Diagnostic,
    ) ![]u8 {
        _ = self;
        if (diagnostics.len == 0) return allocator.alloc(u8, 0);

        var out: std.ArrayListUnmanaged(u8) = .empty;
        defer out.deinit(allocator);
            try out.print(allocator, "LSP diagnostics detected in {s}:\n", .{file_path});
        for (diagnostics, 0..) |item, index| {
            const pretty = try item.pretty(allocator);
            defer allocator.free(pretty);
            if (index > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, pretty);
        }
        return allocator.dupe(u8, out.items);
    }

    pub fn status(self: *Self, allocator: std.mem.Allocator) ![]types.Status {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        var items: std.ArrayListUnmanaged(types.Status) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        for (self.servers) |server| {
            if (!server.disabled) continue;
            try items.append(allocator, .{
                .id = try allocator.dupe(u8, server.id),
                .root = try allocator.dupe(u8, self.workspace_dir),
                .status = .disabled,
            });
        }

        for (self.entries.items) |entry| {
            try items.append(allocator, .{
                .id = try allocator.dupe(u8, entry.server_id),
                .root = try allocator.dupe(u8, entry.root_path),
                .status = entry.status,
                .error_message = if (entry.error_message) |value| try allocator.dupe(u8, value) else null,
            });
        }

        return try items.toOwnedSlice(allocator);
    }

    fn performRequest(self: *Self, allocator: std.mem.Allocator, record: *ClientRecord, method: []const u8, params_json: []const u8) ![]u8 {
        const client = record.client orelse return error.LspServerUnavailable;
        return client.requestJson(allocator, method, params_json) catch |err| {
            try self.markRecordError(record, @errorName(err));
            return err;
        };
    }

    fn ensureAnyClient(self: *Self) !?*ClientRecord {
        if (!self.enabled) return null;
        for (self.servers) |server| {
            if (server.disabled) continue;
            const record = try self.ensureRecord(server, self.workspace_dir);
            if (record.status == .connected) return record;
        }
        return null;
    }

    fn ensureClientForFile(self: *Self, file_path: []const u8) !?*ClientRecord {
        if (!self.enabled) return null;
        for (self.servers) |server| {
            if (server.disabled) continue;
            if (!server_model.matchesFile(server, file_path)) continue;
            const root_path = try server_model.resolveRoot(self.allocator, self.workspace_dir, server, file_path);
            defer self.allocator.free(root_path);
            const record = try self.ensureRecord(server, root_path);
            if (record.status == .connected) return record;
        }
        return null;
    }

    fn ensureRecord(self: *Self, server: config.LspServerConfig, root_path: []const u8) !*ClientRecord {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.server_id, server.id) and std.mem.eql(u8, entry.root_path, root_path)) {
                self.mutex.unlock();
                return entry;
            }
        }
        self.mutex.unlock();

        const record = try self.allocator.create(ClientRecord);
        errdefer self.allocator.destroy(record);
        record.* = .{
            .server_id = try self.allocator.dupe(u8, server.id),
            .root_path = try self.allocator.dupe(u8, root_path),
            .status = .connected,
            .client = null,
        };
        errdefer {
            self.allocator.free(record.server_id);
            self.allocator.free(record.root_path);
        }

        const sink = client_model.DiagnosticsSink{
            .ptr = @ptrCast(self),
            .on_diagnostics = diagnosticsSinkThunk,
        };

        record.client = self.client_factory.connect(self.allocator, server, root_path, sink) catch |err| {
            record.status = .@"error";
            record.error_message = try self.allocator.dupe(u8, @errorName(err));
            try self.appendRecord(record);
            try self.publishStatusEvent(record);
            return record;
        };

        try self.appendRecord(record);
        try self.publishStatusEvent(record);
        return record;
    }

    fn appendRecord(self: *Self, record: *ClientRecord) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        try self.entries.append(self.allocator, record);
    }

    fn markRecordError(self: *Self, record: *ClientRecord, error_name: []const u8) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        if (record.error_message) |value| self.allocator.free(value);
        record.error_message = try self.allocator.dupe(u8, error_name);
        record.status = .@"error";
        try self.publishStatusEventLocked(record);
    }

    fn diagnosticsSinkThunk(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        server_id: []const u8,
        root_path: []const u8,
        file_path: []const u8,
        diagnostics: []const types.Diagnostic,
    ) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = allocator;
        _ = server_id;
        _ = root_path;
        try self.updateDiagnostics(file_path, diagnostics);
    }

    fn updateDiagnostics(self: *Self, file_path: []const u8, diagnostics: []const types.Diagnostic) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        const cloned = try self.allocator.alloc(types.Diagnostic, diagnostics.len);
        errdefer self.allocator.free(cloned);
        for (diagnostics, 0..) |item, index| {
            cloned[index] = try item.clone(self.allocator);
            errdefer cloned[index].deinit(self.allocator);
        }

        if (self.diagnostics_by_file.getPtr(file_path)) |existing| {
            types.freeDiagnostics(self.allocator, existing.*);
            existing.* = cloned;
        } else {
            try self.diagnostics_by_file.put(self.allocator, try self.allocator.dupe(u8, file_path), cloned);
        }
        try self.publishDiagnosticsEventLocked(file_path, diagnostics.len);
    }

    fn publishStatusEvent(self: *Self, record: *ClientRecord) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        try self.publishStatusEventLocked(record);
    }

    fn publishStatusEventLocked(self: *Self, record: *ClientRecord) !void {
        const payload = try encodeJsonAlloc(self.allocator, .{
            .server_id = record.server_id,
            .root = record.root_path,
            .status = record.status.asText(),
            .@"error" = record.error_message,
        });
        defer self.allocator.free(payload);
        _ = try self.event_bus.publish(LSP_UPDATED_EVENT_TOPIC, payload);
    }

    fn publishDiagnosticsEventLocked(self: *Self, file_path: []const u8, count: usize) !void {
        const payload = try encodeJsonAlloc(self.allocator, .{
            .file_path = file_path,
            .count = count,
        });
        defer self.allocator.free(payload);
        _ = try self.event_bus.publish(LSP_DIAGNOSTICS_UPDATED_EVENT_TOPIC, payload);
    }
};

fn cloneServers(allocator: std.mem.Allocator, input: []const config.LspServerConfig) ![]config.LspServerConfig {
    const cloned = try allocator.alloc(config.LspServerConfig, input.len);
    errdefer allocator.free(cloned);
    for (input, 0..) |server, index| {
        cloned[index] = .{
            .id = try allocator.dupe(u8, server.id),
            .disabled = server.disabled,
            .command = try cloneStringSlice(allocator, server.command),
            .extensions = try cloneStringSlice(allocator, server.extensions),
            .root_markers = try cloneStringSlice(allocator, server.root_markers),
            .initialization_json = if (server.initialization_json) |value| try allocator.dupe(u8, value) else null,
        };
        errdefer cloned[index].deinit(allocator);
    }
    return cloned;
}

fn cloneStringSlice(allocator: std.mem.Allocator, input: [][]const u8) ![][]const u8 {
    const cloned = try allocator.alloc([]const u8, input.len);
    errdefer allocator.free(cloned);
    for (input, 0..) |item, index| {
        cloned[index] = try allocator.dupe(u8, item);
    }
    return cloned;
}

fn fileUriFromPath(allocator: std.mem.Allocator, file_path: []const u8) ![]u8 {
    const normalized = try allocator.dupe(u8, file_path);
    defer allocator.free(normalized);
    for (normalized) |*ch| {
        if (ch.* == '\\') ch.* = '/';
    }
    if (std.fs.path.isAbsolute(file_path) and normalized.len >= 2 and normalized[1] == ':') {
        return std.fmt.allocPrint(allocator, "file:///{s}", .{normalized});
    }
    if (std.fs.path.isAbsolute(file_path)) {
        return std.fmt.allocPrint(allocator, "file://{s}", .{normalized});
    }
    return std.fmt.allocPrint(allocator, "file:///{s}", .{normalized});
}

fn encodeJsonAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "{f}", .{std.json.fmt(value, .{})});
    return allocator.dupe(u8, out.items);
}

test "lsp runtime reuses clients and updates diagnostics cache via sink" {
    const MockFactory = struct {
        const State = struct {
            connect_count: usize = 0,
        };

        const MockClient = struct {
            allocator: std.mem.Allocator,
            server_id: []u8,
            root_path: []u8,
            sink: client_model.DiagnosticsSink,

            const vtable = client_model.LspClient.VTable{
                .touch_file = touchFileErased,
                .request_json = requestJsonErased,
                .deinit = deinitErased,
            };

            fn asClient(self: *@This()) client_model.LspClient {
                return .{ .ptr = @ptrCast(self), .vtable = &vtable };
            }

            fn touchFileErased(ptr: *anyopaque, allocator: std.mem.Allocator, file_path: []const u8, wait_for_diagnostics: bool) anyerror!void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                _ = wait_for_diagnostics;
                const diagnostics = try allocator.alloc(types.Diagnostic, 1);
                diagnostics[0] = .{
                    .file_path = try allocator.dupe(u8, file_path),
                    .line = 0,
                    .character = 0,
                    .severity = 1,
                    .message = try allocator.dupe(u8, "mock diagnostic"),
                };
                defer types.freeDiagnostics(allocator, diagnostics);
                try self.sink.onDiagnostics(allocator, self.server_id, self.root_path, file_path, diagnostics);
            }

            fn requestJsonErased(_: *anyopaque, allocator: std.mem.Allocator, method: []const u8, _: []const u8) anyerror![]u8 {
                return std.fmt.allocPrint(allocator, "[{{\"method\":\"{s}\"}}]", .{method});
            }

            fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
                const self: *@This() = @ptrCast(@alignCast(ptr));
                allocator.free(self.server_id);
                allocator.free(self.root_path);
                allocator.destroy(self);
            }
        };

        fn connect(
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            server: config.LspServerConfig,
            root_path: []const u8,
            sink: client_model.DiagnosticsSink,
        ) anyerror!client_model.LspClient {
            const state: *State = @ptrCast(@alignCast(ptr));
            state.connect_count += 1;
            const client = try allocator.create(MockClient);
            client.* = .{
                                .server_id = try allocator.dupe(u8, server.id),
                .root_path = try allocator.dupe(u8, root_path),
                .sink = sink,
            };
            return client.asClient();
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try std.testing.allocator.dupe(u8, ".");
    defer std.testing.allocator.free(root_path);
    const workspace_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "workspace" });
    defer std.testing.allocator.free(workspace_dir);
    const src_dir = try std.fs.path.join(std.testing.allocator, &.{ workspace_dir, "src" });
    defer std.testing.allocator.free(src_dir);
    _ = std.c.mkdir(@ptrCast(src_dir.ptr), 0o755);

    const marker_path = try std.fs.path.join(std.testing.allocator, &.{ workspace_dir, "build.zig" });
    defer std.testing.allocator.free(marker_path);
    var marker = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), marker_path, .{});
    defer marker.close(std.Io.Threaded.global_single_threaded.*.io());
    try marker.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "test");

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ src_dir, "main.zig" });
    defer std.testing.allocator.free(file_path);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), file_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "const x = 1;");

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 64);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    var factory_state = MockFactory.State{};
    const factory = client_model.ClientFactory{
        .ptr = @ptrCast(&factory_state),
        .connect_fn = MockFactory.connect,
        .deinit_fn = MockFactory.deinit,
    };

    const command_items = [_][]const u8{"zls"};
    const extension_items = [_][]const u8{".zig"};
    const marker_items = [_][]const u8{"build.zig"};
    const server_cfg = [_]config.LspServerConfig{
        .{
            .id = "zls",
            .command = @constCast(command_items[0..]),
            .extensions = @constCast(extension_items[0..]),
            .root_markers = @constCast(marker_items[0..]),
        },
    };
    const lsp_cfg = config.LspConfig{
        .enabled = true,
        .servers = @constCast(server_cfg[0..]),
    };

    const runtime = try LspRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
        .workspace_dir = workspace_dir,
        .lsp = lsp_cfg,
        .client_factory = factory,
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    const first = try runtime.touchFile(std.testing.allocator, file_path, true);
    defer types.freeDiagnostics(std.testing.allocator, first);
    try std.testing.expectEqual(@as(usize, 1), first.len);

    const second = try runtime.touchFile(std.testing.allocator, file_path, true);
    defer types.freeDiagnostics(std.testing.allocator, second);
    try std.testing.expectEqual(@as(usize, 1), second.len);
    try std.testing.expectEqual(@as(usize, 1), factory_state.connect_count);

    const result = try runtime.requestOperation(std.testing.allocator, .{
        .operation = .document_symbols,
        .file_path = file_path,
    });
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "textDocument/documentSymbol") != null);

    const statuses = try runtime.status(std.testing.allocator);
    defer {
        for (statuses) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(statuses);
    }
    try std.testing.expectEqual(@as(usize, 1), statuses.len);
    try std.testing.expectEqual(types.StatusKind.connected, statuses[0].status);
}

test "lsp runtime keeps failed server entries in error state and does not treat them as connected" {
    const FailingFactory = struct {
        const State = struct {
            connect_count: usize = 0,
        };

        fn connect(
            ptr: *anyopaque,
            _: std.mem.Allocator,
            _: config.LspServerConfig,
            _: []const u8,
            _: client_model.DiagnosticsSink,
        ) anyerror!client_model.LspClient {
            const state: *State = @ptrCast(@alignCast(ptr));
            state.connect_count += 1;
            return error.MockLspConnectFailed;
        }

        fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
    };

    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try std.testing.allocator.dupe(u8, ".");
    defer std.testing.allocator.free(root_path);
    const workspace_dir = try std.fs.path.join(std.testing.allocator, &.{ root_path, "workspace" });
    defer std.testing.allocator.free(workspace_dir);
    const src_dir = try std.fs.path.join(std.testing.allocator, &.{ workspace_dir, "src" });
    defer std.testing.allocator.free(src_dir);
    _ = std.c.mkdir(@ptrCast(src_dir.ptr), 0o755);

    const marker_path = try std.fs.path.join(std.testing.allocator, &.{ workspace_dir, "build.zig" });
    defer std.testing.allocator.free(marker_path);
    var marker = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), marker_path, .{});
    defer marker.close(std.Io.Threaded.global_single_threaded.*.io());
    try marker.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "test");

    const file_path = try std.fs.path.join(std.testing.allocator, &.{ src_dir, "main.zig" });
    defer std.testing.allocator.free(file_path);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), file_path, .{});
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "const x = 1;");

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 64);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();
    var event_bus = framework.MemoryEventBus.init(std.testing.allocator);
    defer event_bus.deinit();

    var factory_state = FailingFactory.State{};
    const factory = client_model.ClientFactory{
        .ptr = @ptrCast(&factory_state),
        .connect_fn = FailingFactory.connect,
        .deinit_fn = FailingFactory.deinit,
    };

    const command_items = [_][]const u8{"zls"};
    const extension_items = [_][]const u8{".zig"};
    const marker_items = [_][]const u8{"build.zig"};
    const server_cfg = [_]config.LspServerConfig{
        .{
            .id = "zls",
            .command = @constCast(command_items[0..]),
            .extensions = @constCast(extension_items[0..]),
            .root_markers = @constCast(marker_items[0..]),
        },
    };
    const lsp_cfg = config.LspConfig{
        .enabled = true,
        .servers = @constCast(server_cfg[0..]),
    };

    const runtime = try LspRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .event_bus = event_bus.asEventBus(),
        .workspace_dir = workspace_dir,
        .lsp = lsp_cfg,
        .client_factory = factory,
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    try std.testing.expect(runtime.hasServerForFile(file_path));

    const diagnostics = try runtime.touchFile(std.testing.allocator, file_path, true);
    defer types.freeDiagnostics(std.testing.allocator, diagnostics);
    try std.testing.expectEqual(@as(usize, 0), diagnostics.len);

    const statuses = try runtime.status(std.testing.allocator);
    defer {
        for (statuses) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(statuses);
    }

    try std.testing.expectEqual(@as(usize, 1), statuses.len);
    try std.testing.expectEqual(types.StatusKind.@"error", statuses[0].status);
    try std.testing.expect(statuses[0].error_message != null);
    try std.testing.expectEqualStrings("MockLspConnectFailed", statuses[0].error_message.?);

    try std.testing.expectError(error.LspServerUnavailable, runtime.requestOperation(std.testing.allocator, .{
        .operation = .document_symbols,
        .file_path = file_path,
    }));

    const repeated = try runtime.touchFile(std.testing.allocator, file_path, true);
    defer types.freeDiagnostics(std.testing.allocator, repeated);
    try std.testing.expectEqual(@as(usize, 0), repeated.len);
    try std.testing.expectEqual(@as(usize, 1), factory_state.connect_count);
}
