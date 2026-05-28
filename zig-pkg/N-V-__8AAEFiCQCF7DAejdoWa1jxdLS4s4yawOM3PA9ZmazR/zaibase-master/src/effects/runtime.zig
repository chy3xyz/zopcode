const std = @import("std");
const fs = @import("fs.zig");
const process_runner = @import("process_runner.zig");
const env_provider = @import("env_provider.zig");
const clock = @import("clock.zig");
const http_client = @import("http_client.zig");

pub const EffectsRuntime = struct {
    native_process_runner: process_runner.NativeProcessRunner,
    native_file_system: fs.NativeFileSystem,
    native_env_provider: env_provider.NativeEnvProvider,
    native_clock: clock.NativeClock,
    native_http_client: http_client.NativeHttpClient,

    process_runner: process_runner.ProcessRunner,
    file_system: fs.FileSystem,
    env_provider: env_provider.EnvProvider,
    clock: clock.Clock,
    http_client: http_client.HttpClient,

    pub const Dependencies = struct {
        process_runner: ?process_runner.ProcessRunner = null,
        file_system: ?fs.FileSystem = null,
        env_provider: ?env_provider.EnvProvider = null,
        clock: ?clock.Clock = null,
        http_client: ?http_client.HttpClient = null,
        native_http_requester: ?http_client.NativeHttpClient.Requester = null,
    };

    pub fn init(deps: Dependencies) EffectsRuntime {
        var runtime_value: EffectsRuntime = undefined;
        runtime_value.native_process_runner = process_runner.NativeProcessRunner.init();
        runtime_value.native_file_system = fs.NativeFileSystem.init();
        runtime_value.native_env_provider = env_provider.NativeEnvProvider.init();
        runtime_value.native_clock = clock.NativeClock.init();
        runtime_value.native_http_client = http_client.NativeHttpClient.init(deps.native_http_requester, std.Io.Threaded.global_single_threaded.*.io());

        runtime_value.process_runner = deps.process_runner orelse runtime_value.native_process_runner.runner();
        runtime_value.file_system = deps.file_system orelse runtime_value.native_file_system.fileSystem();
        runtime_value.env_provider = deps.env_provider orelse runtime_value.native_env_provider.provider();
        runtime_value.clock = deps.clock orelse runtime_value.native_clock.clock();
        runtime_value.http_client = deps.http_client orelse runtime_value.native_http_client.client();
        return runtime_value;
    }
};

test "effects runtime initializes with native defaults" {
    var runtime_value = EffectsRuntime.init(.{});

    try std.testing.expectEqualStrings("native", runtime_value.process_runner.name());
    try std.testing.expectEqualStrings("native", runtime_value.file_system.name());
    try std.testing.expectEqualStrings("native", runtime_value.env_provider.name());
    try std.testing.expectEqualStrings("native", runtime_value.clock.name());
    try std.testing.expectEqualStrings("native", runtime_value.http_client.name());
}


