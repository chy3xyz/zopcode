const std = @import("std");
const framework = @import("framework");

pub const keys = struct {
    pub const model_default = "model.default";
    pub const model_small = "model.small";
    pub const agent_default = "agent.default";
    pub const permission_rules = "permission.rules";
    pub const session_store_path = "session.store.path";
    pub const server_port = "server.port";
    pub const server_hostname = "server.hostname";
    pub const tui_scroll_speed = "tui.scroll_speed";
    pub const lsp_enabled = "lsp.enabled";
    pub const lsp_servers = "lsp.servers";
    pub const mcp_servers = "mcp.servers";
    pub const formatter_definitions = "formatter.definitions";
    pub const provider_anthropic_base_url = "provider.anthropic.base_url";
    pub const provider_anthropic_api_key = "provider.anthropic.api_key";
    pub const provider_anthropic_timeout_ms = "provider.anthropic.timeout_ms";
    pub const provider_openai_base_url = "provider.openai.base_url";
    pub const provider_openai_api_key = "provider.openai.api_key";
    pub const provider_openai_timeout_ms = "provider.openai.timeout_ms";
    pub const tool_read_file_enabled = "tools.read_file.enabled";
    pub const tool_write_file_enabled = "tools.write_file.enabled";
    pub const tool_execute_shell_enabled = "tools.execute_shell.enabled";
    pub const tool_list_files_enabled = "tools.list_files.enabled";
    pub const tool_search_files_enabled = "tools.search_files.enabled";
    pub const tool_fetch_url_enabled = "tools.fetch_url.enabled";
    pub const tool_lsp_enabled = "tools.lsp.enabled";
};

const lsp_server_fields = [_]framework.FieldDefinition{
    .{ .key = "id", .required = true, .value_kind = .string, .rules = &.{.non_empty_string} },
    .{ .key = "disabled", .required = false, .value_kind = .boolean },
    .{
        .key = "command",
        .required = true,
        .value_kind = .array,
        .rules = &.{.{ .array_length = .{ .min = 1 } }},
        .element_kind = .string,
        .element_rules = &.{.non_empty_string},
    },
    .{
        .key = "extensions",
        .required = true,
        .value_kind = .array,
        .rules = &.{.{ .array_length = .{ .min = 1 } }},
        .element_kind = .string,
        .element_rules = &.{.non_empty_string},
    },
    .{
        .key = "root_markers",
        .required = false,
        .value_kind = .array,
        .element_kind = .string,
        .element_rules = &.{.non_empty_string},
    },
    .{ .key = "initialization_json", .required = false, .value_kind = .string },
};

const mcp_server_fields = [_]framework.FieldDefinition{
    .{ .key = "id", .required = true, .value_kind = .string, .rules = &.{.non_empty_string} },
    .{
        .key = "type",
        .required = true,
        .value_kind = .enum_string,
        .rules = &.{.{ .enum_string = &.{ "local", "remote" } }},
    },
    .{ .key = "disabled", .required = false, .value_kind = .boolean },
    .{
        .key = "command",
        .required = false,
        .value_kind = .array,
        .rules = &.{.{ .array_length = .{ .min = 1 } }},
        .element_kind = .string,
        .element_rules = &.{.non_empty_string},
    },
    .{ .key = "url", .required = false, .value_kind = .string, .rules = &.{.non_empty_string} },
    .{
        .key = "timeout_ms",
        .required = false,
        .value_kind = .integer,
        .rules = &.{.{ .int_range = .{ .min = 1 } }},
    },
};

const formatter_definition_fields = [_]framework.FieldDefinition{
    .{ .key = "name", .required = true, .value_kind = .string, .rules = &.{.non_empty_string} },
    .{ .key = "enabled", .required = false, .value_kind = .boolean },
    .{
        .key = "extensions",
        .required = true,
        .value_kind = .array,
        .rules = &.{.{ .array_length = .{ .min = 1 } }},
        .element_kind = .string,
        .element_rules = &.{.non_empty_string},
    },
    .{
        .key = "command",
        .required = true,
        .value_kind = .array,
        .rules = &.{.{ .array_length = .{ .min = 1 } }},
        .element_kind = .string,
        .element_rules = &.{.non_empty_string},
    },
};

const permission_rule_fields = [_]framework.FieldDefinition{
    .{ .key = "permission", .required = true, .value_kind = .string, .rules = &.{.non_empty_string} },
    .{ .key = "pattern", .required = true, .value_kind = .string, .rules = &.{.non_empty_string} },
    .{
        .key = "action",
        .required = true,
        .value_kind = .enum_string,
        .rules = &.{.{ .enum_string = &.{ "allow", "deny", "ask" } }},
    },
};

const field_definitions = [_]framework.FieldDefinition{
    .{
        .key = keys.model_default,
        .required = false,
        .value_kind = .string,
        .rules = &.{.non_empty_string},
    },
    .{
        .key = keys.model_small,
        .required = false,
        .value_kind = .string,
        .rules = &.{.non_empty_string},
    },
    .{
        .key = keys.agent_default,
        .required = false,
        .value_kind = .string,
        .rules = &.{.non_empty_string},
    },
    .{
        .key = keys.permission_rules,
        .required = false,
        .value_kind = .array,
        .element_kind = .object,
        .element_fields = permission_rule_fields[0..],
    },
    .{
        .key = keys.session_store_path,
        .required = false,
        .requires_restart = true,
        .value_kind = .string,
        .rules = &.{.path_no_traversal},
    },
    .{
        .key = keys.server_port,
        .required = false,
        .value_kind = .integer,
        .rules = &.{.port},
    },
    .{
        .key = keys.server_hostname,
        .required = false,
        .value_kind = .string,
        .rules = &.{.hostname_or_ipv4},
    },
    .{
        .key = keys.tui_scroll_speed,
        .required = false,
        .value_kind = .integer,
        .rules = &.{.{ .int_range = .{ .min = 1 } }},
    },
    .{
        .key = keys.lsp_enabled,
        .required = false,
        .value_kind = .boolean,
    },
    .{
        .key = keys.lsp_servers,
        .required = false,
        .value_kind = .array,
        .element_kind = .object,
        .element_fields = lsp_server_fields[0..],
    },
    .{
        .key = keys.mcp_servers,
        .required = false,
        .value_kind = .array,
        .element_kind = .object,
        .element_fields = mcp_server_fields[0..],
    },
    .{
        .key = keys.formatter_definitions,
        .required = false,
        .value_kind = .array,
        .element_kind = .object,
        .element_fields = formatter_definition_fields[0..],
    },
    .{
        .key = keys.provider_anthropic_base_url,
        .required = false,
        .value_kind = .string,
    },
    .{
        .key = keys.provider_anthropic_api_key,
        .required = false,
        .sensitive = true,
        .value_kind = .string,
        .rules = &.{.non_empty_string},
    },
    .{
        .key = keys.provider_anthropic_timeout_ms,
        .required = false,
        .value_kind = .integer,
        .rules = &.{.{ .int_range = .{ .min = 1 } }},
    },
    .{
        .key = keys.provider_openai_base_url,
        .required = false,
        .value_kind = .string,
    },
    .{
        .key = keys.provider_openai_api_key,
        .required = false,
        .sensitive = true,
        .value_kind = .string,
        .rules = &.{.non_empty_string},
    },
    .{
        .key = keys.provider_openai_timeout_ms,
        .required = false,
        .value_kind = .integer,
        .rules = &.{.{ .int_range = .{ .min = 1 } }},
    },
    .{
        .key = keys.tool_read_file_enabled,
        .required = false,
        .value_kind = .boolean,
    },
    .{
        .key = keys.tool_write_file_enabled,
        .required = false,
        .value_kind = .boolean,
    },
    .{
        .key = keys.tool_execute_shell_enabled,
        .required = false,
        .value_kind = .boolean,
    },
    .{
        .key = keys.tool_list_files_enabled,
        .required = false,
        .value_kind = .boolean,
    },
    .{
        .key = keys.tool_search_files_enabled,
        .required = false,
        .value_kind = .boolean,
    },
    .{
        .key = keys.tool_fetch_url_enabled,
        .required = false,
        .value_kind = .boolean,
    },
    .{
        .key = keys.tool_lsp_enabled,
        .required = false,
        .value_kind = .boolean,
    },
};

pub fn fieldDefinitions() []const framework.FieldDefinition {
    return field_definitions[0..];
}

test "config schema exports stable canonical keys" {
    try std.testing.expectEqualStrings("model.default", keys.model_default);
    try std.testing.expect(fieldDefinitions().len >= 10);
}
