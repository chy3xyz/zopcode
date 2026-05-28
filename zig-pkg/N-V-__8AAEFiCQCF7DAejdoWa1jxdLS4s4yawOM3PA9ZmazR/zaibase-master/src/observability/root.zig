const std = @import("std");

pub const MODULE_NAME = "observability";
pub const observer = @import("observer.zig");
pub const multi_observer = @import("multi_observer.zig");
pub const log_observer = @import("log_observer.zig");
pub const file_observer = @import("file_observer.zig");
pub const metrics = @import("metrics.zig");
pub const trace_scope = @import("trace_scope.zig");
pub const request_trace = @import("request_trace.zig");
pub const step_trace = @import("step_trace.zig");
pub const method_trace = @import("method_trace.zig");
pub const summary_trace = @import("summary_trace.zig");

pub const ObservedEvent = observer.ObservedEvent;
pub const Observer = observer.Observer;
pub const MemoryObserver = observer.MemoryObserver;
pub const MultiObserver = multi_observer.MultiObserver;
pub const LogObserver = log_observer.LogObserver;
pub const JsonlFileObserver = file_observer.JsonlFileObserver;
pub const MetricsSnapshot = metrics.MetricsSnapshot;
pub const MetricsObserver = metrics.MetricsObserver;
pub const TraceScope = trace_scope;
pub const RequestTrace = request_trace.RequestTrace;
pub const StepTrace = step_trace.StepTrace;
pub const MethodTrace = method_trace.MethodTrace;
pub const SummaryTrace = summary_trace.SummaryTrace;
pub const ExceptionCategory = summary_trace.ExceptionCategory;

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test "observability scaffold exports are stable" {
    try std.testing.expectEqualStrings("observability", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);
    _ = MemoryObserver;
    _ = MetricsObserver;
}


