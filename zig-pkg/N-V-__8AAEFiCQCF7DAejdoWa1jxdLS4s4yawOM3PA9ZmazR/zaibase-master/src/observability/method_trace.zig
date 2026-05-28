const std = @import("std");
const core = @import("../core/root.zig");

pub const Logger = core.logging.Logger;
pub const LogField = core.logging.LogField;

pub const MethodTrace = struct {
    allocator: std.mem.Allocator,
    logger: *Logger,
    method_name: []u8,
    threshold_ms: ?u64,
    started_at_ms: i64,
    completed: bool = false,

    pub fn begin(allocator: std.mem.Allocator, logger: *Logger, method_name: []const u8, params_summary: []const u8, threshold_ms: ?u64) anyerror!MethodTrace {
        var trace = MethodTrace{
            .allocator = allocator,
            .logger = logger,
            .method_name = try allocator.dupe(u8, method_name),
            .threshold_ms = threshold_ms,
            .started_at_ms = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }),
        };
        errdefer trace.deinit();

        var fields: [3]LogField = undefined;
        var count: usize = 0;
        fields[count] = LogField.string("method", trace.method_name);
        count += 1;
        fields[count] = LogField.string("params", params_summary);
        count += 1;
        if (threshold_ms) |threshold| {
            fields[count] = LogField.uint("threshold_ms", threshold);
            count += 1;
        }
        logger.child("method").logKind(.debug, core.logging.LogRecordKind.method, "ENTRY", fields[0..count]);
        return trace;
    }

    pub fn finishSuccess(self: *MethodTrace, result_summary: []const u8, is_async: bool) void {
        if (self.completed) return;
        self.completed = true;
        const elapsed_ms: u64 = @intCast(@max(0, (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }) - self.started_at_ms));
        const beyond_threshold = if (self.threshold_ms) |threshold| elapsed_ms > threshold else false;

        var fields: [7]LogField = undefined;
        var count: usize = 0;
        fields[count] = LogField.string("method", self.method_name);
        count += 1;
        fields[count] = LogField.string("result", result_summary);
        count += 1;
        fields[count] = LogField.string("status", "SUCCESS");
        count += 1;
        fields[count] = LogField.uint("duration_ms", elapsed_ms);
        count += 1;
        fields[count] = LogField.string("type", if (is_async) "ASYNC" else "SYNC");
        count += 1;
        fields[count] = LogField.boolean("beyond_threshold", beyond_threshold);
        count += 1;
        if (self.threshold_ms) |threshold| {
            fields[count] = LogField.uint("threshold_ms", threshold);
            count += 1;
        }
        if (beyond_threshold) {
            self.logger.child("method").logKind(.warn, core.logging.LogRecordKind.method, "EXIT", fields[0..count]);
        } else {
            self.logger.child("method").logKind(.info, core.logging.LogRecordKind.method, "EXIT", fields[0..count]);
        }
    }

    pub fn finishError(self: *MethodTrace, exception_type: []const u8, error_code: ?[]const u8, is_async: bool) void {
        if (self.completed) return;
        self.completed = true;
        const elapsed_ms: u64 = @intCast(@max(0, (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }) - self.started_at_ms));

        var fields: [7]LogField = undefined;
        var count: usize = 0;
        fields[count] = LogField.string("method", self.method_name);
        count += 1;
        fields[count] = LogField.string("exception_type", exception_type);
        count += 1;
        fields[count] = LogField.string("status", "FAIL");
        count += 1;
        fields[count] = LogField.uint("duration_ms", elapsed_ms);
        count += 1;
        fields[count] = LogField.string("type", if (is_async) "ASYNC" else "SYNC");
        count += 1;
        if (error_code) |code| {
            fields[count] = LogField.string("error_code", code);
            count += 1;
        }
        self.logger.child("method").logKind(.warn, core.logging.LogRecordKind.method, "ERROR", fields[0..count]);
    }

    pub fn deinit(self: *MethodTrace) void {
        self.allocator.free(self.method_name);
    }
};

test "method trace emits entry and exit logs" {
    var memory_sink = core.logging.sinks.Memory.init(std.testing.allocator, 8);
    defer memory_sink.deinit();
    var logger = core.logging.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var trace = try MethodTrace.begin(std.testing.allocator, &logger, "Controller.Auth.Login", "{\"user\":\"admin\"}", 1000);
    defer trace.deinit();
    trace.finishSuccess("Ok(200)", false);

    try std.testing.expectEqual(@as(usize, 2), memory_sink.count());
    try std.testing.expectEqual(core.logging.LogRecordKind.method, memory_sink.recordAt(0).?.kind);
    try std.testing.expectEqual(core.logging.LogRecordKind.method, memory_sink.recordAt(1).?.kind);
    try std.testing.expectEqualStrings("ENTRY", memory_sink.recordAt(0).?.message);
    try std.testing.expectEqualStrings("EXIT", memory_sink.recordAt(1).?.message);
}


