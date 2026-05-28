const std = @import("std");
const config = @import("../config/root.zig");
const protocol = @import("protocol.zig");
const types = @import("types.zig");

pub const DiagnosticsSink = struct {
    ptr: *anyopaque,
    on_diagnostics: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        server_id: []const u8,
        root_path: []const u8,
        file_path: []const u8,
        diagnostics: []const types.Diagnostic,
    ) anyerror!void,

    pub fn onDiagnostics(
        self: DiagnosticsSink,
        allocator: std.mem.Allocator,
        server_id: []const u8,
        root_path: []const u8,
        file_path: []const u8,
        diagnostics: []const types.Diagnostic,
    ) anyerror!void {
        return self.on_diagnostics(self.ptr, allocator, server_id, root_path, file_path, diagnostics);
    }
};

pub const LspClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        touch_file: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, file_path: []const u8, wait_for_diagnostics: bool) anyerror!void,
        request_json: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) anyerror![]u8,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn touchFile(self: LspClient, allocator: std.mem.Allocator, file_path: []const u8, wait_for_diagnostics: bool) anyerror!void {
        return self.vtable.touch_file(self.ptr, allocator, file_path, wait_for_diagnostics);
    }

    pub fn requestJson(self: LspClient, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) anyerror![]u8 {
        return self.vtable.request_json(self.ptr, allocator, method, params_json);
    }

    pub fn deinit(self: LspClient, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub const ClientFactory = struct {
    ptr: *anyopaque,
    connect_fn: *const fn (
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        server: config.LspServerConfig,
        root_path: []const u8,
        sink: DiagnosticsSink,
    ) anyerror!LspClient,
    deinit_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    pub fn connect(
        self: ClientFactory,
        allocator: std.mem.Allocator,
        server: config.LspServerConfig,
        root_path: []const u8,
        sink: DiagnosticsSink,
    ) anyerror!LspClient {
        return self.connect_fn(self.ptr, allocator, server, root_path, sink);
    }

    pub fn deinit(self: ClientFactory, allocator: std.mem.Allocator) void {
        self.deinit_fn(self.ptr, allocator);
    }
};

pub fn stdioFactory() ClientFactory {
    return .{
        .ptr = undefined,
        .connect_fn = StdioFactory.connect,
        .deinit_fn = StdioFactory.deinit,
    };
}

const StdioFactory = struct {
    fn connect(
        _: *anyopaque,
        allocator: std.mem.Allocator,
        server: config.LspServerConfig,
        root_path: []const u8,
        sink: DiagnosticsSink,
    ) anyerror!LspClient {
        const client = try StdioLspClient.init(allocator, server, root_path, sink);
        return client.asClient();
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
};

pub const StdioLspClient = struct {
    allocator: std.mem.Allocator,
    server_id: []u8,
    root_path: []u8,
    sink: DiagnosticsSink,
    child: std.process.Child,
    write_mutex: std.atomic.Mutex = .unlocked,
    mutex: std.atomic.Mutex = .unlocked,
    condition: std.Io.Condition = .init,
    next_request_id: i64 = 1,
    responses: std.ArrayListUnmanaged(ResponseRecord) = .empty,
    open_versions: std.StringHashMapUnmanaged(u32) = .empty,
    diagnostic_seq_by_file: std.StringHashMapUnmanaged(u64) = .empty,
    diagnostic_counter: u64 = 0,
    reader_error: ?[]u8 = null,
    closed: bool = false,
    reader_thread: ?std.Thread = null,

    const Self = @This();

    const vtable = LspClient.VTable{
        .touch_file = touchFileErased,
        .request_json = requestJsonErased,
        .deinit = deinitErased,
    };

    const ResponseRecord = struct {
        id: i64,
        ok: bool,
        payload_json: []u8,

        fn deinit(self: *ResponseRecord, allocator: std.mem.Allocator) void {
            allocator.free(self.payload_json);
        }
    };

    pub fn init(
        allocator: std.mem.Allocator,
        server: config.LspServerConfig,
        root_path: []const u8,
        sink: DiagnosticsSink,
    ) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var child = std.process.Child.init(server.command, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = root_path;
        try child.spawn();
        errdefer _ = child.kill() catch {};

        self.* = .{
            .allocator = allocator,
            .server_id = try allocator.dupe(u8, server.id),
            .root_path = try allocator.dupe(u8, root_path),
            .sink = sink,
            .child = child,
        };
        errdefer {
            allocator.free(self.server_id);
            allocator.free(self.root_path);
        }

        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        errdefer {
            self.closed = true;
            _ = self.child.kill() catch {};
            if (self.reader_thread) |thread| thread.join();
        }

        const init_json = server.initialization_json orelse "null";
        const root_uri = try fileUriFromPath(allocator, root_path);
        defer allocator.free(root_uri);
        const initialize_params = try std.fmt.allocPrint(
            allocator,
            "{{\"rootUri\":\"{s}\",\"capabilities\":{{}},\"initializationOptions\":{s}}}",
            .{ root_uri, init_json },
        );
        defer allocator.free(initialize_params);
        const initialize_result = try self.requestJson(allocator, "initialize", initialize_params);
        allocator.free(initialize_result);

        try self.notifyJson("initialized", "{}");
        return self;
    }

    pub fn asClient(self: *Self) LspClient {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    fn touchFileErased(ptr: *anyopaque, allocator: std.mem.Allocator, file_path: []const u8, wait_for_diagnostics: bool) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.touchFile(allocator, file_path, wait_for_diagnostics);
    }

    fn requestJsonErased(ptr: *anyopaque, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) anyerror![]u8 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.requestJson(allocator, method, params_json);
    }

    fn deinitErased(ptr: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.deinit();
        allocator.destroy(self);
    }

    pub fn deinit(self: *Self) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        self.closed = true;
        self.condition.broadcast();
        self.mutex.unlock();

        _ = self.child.kill() catch {};
        if (self.reader_thread) |thread| thread.join();

        while (!self.write_mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.write_mutex.unlock();
        if (self.child.stdin) |*stdin| stdin.close();
        if (self.child.stdout) |*stdout| stdout.close();
        if (self.child.stderr) |*stderr| stderr.close();

        self.allocator.free(self.server_id);
        self.allocator.free(self.root_path);
        if (self.reader_error) |value| self.allocator.free(value);
        for (self.responses.items) |*item| item.deinit(self.allocator);
        self.responses.deinit(self.allocator);
        var version_it = self.open_versions.iterator();
        while (version_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.open_versions.deinit(self.allocator);
        var diag_it = self.diagnostic_seq_by_file.iterator();
        while (diag_it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.diagnostic_seq_by_file.deinit(self.allocator);
    }

    fn touchFile(self: *Self, allocator: std.mem.Allocator, file_path: []const u8, wait_for_diagnostics: bool) !void {
        const contents = try std.Io.Dir.cwd().readFileAlloc(allocator, file_path, 1024 * 1024);
        defer allocator.free(contents);

        const uri = try fileUriFromPath(allocator, file_path);
        defer allocator.free(uri);

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        const previous_seq = self.diagnostic_seq_by_file.get(file_path) orelse 0;
        const version = if (self.open_versions.get(file_path)) |current| current + 1 else 0;
        if (self.open_versions.getPtr(file_path)) |ptr| {
            ptr.* = version;
        } else {
            try self.open_versions.put(self.allocator, try self.allocator.dupe(u8, file_path), version);
        }
        self.mutex.unlock();

        if (version == 0) {
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"textDocument\":{{\"uri\":\"{s}\",\"languageId\":\"{s}\",\"version\":0,\"text\":{f}}}}}",
                .{ uri, languageIdForPath(file_path), std.json.fmt(contents, .{}) },
            );
            defer allocator.free(payload);
            try self.notifyJson("textDocument/didOpen", payload);
        } else {
            const payload = try std.fmt.allocPrint(
                allocator,
                "{{\"textDocument\":{{\"uri\":\"{s}\",\"version\":{d}}},\"contentChanges\":[{{\"text\":{f}}}]}}",
                .{ uri, version, std.json.fmt(contents, .{}) },
            );
            defer allocator.free(payload);
            try self.notifyJson("textDocument/didChange", payload);
        }

        if (wait_for_diagnostics) {
            try self.waitForDiagnostics(file_path, previous_seq, 1500 * std.time.ns_per_ms);
        }
    }

    fn requestJson(self: *Self, allocator: std.mem.Allocator, method: []const u8, params_json: []const u8) ![]u8 {
        const request_id = blk: {
            while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
            defer self.mutex.unlock();
            const id = self.next_request_id;
            self.next_request_id += 1;
            break :blk id;
        };

        const payload = try std.fmt.allocPrint(
            allocator,
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{s}}}",
            .{ request_id, method, params_json },
        );
        defer allocator.free(payload);

        while (!self.write_mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.write_mutex.unlock();
        if (self.child.stdin == null) return error.LspClientClosed;
        try protocol.writeMessage(self.child.stdin.?, payload);
        return self.waitForResponse(allocator, request_id, 5000 * std.time.ns_per_ms);
    }

    fn notifyJson(self: *Self, method: []const u8, params_json: []const u8) !void {
        const payload = try std.fmt.allocPrint(
            self.allocator,
            "{{\"jsonrpc\":\"2.0\",\"method\":\"{s}\",\"params\":{s}}}",
            .{ method, params_json },
        );
        defer self.allocator.free(payload);

        while (!self.write_mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.write_mutex.unlock();
        if (self.child.stdin == null) return error.LspClientClosed;
        try protocol.writeMessage(self.child.stdin.?, payload);
    }

    fn waitForResponse(self: *Self, allocator: std.mem.Allocator, request_id: i64, timeout_ns: u64) ![]u8 {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        while (true) {
            if (self.takeResponseLocked(request_id)) |response_value| {
                var response = response_value;
                defer response.deinit(self.allocator);
                if (!response.ok) return error.LspRequestFailed;
                return allocator.dupe(u8, response.payload_json);
            }
            if (self.reader_error != null) return error.LspReaderFailed;
            if (self.closed) return error.LspClientClosed;
            self.condition.timedWait(&self.mutex, timeout_ns) catch return error.Timeout;
        }
    }

    fn waitForDiagnostics(self: *Self, file_path: []const u8, previous_seq: u64, timeout_ns: u64) !void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        while (true) {
            if ((self.diagnostic_seq_by_file.get(file_path) orelse 0) > previous_seq) return;
            if (self.reader_error != null) return error.LspReaderFailed;
            if (self.closed) return error.LspClientClosed;
            self.condition.timedWait(&self.mutex, timeout_ns) catch return;
        }
    }

    fn takeResponseLocked(self: *Self, request_id: i64) ?ResponseRecord {
        for (self.responses.items, 0..) |item, index| {
            if (item.id != request_id) continue;
            return self.responses.orderedRemove(index);
        }
        return null;
    }

    fn readerMain(self: *Self) void {
        while (true) {
            while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
            const should_stop = self.closed;
            self.mutex.unlock();
            if (should_stop) return;

            const stdout = self.child.stdout orelse return self.failReader("stdout_closed");
            const message = protocol.readMessageAlloc(self.allocator, stdout) catch |err| {
                return self.failReader(@errorName(err));
            };
            defer self.allocator.free(message);
            self.handleIncomingMessage(message) catch |err| {
                self.failReader(@errorName(err));
                return;
            };
        }
    }

    fn handleIncomingMessage(self: *Self, message_json: []const u8) !void {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, message_json, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return;

        if (objectString(parsed.value.object, "method")) |method| {
            if (std.mem.eql(u8, method, "textDocument/publishDiagnostics")) {
                try self.handleDiagnosticsNotification(parsed.value.object);
            }
            return;
        }

        const id = objectInt(parsed.value.object, "id") orelse return;
        const result_value = parsed.value.object.get("result");
        const error_value = parsed.value.object.get("error");
        const payload = if (result_value) |value|
            try stringifyJsonValue(self.allocator, value)
        else if (error_value) |value|
            try stringifyJsonValue(self.allocator, value)
        else
            try self.allocator.dupe(u8, "null");

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        try self.responses.append(self.allocator, .{
            .id = id,
            .ok = result_value != null,
            .payload_json = payload,
        });
        self.condition.broadcast();
    }

    fn handleDiagnosticsNotification(self: *Self, object: std.json.ObjectMap) !void {
        const params = object.get("params") orelse return;
        if (params != .object) return;
        const uri = objectString(params.object, "uri") orelse return;
        const file_path = try pathFromFileUri(self.allocator, uri);
        defer self.allocator.free(file_path);

        const diagnostics_value = params.object.get("diagnostics") orelse return;
        if (diagnostics_value != .array) return;

        const diagnostics = try parseDiagnostics(self.allocator, file_path, diagnostics_value.array.items);
        defer types.freeDiagnostics(self.allocator, diagnostics);

        try self.sink.onDiagnostics(self.allocator, self.server_id, self.root_path, file_path, diagnostics);

        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        self.diagnostic_counter += 1;
        if (self.diagnostic_seq_by_file.getPtr(file_path)) |ptr| {
            ptr.* = self.diagnostic_counter;
        } else {
            try self.diagnostic_seq_by_file.put(self.allocator, try self.allocator.dupe(u8, file_path), self.diagnostic_counter);
        }
        self.condition.broadcast();
    }

    fn failReader(self: *Self, error_name: []const u8) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        if (self.reader_error != null) return;
        self.reader_error = self.allocator.dupe(u8, error_name) catch null;
        self.closed = true;
        self.condition.broadcast();
    }
};

fn parseDiagnostics(allocator: std.mem.Allocator, file_path: []const u8, items: []const std.json.Value) ![]types.Diagnostic {
    const diagnostics = try allocator.alloc(types.Diagnostic, items.len);
    errdefer allocator.free(diagnostics);

    for (items, 0..) |item, index| {
        if (item != .object) return error.InvalidLspDiagnostic;
        const range = item.object.get("range") orelse return error.InvalidLspDiagnostic;
        if (range != .object) return error.InvalidLspDiagnostic;
        const start = range.object.get("start") orelse return error.InvalidLspDiagnostic;
        if (start != .object) return error.InvalidLspDiagnostic;

        diagnostics[index] = .{
            .file_path = try allocator.dupe(u8, file_path),
            .line = @intCast(objectInt(start.object, "line") orelse 0),
            .character = @intCast(objectInt(start.object, "character") orelse 0),
            .severity = if (objectInt(item.object, "severity")) |value| @intCast(value) else null,
            .message = try allocator.dupe(u8, objectString(item.object, "message") orelse ""),
        };
        errdefer diagnostics[index].deinit(allocator);
    }
    return diagnostics;
}

fn objectString(object: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

fn objectInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return switch (value) {
        .integer => |number| number,
        else => null,
    };
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.print("{f}", .{std.json.fmt(value, .{})});
    return allocator.dupe(u8, out.items);
}

fn languageIdForPath(file_path: []const u8) []const u8 {
    const ext = std.fs.path.extension(file_path);
    if (std.mem.eql(u8, ext, ".zig")) return "zig";
    if (std.mem.eql(u8, ext, ".ts")) return "typescript";
    if (std.mem.eql(u8, ext, ".js")) return "javascript";
    if (std.mem.eql(u8, ext, ".py")) return "python";
    return "plaintext";
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

fn pathFromFileUri(allocator: std.mem.Allocator, uri: []const u8) ![]u8 {
    if (!std.mem.startsWith(u8, uri, "file://")) return allocator.dupe(u8, uri);
    var path_text = uri["file://".len..];
    if (path_text.len >= 3 and path_text[0] == '/' and path_text[2] == ':') {
        path_text = path_text[1..];
    }
    const result = try allocator.dupe(u8, path_text);
    if (std.fs.path.sep == '\\') {
        for (result) |*ch| {
            if (ch.* == '/') ch.* = '\\';
        }
    }
    return result;
}

test "file uri conversion round-trips basic absolute paths" {
    const path_text = if (@import("builtin").os.tag == .windows) "C:\\work\\main.zig" else "/tmp/main.zig";
    const uri = try fileUriFromPath(std.testing.allocator, path_text);
    defer std.testing.allocator.free(uri);
    const roundtrip = try pathFromFileUri(std.testing.allocator, uri);
    defer std.testing.allocator.free(roundtrip);
    try std.testing.expectEqualStrings(path_text, roundtrip);
}
