const std = @import("std");
const error_model = @import("../core/error.zig");

pub const AppError = error_model.AppError;

pub const EnvelopeMeta = struct {
    request_id: ?[]const u8 = null,
    trace_id: ?[]const u8 = null,
    duration_ms: ?u64 = null,
    task_id: ?[]const u8 = null,
    warnings_json: ?[]const u8 = null,
    version: ?[]const u8 = null,
};

pub const TaskAccepted = struct {
    accepted: bool = true,
    task_id: []const u8,
    state: []const u8,
};

pub fn Envelope(comptime ResultType: type) type {
    return struct {
        ok: bool,
        result: ?ResultType = null,
        app_error: ?AppError = null,
        meta: EnvelopeMeta = .{},

        const Self = @This();

        pub fn success(result: ResultType, meta: EnvelopeMeta) Self {
            return .{
                .ok = true,
                .result = result,
                .meta = meta,
            };
        }

        pub fn failure(app_error: AppError, meta: EnvelopeMeta) Self {
            return .{
                .ok = false,
                .app_error = app_error,
                .meta = meta,
            };
        }

        pub fn isValid(self: Self) bool {
            const has_result = self.result != null;
            const has_error = self.app_error != null;

            if (self.ok) {
                return has_result and !has_error;
            }

            return !has_result and has_error;
        }
    };
}

test "success envelope keeps result and meta" {
    const ExampleResult = struct {
        name: []const u8,
        count: u32,
    };
    const ExampleEnvelope = Envelope(ExampleResult);

    const envelope = ExampleEnvelope.success(.{
        .name = "app.meta",
        .count = 1,
    }, .{
        .request_id = "req_01",
        .trace_id = "trc_01",
        .duration_ms = 42,
    });

    try std.testing.expect(envelope.ok);
    try std.testing.expect(envelope.result != null);
    try std.testing.expect(envelope.app_error == null);
    try std.testing.expect(envelope.isValid());
    try std.testing.expectEqualStrings("app.meta", envelope.result.?.name);
    try std.testing.expectEqual(@as(u64, 42), envelope.meta.duration_ms.?);
}

test "failure envelope carries app error" {
    const ExampleResult = struct {
        name: []const u8,
    };
    const ExampleEnvelope = Envelope(ExampleResult);
    const app_error = error_model.validationFailed(
        "request validation failed",
        "{\"issues\":[{\"path\":\"gateway.port\"}]}",
    );

    const envelope = ExampleEnvelope.failure(app_error, .{
        .request_id = "req_02",
        .trace_id = "trc_02",
        .duration_ms = 7,
    });

    try std.testing.expect(!envelope.ok);
    try std.testing.expect(envelope.result == null);
    try std.testing.expect(envelope.app_error != null);
    try std.testing.expect(envelope.isValid());
    try std.testing.expectEqualStrings(error_model.code.VALIDATION_FAILED, envelope.app_error.?.code);
}

test "manual invalid state is detectable" {
    const ExampleResult = struct {
        ok: bool,
    };
    const ExampleEnvelope = Envelope(ExampleResult);

    var envelope = ExampleEnvelope.success(.{ .ok = true }, .{});
    envelope.app_error = error_model.internal("unexpected invalid state");

    try std.testing.expect(!envelope.isValid());
}

test "task acceptance defaults to accepted" {
    const accepted = TaskAccepted{
        .task_id = "task_01",
        .state = "queued",
    };

    try std.testing.expect(accepted.accepted);
    try std.testing.expectEqualStrings("task_01", accepted.task_id);
    try std.testing.expectEqualStrings("queued", accepted.state);
}


