const std = @import("std");

pub const HttpMethod = enum {
    GET,
    POST,

    fn toStd(self: HttpMethod) std.http.Method {
        return switch (self) {
            .GET => .GET,
            .POST => .POST,
        };
    }
};

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

pub const HttpRequest = struct {
    method: HttpMethod = .GET,
    url: []const u8,
    headers: []const HttpHeader = &.{},
    body: ?[]const u8 = null,
    timeout_ms: ?u32 = null,
};

pub const HttpResponse = struct {
    status_code: u16,
    body: []u8,

    pub fn deinit(self: *HttpResponse, allocator: std.mem.Allocator) void {
        allocator.free(self.body);
    }
};

pub const HttpClient = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        send: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: HttpRequest) anyerror!HttpResponse,
        name: *const fn (ptr: *anyopaque) []const u8,
        deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
    };

    pub fn send(self: HttpClient, allocator: std.mem.Allocator, request: HttpRequest) anyerror!HttpResponse {
        return self.vtable.send(self.ptr, allocator, request);
    }

    pub fn name(self: HttpClient) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn deinit(self: HttpClient, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |deinit_fn| deinit_fn(self.ptr, allocator);
    }
};

pub const NativeHttpClient = struct {
    pub const Requester = *const fn (allocator: std.mem.Allocator, request: HttpRequest) anyerror!HttpResponse;

    requester: ?Requester = null,
    io: std.Io,

    const vtable = HttpClient.VTable{
        .send = sendErased,
        .name = nameErased,
        .deinit = null,
    };

    pub fn init(requester: ?Requester, io: std.Io) NativeHttpClient {
        return .{
            .requester = requester,
            .io = io,
        };
    }

    pub fn client(self: *NativeHttpClient) HttpClient {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn clientName() []const u8 {
        return "native";
    }

    pub fn send(self: *NativeHttpClient, allocator: std.mem.Allocator, request: HttpRequest) !HttpResponse {
        if (self.requester) |requester| return requester(allocator, request);
        return sendStd(allocator, self.io, request);
    }

    fn sendErased(ptr: *anyopaque, allocator: std.mem.Allocator, request: HttpRequest) anyerror!HttpResponse {
        const self: *NativeHttpClient = @ptrCast(@alignCast(ptr));
        return self.send(allocator, request);
    }

    fn nameErased(_: *anyopaque) []const u8 {
        return clientName();
    }
};

fn sendStd(allocator: std.mem.Allocator, io: std.Io, request: HttpRequest) !HttpResponse {
    var client: std.http.Client = .{ .allocator = allocator, .io = io };
    defer client.deinit();

    var headers: std.ArrayListUnmanaged(std.http.Header) = .{ .items = &[_]std.http.Header{}, .capacity = 0 };
    defer headers.deinit(allocator);
    for (request.headers) |header| {
        try headers.append(allocator, .{
            .name = header.name,
            .value = header.value,
        });
    }

    var writer = std.Io.Writer.Allocating.init(allocator);
    defer writer.deinit();

    // Note: std.http.Client does not expose a simple end-to-end per-request
    // timeout control here. The timeout field is still carried in the request
    // contract so injected requesters or future native implementations can honor
    // it consistently.
    const result = try client.fetch(.{
        .location = .{ .url = request.url },
        .method = request.method.toStd(),
        .payload = request.body,
        .extra_headers = headers.items,
        .response_writer = &writer.writer,
    });

    return .{
        .status_code = @intFromEnum(result.status),
        .body = try allocator.dupe(u8, writer.writer.buffer[0..writer.writer.end]),
    };
}

test "native http client can use injected requester" {
    const Mock = struct {
        fn mockRequest(allocator: std.mem.Allocator, req: HttpRequest) !HttpResponse {
            try std.testing.expectEqual(HttpMethod.POST, req.method);
            try std.testing.expectEqualStrings("https://example.test/echo", req.url);
            try std.testing.expectEqualStrings("payload", req.body.?);
            try std.testing.expectEqual(@as(usize, 1), req.headers.len);
            try std.testing.expectEqualStrings("x-test", req.headers[0].name);
            try std.testing.expectEqualStrings("123", req.headers[0].value);
            try std.testing.expectEqual(@as(?u32, 250), req.timeout_ms);
            return .{
                .status_code = 201,
                .body = try allocator.dupe(u8, "{\"ok\":true}"),
            };
        }
    };

    var client = NativeHttpClient.init(Mock.mockRequest, std.Io.Threaded.global_single_threaded.*.io());
    var response = try client.send(std.testing.allocator, .{
        .method = .POST,
        .url = "https://example.test/echo",
        .headers = &.{.{ .name = "x-test", .value = "123" }},
        .body = "payload",
        .timeout_ms = 250,
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 201), response.status_code);
    try std.testing.expectEqualStrings("{\"ok\":true}", response.body);
}


