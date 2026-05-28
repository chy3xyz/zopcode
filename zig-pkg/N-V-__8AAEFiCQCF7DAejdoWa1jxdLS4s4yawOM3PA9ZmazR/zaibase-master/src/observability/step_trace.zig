const std = @import("std");
const core = @import("../core/root.zig");

pub const Logger = core.logging.Logger;
pub const LogField = core.logging.LogField;

pub const StepTrace = struct {
    allocator: std.mem.Allocator,
    logger: *Logger,
    subsystem: []u8,
    step: []u8,
    threshold_ms: ?u64,
    started_at_ms: i64,
    completed: bool = false,

    pub fn begin(allocator: std.mem.Allocator, logger: *Logger, subsystem: []const u8, step: []const u8, threshold_ms: ?u64) anyerror!StepTrace {
        var trace = StepTrace{
            .allocator = allocator,
            .logger = logger,
            .subsystem = try allocator.dupe(u8, subsystem),
            .step = try allocator.dupe(u8, step),
            .threshold_ms = threshold_ms,
            .started_at_ms = (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }),
        };
        errdefer trace.deinit();
        trace.logStarted();
        return trace;
    }

    pub fn finish(self: *StepTrace, error_code: ?[]const u8) void {
        if (self.completed) return;
        self.completed = true;

        const elapsed_ms: u64 = @intCast(@max(0, (blk: { const io = std.Io.Threaded.global_single_threaded.*.io(); break :blk std.Io.Timestamp.now(io, .real).toMilliseconds(); }) - self.started_at_ms));
        const beyond_threshold = if (self.threshold_ms) |threshold| elapsed_ms > threshold else false;

        var fields: [5]LogField = undefined;
        var count: usize = 0;
        fields[count] = LogField.string("step", self.step);
        count += 1;
        fields[count] = LogField.uint("duration_ms", elapsed_ms);
        count += 1;
        fields[count] = LogField.boolean("beyond_threshold", beyond_threshold);
        count += 1;
        if (self.threshold_ms) |threshold| {
            fields[count] = LogField.uint("threshold_ms", threshold);
            count += 1;
        }
        if (error_code) |err| {
            fields[count] = LogField.string("error_code", err);
            count += 1;
            self.logger.child(self.subsystem).logKind(.warn, core.logging.LogRecordKind.step, "Step completed", fields[0..count]);
        } else if (beyond_threshold) {
            self.logger.child(self.subsystem).logKind(.warn, core.logging.LogRecordKind.step, "Step completed", fields[0..count]);
        } else {
            self.logger.child(self.subsystem).logKind(.info, core.logging.LogRecordKind.step, "Step completed", fields[0..count]);
        }
    }

    pub fn deinit(self: *StepTrace) void {
        self.allocator.free(self.subsystem);
        self.allocator.free(self.step);
    }

    fn logStarted(self: *StepTrace) void {
        var fields: [2]LogField = undefined;
        var count: usize = 0;
        fields[count] = LogField.string("step", self.step);
        count += 1;
        if (self.threshold_ms) |threshold| {
            fields[count] = LogField.uint("threshold_ms", threshold);
            count += 1;
        }
        self.logger.child(self.subsystem).logKind(.info, core.logging.LogRecordKind.step, "Step started", fields[0..count]);
    }
};

test "step trace emits started and completed logs" {
    var memory_sink = core.logging.sinks.Memory.init(std.testing.allocator, 8);
    defer memory_sink.deinit();
    var logger = core.logging.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var trace = try StepTrace.begin(std.testing.allocator, &logger, "runtime/config", "apply_write", 1000);
    defer trace.deinit();
    trace.finish(null);

    try std.testing.expectEqual(@as(usize, 2), memory_sink.count());
    try std.testing.expectEqual(core.logging.LogRecordKind.step, memory_sink.recordAt(0).?.kind);
    try std.testing.expectEqual(core.logging.LogRecordKind.step, memory_sink.recordAt(1).?.kind);
    try std.testing.expectEqualStrings("Step started", memory_sink.recordAt(0).?.message);
    try std.testing.expectEqualStrings("Step completed", memory_sink.recordAt(1).?.message);
}

test "step trace warns on threshold or error" {
    var memory_sink = core.logging.sinks.Memory.init(std.testing.allocator, 8);
    defer memory_sink.deinit();
    var logger = core.logging.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    var trace = try StepTrace.begin(std.testing.allocator, &logger, "runtime/provider", "request", 0);
    defer trace.deinit();
    trace.finish("PROVIDER_TIMEOUT");

    try std.testing.expect(memory_sink.latest().?.level == .warn);
}


