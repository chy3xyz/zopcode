const std = @import("std");
const config = @import("../config/root.zig");
const protocol = @import("../lsp/protocol.zig");
const types = @import("types.zig");

pub const McpClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        list_tools: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ToolInfo,
        call_tool: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8, input_json: []const u8) anyerror!types.ToolCallResult,
        list_resources: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ResourceInfo,
        read_resource: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror!types.ResourceContent,
        deinit: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,
    };

    pub fn listTools(self: McpClient, allocator: std.mem.Allocator) anyerror![]types.ToolInfo {
        return self.vtable.list_tools(self.ptr, allocator);
    }

    pub fn callTool(self: McpClient, allocator: std.mem.Allocator, tool_name: []const u8, input_json: []const u8) anyerror!types.ToolCallResult {
        return self.vtable.call_tool(self.ptr, allocator, tool_name, input_json);
    }

    pub fn listResources(self: McpClient, allocator: std.mem.Allocator) anyerror![]types.ResourceInfo {
        return self.vtable.list_resources(self.ptr, allocator);
    }

    pub fn readResource(self: McpClient, allocator: std.mem.Allocator, uri: []const u8) anyerror!types.ResourceContent {
        return self.vtable.read_resource(self.ptr, allocator, uri);
    }

    pub fn deinit(self: McpClient, allocator: std.mem.Allocator) void {
        self.vtable.deinit(self.ptr, allocator);
    }
};

pub const ClientFactory = struct {
    ptr: *anyopaque,
    connect_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, server: config.McpServerConfig, workspace_dir: []const u8) anyerror!McpClient,
    deinit_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void,

    pub fn connect(self: ClientFactory, allocator: std.mem.Allocator, server: config.McpServerConfig, workspace_dir: []const u8) anyerror!McpClient {
        return self.connect_fn(self.ptr, allocator, server, workspace_dir);
    }

    pub fn deinit(self: ClientFactory, allocator: std.mem.Allocator) void {
        self.deinit_fn(self.ptr, allocator);
    }
};

pub fn defaultFactory() ClientFactory {
    return .{
        .ptr = undefined,
        .connect_fn = DefaultFactory.connect,
        .deinit_fn = DefaultFactory.deinit,
    };
}

const DefaultFactory = struct {
    fn connect(_: *anyopaque, allocator: std.mem.Allocator, server: config.McpServerConfig, workspace_dir: []const u8) anyerror!McpClient {
        switch (server.transport) {
            .local => {
                const client = try StdioMcpClient.init(allocator, server, workspace_dir);
                return client.asClient();
            },
            .remote => return error.RemoteMcpTransportUnsupported,
        }
    }

    fn deinit(_: *anyopaque, _: std.mem.Allocator) void {}
};

pub const StdioMcpClient = struct {
    allocator: std.mem.Allocator,
    server_id: []u8,
    child: std.process.Child,
    write_mutex: std.atomic.Mutex = .unlocked,
    mutex: std.atomic.Mutex = .unlocked,
    condition: std.Io.Condition = .init,
    next_request_id: i64 = 1,
    responses: std.ArrayListUnmanaged(ResponseRecord) = .empty,
    reader_error: ?[]u8 = null,
    closed: bool = false,
    reader_thread: ?std.Thread = null,

    const Self = @This();

    const vtable = McpClient.VTable{
        .list_tools = listToolsErased,
        .call_tool = callToolErased,
        .list_resources = listResourcesErased,
        .read_resource = readResourceErased,
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

    pub fn init(allocator: std.mem.Allocator, server: config.McpServerConfig, workspace_dir: []const u8) !*Self {
        if (server.command.len == 0) return error.InvalidMcpCommand;

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        var child = std.process.Child{ .id = 0, .thread_handle = undefined, .stdin = undefined, .stdout = undefined, .stderr = undefined }; // Zig17 stub
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = workspace_dir;
        try child.spawn();
        errdefer _ = child.kill() catch {};

        self.* = .{
            .allocator = allocator,
            .server_id = try allocator.dupe(u8, server.id),
            .child = child,
        };
        errdefer allocator.free(self.server_id);

        self.reader_thread = try std.Thread.spawn(.{}, readerMain, .{self});
        errdefer {
            self.closed = true;
            _ = self.child.kill() catch {};
            if (self.reader_thread) |thread| thread.join();
        }

        const initialize_params =
            \\{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"zopcode","version":"0.1.0"}}
        ;
        const initialize_result = try self.requestJson(allocator, "initialize", initialize_params);
        allocator.free(initialize_result);
        self.notifyJson("notifications/initialized", "{}") catch {};
        return self;
    }

    pub fn asClient(self: *Self) McpClient {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn listToolsErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ToolInfo {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.listTools(allocator);
    }

    fn callToolErased(ptr: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8, input_json: []const u8) anyerror!types.ToolCallResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.callTool(allocator, tool_name, input_json);
    }

    fn listResourcesErased(ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]types.ResourceInfo {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.listResources(allocator);
    }

    fn readResourceErased(ptr: *anyopaque, allocator: std.mem.Allocator, uri: []const u8) anyerror!types.ResourceContent {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return self.readResource(allocator, uri);
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
        if (self.reader_error) |value| self.allocator.free(value);
        for (self.responses.items) |*item| item.deinit(self.allocator);
        self.responses.deinit(self.allocator);
    }

    fn listTools(self: *Self, allocator: std.mem.Allocator) ![]types.ToolInfo {
        const payload = try self.requestJson(allocator, "tools/list", "{}");
        defer allocator.free(payload);
        return parseToolsPayload(allocator, self.server_id, payload);
    }

    fn callTool(self: *Self, allocator: std.mem.Allocator, tool_name: []const u8, input_json: []const u8) !types.ToolCallResult {
        const params = try std.fmt.allocPrint(
            allocator,
            "{{\"name\":{f},\"arguments\":{s}}}",
            .{ std.json.fmt(tool_name, .{}), input_json },
        );
        defer allocator.free(params);

        const payload = try self.requestJson(allocator, "tools/call", params);
        defer allocator.free(payload);

        const output_text = try extractToolCallText(allocator, payload);
        errdefer allocator.free(output_text);
        return .{
            .output_text = output_text,
            .metadata_json = try allocator.dupe(u8, payload),
        };
    }

    fn listResources(self: *Self, allocator: std.mem.Allocator) ![]types.ResourceInfo {
        const payload = try self.requestJson(allocator, "resources/list", "{}");
        defer allocator.free(payload);
        return parseResourcesPayload(allocator, self.server_id, payload);
    }

    fn readResource(self: *Self, allocator: std.mem.Allocator, uri: []const u8) !types.ResourceContent {
        const params = try std.fmt.allocPrint(allocator, "{{\"uri\":{f}}}", .{std.json.fmt(uri, .{})});
        defer allocator.free(params);

        const payload = try self.requestJson(allocator, "resources/read", params);
        defer allocator.free(payload);

        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidMcpResourcePayload;
        const contents_value = parsed.value.object.get("contents") orelse return error.InvalidMcpResourcePayload;
        if (contents_value != .array or contents_value.array.items.len == 0) return error.InvalidMcpResourcePayload;
        const first = contents_value.array.items[0];
        if (first != .object) return error.InvalidMcpResourcePayload;

        const text_value = first.object.get("text");
        const mime_value = first.object.get("mimeType");
        return .{
            .server_id = try allocator.dupe(u8, self.server_id),
            .uri = try allocator.dupe(u8, uri),
            .text = if (textValue(text_value)) |value| try allocator.dupe(u8, value) else try stringifyJsonValue(allocator, first),
            .mime_type = if (textValue(mime_value)) |value| try allocator.dupe(u8, value) else null,
        };
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
        if (self.child.stdin == null) return error.McpClientClosed;
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
        if (self.child.stdin == null) return error.McpClientClosed;
        try protocol.writeMessage(self.child.stdin.?, payload);
    }

    fn waitForResponse(self: *Self, allocator: std.mem.Allocator, request_id: i64, timeout_ns: u64) ![]u8 {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();

        while (true) {
            if (self.takeResponseLocked(request_id)) |response_value| {
                var response = response_value;
                defer response.deinit(self.allocator);
                if (!response.ok) return error.McpRequestFailed;
                return allocator.dupe(u8, response.payload_json);
            }
            if (self.reader_error != null) return error.McpReaderFailed;
            if (self.closed) return error.McpClientClosed;
            self.condition.timedWait(&self.mutex, timeout_ns) catch return error.Timeout;
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

        if (parsed.value.object.get("method") != null) return;

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

    fn failReader(self: *Self, error_name: []const u8) void {
        while (!self.mutex.tryLock()) { std.atomic.spinLoopHint(); }
        defer self.mutex.unlock();
        if (self.reader_error != null) return;
        self.reader_error = self.allocator.dupe(u8, error_name) catch null;
        self.closed = true;
        self.condition.broadcast();
    }
};

fn parseToolsPayload(allocator: std.mem.Allocator, server_id: []const u8, payload: []const u8) ![]types.ToolInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpToolPayload;
    const tools_value = parsed.value.object.get("tools") orelse return error.InvalidMcpToolPayload;
    if (tools_value != .array) return error.InvalidMcpToolPayload;

    const result = try allocator.alloc(types.ToolInfo, tools_value.array.items.len);
    errdefer allocator.free(result);
    for (tools_value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidMcpToolPayload;
        const name = textValue(item.object.get("name")) orelse return error.InvalidMcpToolPayload;
        const description = textValue(item.object.get("description")) orelse "";
        const input_schema = if (item.object.get("inputSchema")) |schema_value|
            try stringifyJsonValue(allocator, schema_value)
        else
            try allocator.dupe(u8, "{\"type\":\"object\"}");
        errdefer allocator.free(input_schema);
        result[index] = .{
            .server_id = try allocator.dupe(u8, server_id),
            .name = try allocator.dupe(u8, name),
            .description = try allocator.dupe(u8, description),
            .input_schema_json = input_schema,
        };
        errdefer result[index].deinit(allocator);
    }
    return result;
}

fn parseResourcesPayload(allocator: std.mem.Allocator, server_id: []const u8, payload: []const u8) ![]types.ResourceInfo {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMcpResourcePayload;
    const resources_value = parsed.value.object.get("resources") orelse return error.InvalidMcpResourcePayload;
    if (resources_value != .array) return error.InvalidMcpResourcePayload;

    const result = try allocator.alloc(types.ResourceInfo, resources_value.array.items.len);
    errdefer allocator.free(result);
    for (resources_value.array.items, 0..) |item, index| {
        if (item != .object) return error.InvalidMcpResourcePayload;
        const uri = textValue(item.object.get("uri")) orelse return error.InvalidMcpResourcePayload;
        const name = textValue(item.object.get("name")) orelse uri;
        result[index] = .{
            .server_id = try allocator.dupe(u8, server_id),
            .uri = try allocator.dupe(u8, uri),
            .name = try allocator.dupe(u8, name),
            .description = if (textValue(item.object.get("description"))) |value| try allocator.dupe(u8, value) else null,
            .mime_type = if (textValue(item.object.get("mimeType"))) |value| try allocator.dupe(u8, value) else null,
        };
        errdefer result[index].deinit(allocator);
    }
    return result;
}

fn extractToolCallText(allocator: std.mem.Allocator, payload: []const u8) ![]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, payload, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return allocator.dupe(u8, payload);
    if (parsed.value.object.get("content")) |content_value| {
        if (content_value == .array and content_value.array.items.len > 0) {
            const first = content_value.array.items[0];
            if (first == .object) {
                if (textValue(first.object.get("text"))) |text| return allocator.dupe(u8, text);
            }
        }
    }
    return allocator.dupe(u8, payload);
}

fn textValue(maybe_value: ?std.json.Value) ?[]const u8 {
    const value = maybe_value orelse return null;
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

test "mcp payload parsers extract tools and resources" {
    const tools = try parseToolsPayload(std.testing.allocator, "docs", "{\"tools\":[{\"name\":\"echo\",\"description\":\"Echo\",\"inputSchema\":{\"type\":\"object\"}}]}");
    defer types.freeTools(std.testing.allocator, tools);
    try std.testing.expectEqual(@as(usize, 1), tools.len);

    const resources = try parseResourcesPayload(std.testing.allocator, "docs", "{\"resources\":[{\"uri\":\"mcp://docs/readme\",\"name\":\"README\"}]}");
    defer types.freeResources(std.testing.allocator, resources);
    try std.testing.expectEqual(@as(usize, 1), resources.len);
}
