const std = @import("std");
const http = std.http;
const app_context_model = @import("../app_context.zig");
const dto = @import("dto.zig");
const http_model = @import("http.zig");
const services_model = @import("services.zig");

pub const ListenOptions = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 0,
};

pub const ServerListener = struct {
    allocator: std.mem.Allocator,
    tcp_server: std.Io.net.Server,
    thread: ?std.Thread = null,
    services: services_model.ServerServices,
    stop_requested: std.atomic.Value(bool) = .init(false),

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, app_context: *app_context_model.AppContext, options: ListenOptions) !*Self {
        const address = try std.Io.net.IpAddress.parse(options.host, options.port);
        const io = std.Io.Threaded.global_single_threaded.*.io();
        const tcp_server = try address.listen(io, .{ .reuse_address = true });

        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .tcp_server = tcp_server,
            .services = services_model.ServerServices.init(allocator, app_context),
        };

        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.stop_requested.store(true, .release);
        if (self.thread) |thread| thread.join();
        self.tcp_server.deinit(std.Io.Threaded.global_single_threaded.*.io());
        self.allocator.destroy(self);
    }

    pub fn urlAlloc(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        return allocator.dupe(u8, "http://unknown");
    }

    fn serveLoop(self: *Self) void {
        while (true) {
            const connection = self.tcp_server.accept(std.Io.Threaded.global_single_threaded.*.io()) catch return;
            if (self.stop_requested.load(.acquire)) {
                connection.close(std.Io.Threaded.global_single_threaded.*.io());
                return;
            }
            self.handleConnection(connection) catch {};
        }
    }

    fn handleConnection(self: *Self, connection: std.Io.net.Stream) !void {
        const io = std.Io.Threaded.global_single_threaded.*.io();
        var recv_buffer: [4096]u8 = undefined;
        var send_buffer: [4096]u8 = undefined;
        var stream_reader = std.Io.net.Stream.Reader.init(connection, io, &recv_buffer);
        var stream_writer = std.Io.net.Stream.Writer.init(connection, io, &send_buffer);
        var server: http.Server = .init(&stream_reader.interface, &stream_writer.interface);

        var request = server.receiveHead() catch return;

        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var request_services = self.services;
        request_services.allocator = arena;

        const target = try arena.dupe(u8, request.head.target);
        const split = splitTarget(target);

        if (request.head.method == .GET and std.mem.eql(u8, split.path, "/event")) {
            try self.handleEventStream(&request, &request_services, split.query);
            return;
        }

        const maybe_body = try readBody(arena, &request);
        var response = try http_model.handleRequest(arena, &request_services, .{
            .method = mapMethod(request.head.method) orelse return,
            .target = target,
            .body = maybe_body,
        });
        defer response.deinit(arena);

        try request.respond(response.body, .{
            .status = @enumFromInt(response.status),
            .keep_alive = false,
            .extra_headers = &.{
                .{ .name = "Content-Type", .value = response.content_type },
            },
        });
    }

    fn handleEventStream(self: *Self, request: *http.Server.Request, services: *services_model.ServerServices, query: []const u8) !void {
        const after_seq = parseQueryInt(query, "after_seq") orelse 0;
        var send_buffer: [4096]u8 = undefined;
        var body_writer = try request.respondStreaming(&send_buffer, .{
            .respond_options = .{
                .status = .ok,
                .keep_alive = true,
                .extra_headers = &.{
                    .{ .name = "Content-Type", .value = "text/event-stream" },
                    .{ .name = "Cache-Control", .value = "no-cache" },
                },
            },
        });

        const subscription_id = try services.app_context.eventBus().subscribe(&.{}, after_seq);
        defer services.app_context.eventBus().unsubscribe(subscription_id) catch {};

        while (!self.stop_requested.load(.acquire)) {
            var batch = try services.app_context.eventBus().pollSubscription(self.allocator, subscription_id, 64);
            defer batch.deinit(self.allocator);

            if (batch.events.len > 0) {
                for (batch.events) |event| {
                    const dto_value = dto.RuntimeEventDto{
                        .seq = event.seq,
                        .topic = event.topic,
                        .ts_unix_ms = event.ts_unix_ms,
                        .payload_json = event.payload_json,
                    };
                    try body_writer.writer.print("data: {f}\n\n", .{std.json.fmt(dto_value, .{})});
                }
                try body_writer.flush();
            } else {
                try body_writer.writer.writeAll(":keepalive\n\n");
                try body_writer.flush();
            }

            std.Io.sleep(std.Io.Threaded.global_single_threaded.*.io(), std.Io.Duration.fromMilliseconds(200), .awake) catch continue;
        }
    }

    fn readBody(allocator: std.mem.Allocator, request: *http.Server.Request) !?[]const u8 {
        if (request.head.content_length == null and request.head.transfer_encoding == .none) {
            return null;
        }
        var body_buffer: [8192]u8 = undefined;
        const reader = try request.readerExpectContinue(&body_buffer);
        return try reader.allocRemaining(allocator, .limited(512 * 1024));
    }

    fn mapMethod(method: http.Method) ?http_model.Method {
        return switch (method) {
            .GET => .GET,
            .POST => .POST,
            else => null,
        };
    }
};

const TargetParts = struct {
    path: []const u8,
    query: []const u8,
};

fn splitTarget(target: []const u8) TargetParts {
    if (std.mem.indexOfScalar(u8, target, '?')) |index| {
        return .{
            .path = target[0..index],
            .query = target[index + 1 ..],
        };
    }
    return .{
        .path = target,
        .query = "",
    };
}

fn parseQueryInt(query: []const u8, key: []const u8) ?u64 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (!std.mem.eql(u8, part[0..eq_index], key)) continue;
        return std.fmt.parseInt(u64, part[eq_index + 1 ..], 10) catch null;
    }
    return null;
}

test "server listener exposes real local HTTP API" {
    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    const alloc = std.heap.page_allocator;

    const listener = try ServerListener.init(alloc, &fixture.app_context, .{ .host = "127.0.0.1", .port = 0 });
    defer listener.deinit();

    const create_body = "{\"title\":\"Serve\"}";
    const create_request = try std.fmt.allocPrint(alloc,
        "POST /session HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ create_body.len, create_body },
    );
    defer alloc.free(create_request);

    const create_response = try rawHttpRequest(alloc, listener.tcp_server.listen_address, create_request);
    defer alloc.free(create_response);
    try std.testing.expect(std.mem.indexOf(u8, create_response, "200 OK") != null);

    const create_json = splitHttpBody(create_response) orelse return error.InvalidHttpResponse;
    const ParsedCreate = struct {
        session_id: []const u8,
    };
    const parsed_create = try std.json.parseFromSlice(ParsedCreate, alloc, create_json, .{ .ignore_unknown_fields = true });
    defer parsed_create.deinit();

    const prompt_body = "{\"text\":\"hello\"}";
    const prompt_request = try std.fmt.allocPrint(alloc,
        "POST /session/{s}/prompt HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ parsed_create.value.session_id, prompt_body.len, prompt_body },
    );
    defer alloc.free(prompt_request);

    const prompt_response = try rawHttpRequest(alloc, listener.tcp_server.listen_address, prompt_request);
    defer alloc.free(prompt_response);
    try std.testing.expect(std.mem.indexOf(u8, prompt_response, "202 Accepted") != null);

    var attempts: usize = 0;
    while (attempts < 50) : (attempts += 1) {
        const status_request = "GET /session/status HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n";
        const status_response = try rawHttpRequest(alloc, listener.tcp_server.listen_address, status_request);
        defer alloc.free(status_response);
        const status_json = splitHttpBody(status_response) orelse return error.InvalidHttpResponse;
        if (std.mem.indexOf(u8, status_json, "completed") != null) return;
        std.Thread.sleep(20 * std.time.ns_per_ms);
    }
    return error.ExpectedCompletedSessionStatus;
}

fn rawHttpRequest(allocator: std.mem.Allocator, address: std.Io.net.Address, request_text: []const u8) ![]u8 {
    const stream = try std.Io.net.tcpConnectToAddress(address);
    defer stream.close(std.Io.Threaded.global_single_threaded.*.io());

    try stream.writeAll(request_text);
    var buffer: [4096]u8 = undefined;
    var reader = stream.reader(buffer[0..]);
    return reader.interface().allocRemaining(allocator, .limited(512 * 1024));
}

fn splitHttpBody(response: []const u8) ?[]const u8 {
    const marker = "\r\n\r\n";
    const index = std.mem.indexOf(u8, response, marker) orelse return null;
    return response[index + marker.len ..];
}
