const std = @import("std");

pub const MODULE_NAME = "effects";
pub const types = @import("types.zig");
pub const process_runner = @import("process_runner.zig");
pub const fs = @import("fs.zig");
pub const env_provider = @import("env_provider.zig");
pub const clock = @import("clock.zig");
pub const http_client = @import("http_client.zig");
pub const runtime = @import("runtime.zig");

pub const EffectRequestContext = types.EffectRequestContext;
pub const EffectStatus = types.EffectStatus;
pub const EffectResultContext = types.EffectResultContext;
pub const EffectErrorCategory = types.EffectErrorCategory;
pub const EffectErrorInfo = types.EffectErrorInfo;
pub const ProcessEnvVar = process_runner.ProcessEnvVar;
pub const ProcessRunRequest = process_runner.ProcessRunRequest;
pub const ProcessTerminationKind = process_runner.ProcessTerminationKind;
pub const ProcessRunResult = process_runner.ProcessRunResult;
pub const ProcessRunner = process_runner.ProcessRunner;
pub const NativeProcessRunner = process_runner.NativeProcessRunner;
pub const FsEntryKind = fs.FsEntryKind;
pub const FsEntry = fs.FsEntry;
pub const FileSystem = fs.FileSystem;
pub const NativeFileSystem = fs.NativeFileSystem;
pub const EnvProvider = env_provider.EnvProvider;
pub const NativeEnvProvider = env_provider.NativeEnvProvider;
pub const Clock = clock.Clock;
pub const NativeClock = clock.NativeClock;
pub const HttpMethod = http_client.HttpMethod;
pub const HttpHeader = http_client.HttpHeader;
pub const HttpRequest = http_client.HttpRequest;
pub const HttpResponse = http_client.HttpResponse;
pub const HttpClient = http_client.HttpClient;
pub const NativeHttpClient = http_client.NativeHttpClient;
pub const EffectsRuntime = runtime.EffectsRuntime;

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test {
    std.testing.refAllDecls(@This());
}

test "effects scaffold exports are stable" {
    try std.testing.expectEqualStrings("effects", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);
    try std.testing.expectEqualStrings("failed", EffectStatus.failed.asText());
    try std.testing.expectEqualStrings("timeout", EffectErrorCategory.timeout.asText());
    try std.testing.expectEqualStrings("native", NativeProcessRunner.runnerName());
    try std.testing.expectEqualStrings("native", NativeFileSystem.fileSystemName());
    try std.testing.expectEqualStrings("native", NativeEnvProvider.providerName());
    try std.testing.expectEqualStrings("native", NativeClock.clockName());
    try std.testing.expectEqualStrings("native", NativeHttpClient.clientName());
    try std.testing.expectEqualStrings("native", EffectsRuntime.init(.{}).file_system.name());
}


