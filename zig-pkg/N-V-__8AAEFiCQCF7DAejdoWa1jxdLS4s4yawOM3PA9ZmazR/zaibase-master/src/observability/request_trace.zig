const std = @import("std");
const core = @import("../core/root.zig");
const app = @import("../app/root.zig");
const trace_scope = @import("trace_scope.zig");

pub const Logger = core.logging.Logger;
pub const LogField = core.logging.LogField;
pub const RequestSource = app.RequestSource;

pub const RequestTrace = struct {
    allocator: std.mem.Allocator,
    logger: *Logger,
    trace_id: []u8,
    started_at_ms: i64,
    source: RequestSource,
    request_id: []const u8,
    method: []const u8,
    path_or_target: []const u8,
    query: ?[]const u8 = null,
    previous_provider: ?core.logging.TraceContextProvider = null,
    previous_context: core.logging.TraceContext = .{},

    pub fn deinit(self: *RequestTrace) void {
        if (self.previous_context.trace_id != null or self.previous_context.request_id != null or self.previous_context.span_id != null) {
            trace_scope.set(self.previous_context);
        } else {
            trace_scope.clear();
        }
        self.logger.trace_context_provider = self.previous_provider;
        self.allocator.free(self.trace_id);
    }
};

pub fn begin(allocator: std.mem.Allocator, logger: *Logger, source: RequestSource, request_id: []const u8, method: []const u8, path_or_target: []const u8, query: ?[]const u8) anyerror!RequestTrace {
    const trace_id = try generateTraceId(allocator);
    const trace = RequestTrace{
        .allocator = allocator,
        .logger = logger,
        .trace_id = trace_id,
        .started_at_ms = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }),
        .source = source,
        .request_id = request_id,
        .method = method,
        .path_or_target = path_or_target,
        .query = query,
        .previous_provider = logger.trace_context_provider,
        .previous_context = trace_scope.current(),
    };
    logger.trace_context_provider = trace_scope.provider();
    trace_scope.set(.{ .trace_id = trace.trace_id, .request_id = trace.request_id, .span_id = null });
    logStarted(logger, &trace);
    return trace;
}

pub fn complete(logger: *Logger, trace: *const RequestTrace, status_code: ?u16, error_code: ?[]const u8) void {
    const elapsed_ms: u64 = @intCast(@max(0, (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }) - trace.started_at_ms));
    logCompleted(logger, trace, status_code, .{ .duration_ms = elapsed_ms, .error_code = error_code });
}

const Completion = struct {
    duration_ms: u64,
    error_code: ?[]const u8,
};

fn logStarted(logger: *Logger, trace: *const RequestTrace) void {
    var fields_storage: [8]LogField = undefined;
    var count: usize = 0;
    fields_storage[count] = LogField.string("source", @tagName(trace.source));
    count += 1;
    fields_storage[count] = LogField.string("method", trace.method);
    count += 1;
    fields_storage[count] = LogField.string("path", trace.path_or_target);
    count += 1;
    if (trace.query) |query| {
        fields_storage[count] = LogField.string("query", query);
        count += 1;
    }
    logger.child("request").logKind(.info, core.logging.LogRecordKind.request, "Request started", fields_storage[0..count]);
}

fn logCompleted(logger: *Logger, trace: *const RequestTrace, status_code: ?u16, completion: Completion) void {
    var fields_storage: [10]LogField = undefined;
    var count: usize = 0;
    fields_storage[count] = LogField.string("source", @tagName(trace.source));
    count += 1;
    fields_storage[count] = LogField.string("method", trace.method);
    count += 1;
    fields_storage[count] = LogField.string("path", trace.path_or_target);
    count += 1;
    if (trace.query) |query| {
        fields_storage[count] = LogField.string("query", query);
        count += 1;
    }
    if (status_code) |code| {
        fields_storage[count] = LogField.uint("status", code);
        count += 1;
    }
    fields_storage[count] = LogField.uint("duration_ms", completion.duration_ms);
    count += 1;
    if (completion.error_code) |err| {
        fields_storage[count] = LogField.string("error_code", err);
        count += 1;
    }
    logger.child("request").logKind(.info, core.logging.LogRecordKind.request, "Request completed", fields_storage[0..count]);
}

fn generateTraceId(allocator: std.mem.Allocator) anyerror![]u8 {
    var bytes: [8]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0);
    prng.random().bytes(&bytes);
    var out: [16]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (bytes, 0..) |byte, index| {
        out[index * 2] = alphabet[byte >> 4];
        out[index * 2 + 1] = alphabet[byte & 0x0f];
    }
    return allocator.dupe(u8, out[0..]);
}

test "request trace generates 16-char trace id" {
    var memory_sink = core.logging.sinks.Memory.init(std.testing.allocator, 8);
    defer memory_sink.deinit();
    var logger = core.logging.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var trace = try begin(std.testing.allocator, &logger, .http, "req_1", "GET", "/health", null);
    defer trace.deinit();
    complete(&logger, &trace, 200, null);

    try std.testing.expectEqual(@as(usize, 16), trace.trace_id.len);
    try std.testing.expectEqual(@as(usize, 2), memory_sink.count());
    try std.testing.expectEqual(core.logging.LogRecordKind.request, memory_sink.recordAt(0).?.kind);
    try std.testing.expectEqual(core.logging.LogRecordKind.request, memory_sink.recordAt(1).?.kind);
}


