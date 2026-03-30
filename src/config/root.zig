const std = @import("std");

pub const MODULE_NAME = "config";

pub const schema = @import("schema.zig");
pub const defaults = @import("defaults.zig");
pub const paths = @import("paths.zig");
pub const loader = @import("loader.zig");
pub const view = @import("view.zig");
pub const runtime = @import("runtime.zig");

pub const keys = schema.keys;
pub const fieldDefinitions = schema.fieldDefinitions;
pub const bootstrapDefaults = defaults.bootstrapDefaults;

pub const RuntimeOptions = runtime.RuntimeOptions;
pub const ConfigRuntime = runtime.ConfigRuntime;
pub const ResolvedPaths = paths.ResolvedPaths;
pub const EffectiveConfig = view.EffectiveConfig;
pub const ModelConfig = view.ModelConfig;
pub const PermissionConfig = view.PermissionConfig;
pub const SessionConfig = view.SessionConfig;
pub const ServerConfig = view.ServerConfig;
pub const TuiConfig = view.TuiConfig;
pub const LspConfig = view.LspConfig;
pub const LspServerConfig = view.LspServerConfig;
pub const McpConfig = view.McpConfig;
pub const McpServerConfig = view.McpServerConfig;
pub const McpServerTransport = view.McpServerTransport;
pub const FormatterConfig = view.FormatterConfig;
pub const FormatterDefinitionConfig = view.FormatterDefinitionConfig;
pub const ToolPolicy = view.ToolPolicy;
pub const AnthropicProviderConfig = view.AnthropicProviderConfig;

test "config module exports are stable" {
    try std.testing.expectEqualStrings("config", MODULE_NAME);
    try std.testing.expect(fieldDefinitions().len > 0);
}
