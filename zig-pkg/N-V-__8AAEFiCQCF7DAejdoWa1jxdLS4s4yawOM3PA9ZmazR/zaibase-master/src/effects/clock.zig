const std = @import("std");

pub const Clock = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        now_unix_ms: *const fn (ptr: *anyopaque) i64,
        monotonic_ns: *const fn (ptr: *anyopaque) u64,
        sleep_ms: *const fn (ptr: *anyopaque, ms: u64) void,
        name: *const fn (ptr: *anyopaque) []const u8,
        deinit: ?*const fn (ptr: *anyopaque, allocator: std.mem.Allocator) void = null,
    };

    pub fn nowUnixMs(self: Clock) i64 {
        return self.vtable.now_unix_ms(self.ptr);
    }

    pub fn monotonicNs(self: Clock) u64 {
        return self.vtable.monotonic_ns(self.ptr);
    }

    pub fn sleepMs(self: Clock, ms: u64) void {
        self.vtable.sleep_ms(self.ptr, ms);
    }

    pub fn name(self: Clock) []const u8 {
        return self.vtable.name(self.ptr);
    }

    pub fn deinit(self: Clock, allocator: std.mem.Allocator) void {
        if (self.vtable.deinit) |deinit_fn| deinit_fn(self.ptr, allocator);
    }
};

pub fn deadlineAfterMs(clock: Clock, timeout_ms: u64) u64 {
    return clock.monotonicNs() + timeout_ms * std.time.ns_per_ms;
}

pub fn deadlineExceeded(clock: Clock, deadline_ns: u64) bool {
    return clock.monotonicNs() >= deadline_ns;
}

pub const NativeClock = struct {
    const vtable = Clock.VTable{
        .now_unix_ms = nowUnixMsErased,
        .monotonic_ns = monotonicNsErased,
        .sleep_ms = sleepMsErased,
        .name = nameErased,
        .deinit = null,
    };

    pub fn init() NativeClock {
        return .{};
    }

    pub fn clock(self: *NativeClock) Clock {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    pub fn clockName() []const u8 {
        return "native";
    }

    pub fn nowUnixMs(_: *NativeClock) i64 {
        const io = std.Io.Threaded.global_single_threaded.*.io();
        return std.Io.Timestamp.now(io, .real).toMilliseconds();
    }

    pub fn monotonicNs(_: *NativeClock) u64 {
        const io = std.Io.Threaded.global_single_threaded.*.io();
        return @intCast(std.Io.Timestamp.now(io, .awake).nanoseconds);
    }

    pub fn sleepMs(_: *NativeClock, ms: u64) void {
        const io = std.Io.Threaded.global_single_threaded.*.io();
        std.Io.sleep(io, std.Io.Duration.fromMilliseconds(@intCast(ms)), .real) catch {};
    }

    fn nowUnixMsErased(ptr: *anyopaque) i64 {
        const self: *NativeClock = @ptrCast(@alignCast(ptr));
        return self.nowUnixMs();
    }

    fn monotonicNsErased(ptr: *anyopaque) u64 {
        const self: *NativeClock = @ptrCast(@alignCast(ptr));
        return self.monotonicNs();
    }

    fn sleepMsErased(ptr: *anyopaque, ms: u64) void {
        const self: *NativeClock = @ptrCast(@alignCast(ptr));
        self.sleepMs(ms);
    }

    fn nameErased(_: *anyopaque) []const u8 {
        return clockName();
    }
};

test "native clock provides wall and monotonic time" {
    var clock_native = NativeClock.init();
    const clock = clock_native.clock();

    try std.testing.expect(clock.nowUnixMs() > 0);
    const first = clock.monotonicNs();
    clock.sleepMs(1);
    const second = clock.monotonicNs();
    try std.testing.expect(second >= first);
}

test "deadline helpers are stable" {
    var clock_native = NativeClock.init();
    const clock = clock_native.clock();

    const deadline = deadlineAfterMs(clock, 2);
    try std.testing.expect(!deadlineExceeded(clock, deadline));
    clock.sleepMs(5);
    try std.testing.expect(deadlineExceeded(clock, deadline));
}


