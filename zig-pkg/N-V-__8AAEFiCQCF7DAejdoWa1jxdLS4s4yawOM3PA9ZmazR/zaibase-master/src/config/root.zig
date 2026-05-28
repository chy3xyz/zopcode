const std = @import("std");

pub const MODULE_NAME = "config";
pub const defaults = @import("defaults.zig");
pub const loader = @import("loader.zig");
pub const parser = @import("parser.zig");
pub const pipeline = @import("pipeline.zig");
pub const store = @import("store.zig");

pub const ConfigWritePipeline = pipeline.ConfigWritePipeline;
pub const ConfigWriteAttempt = pipeline.ConfigWriteAttempt;
pub const ConfigSideEffect = pipeline.ConfigSideEffect;
pub const ConfigSideEffectRecord = pipeline.ConfigSideEffectRecord;
pub const MemoryConfigSideEffectSink = pipeline.MemoryConfigSideEffectSink;
pub const ConfigPostWriteSummary = pipeline.ConfigPostWriteSummary;
pub const ConfigPostWriteHook = pipeline.ConfigPostWriteHook;
pub const MemoryConfigPostWriteHookSink = pipeline.MemoryConfigPostWriteHookSink;
pub const ConfigChangeKind = store.ConfigChangeKind;
pub const ConfigSideEffectKind = store.ConfigSideEffectKind;
pub const ConfigStore = store.ConfigStore;
pub const ConfigWriteStats = store.ConfigWriteStats;
pub const ConfigDiffSummary = store.ConfigDiffSummary;
pub const ConfigChange = store.ConfigChange;
pub const ConfigChangeLog = store.ConfigChangeLog;
pub const ConfigChangeLogEntry = store.ConfigChangeLogEntry;
pub const MemoryConfigStore = store.MemoryConfigStore;
pub const MemoryConfigChangeLog = store.MemoryConfigChangeLog;
pub const ConfigDefaultEntry = defaults.ConfigDefaultEntry;
pub const ConfigDefaults = defaults.ConfigDefaults;
pub const ConfigLoader = loader.ConfigLoader;
pub const ConfigValueSource = loader.ConfigValueSource;
pub const LoadedConfigValue = loader.LoadedConfigValue;
pub const ConfigValueParser = parser.ConfigValueParser;

pub const ModuleStage = enum {
    scaffold,
};

pub const MODULE_STAGE: ModuleStage = .scaffold;

test "config scaffold exports are stable" {
    try std.testing.expectEqualStrings("config", MODULE_NAME);
    try std.testing.expect(MODULE_STAGE == .scaffold);
    _ = ConfigWritePipeline;
    _ = MemoryConfigStore;
    _ = ConfigDefaults;
    _ = ConfigLoader;
}


