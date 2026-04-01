const std = @import("std");
const framework = @import("framework");
const schema = @import("schema.zig");

const bootstrap_entries = [_]framework.ConfigDefaultEntry{
    .{ .path = schema.keys.model_default, .value_kind = .string, .value_json = "\"anthropic/claude-sonnet-4-5\"" },
    .{ .path = schema.keys.agent_default, .value_kind = .string, .value_json = "\"build\"" },
    .{ .path = schema.keys.permission_rules, .value_kind = .array, .value_json = "[{\"permission\":\"read\",\"pattern\":\"*\",\"action\":\"allow\"},{\"permission\":\"lsp\",\"pattern\":\"*\",\"action\":\"allow\"},{\"permission\":\"question\",\"pattern\":\"*\",\"action\":\"allow\"},{\"permission\":\"edit\",\"pattern\":\"*\",\"action\":\"ask\"},{\"permission\":\"execute_shell\",\"pattern\":\"*\",\"action\":\"ask\"},{\"permission\":\"fetch_url\",\"pattern\":\"*\",\"action\":\"ask\"},{\"permission\":\"mcp\",\"pattern\":\"*\",\"action\":\"ask\"}]" },
    .{ .path = schema.keys.session_store_path, .value_kind = .string, .value_json = "\".zig-opencode-data/sessions\"" },
    .{ .path = schema.keys.server_port, .value_kind = .integer, .value_json = "4096" },
    .{ .path = schema.keys.server_hostname, .value_kind = .string, .value_json = "\"127.0.0.1\"" },
    .{ .path = schema.keys.tui_scroll_speed, .value_kind = .integer, .value_json = "3" },
    .{ .path = schema.keys.lsp_enabled, .value_kind = .boolean, .value_json = "true" },
    .{ .path = schema.keys.lsp_servers, .value_kind = .array, .value_json = "[]" },
    .{ .path = schema.keys.mcp_servers, .value_kind = .array, .value_json = "[]" },
    .{ .path = schema.keys.formatter_definitions, .value_kind = .array, .value_json = "[]" },
    .{ .path = schema.keys.provider_anthropic_timeout_ms, .value_kind = .integer, .value_json = "300000" },
    .{ .path = schema.keys.provider_openai_timeout_ms, .value_kind = .integer, .value_json = "300000" },
    .{ .path = schema.keys.tool_read_file_enabled, .value_kind = .boolean, .value_json = "true" },
    .{ .path = schema.keys.tool_write_file_enabled, .value_kind = .boolean, .value_json = "true" },
    .{ .path = schema.keys.tool_execute_shell_enabled, .value_kind = .boolean, .value_json = "true" },
    .{ .path = schema.keys.tool_list_files_enabled, .value_kind = .boolean, .value_json = "true" },
    .{ .path = schema.keys.tool_search_files_enabled, .value_kind = .boolean, .value_json = "true" },
    .{ .path = schema.keys.tool_fetch_url_enabled, .value_kind = .boolean, .value_json = "true" },
    .{ .path = schema.keys.tool_lsp_enabled, .value_kind = .boolean, .value_json = "true" },
};

pub fn bootstrapDefaults() framework.ConfigDefaults {
    return .{
        .entries = bootstrap_entries[0..],
    };
}

test "bootstrap defaults expose default agent and session path" {
    const defaults = bootstrapDefaults();
    try std.testing.expect(defaults.find(schema.keys.agent_default) != null);
    try std.testing.expect(defaults.find(schema.keys.session_store_path) != null);
}
