const std = @import("std");
const framework = @import("framework");
const permission = @import("../permission/root.zig");
const provider = @import("../provider/root.zig");
const schema = @import("schema.zig");
const paths = @import("paths.zig");

pub const ModelConfig = struct {
    default_model: ?provider.ModelRef = null,
    small_model: ?provider.ModelRef = null,
};

pub const PermissionConfig = struct {
    rules: []permission.PermissionRule,

    pub fn deinit(self: *PermissionConfig, allocator: std.mem.Allocator) void {
        for (self.rules) |*rule| rule.deinit(allocator);
        allocator.free(self.rules);
    }
};

pub const SessionConfig = struct {
    store_path: []const u8,

    pub fn deinit(self: *SessionConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.store_path);
    }
};

pub const ServerConfig = struct {
    port: ?u16 = null,
    hostname: ?[]const u8 = null,

    pub fn deinit(self: *ServerConfig, allocator: std.mem.Allocator) void {
        if (self.hostname) |hostname| allocator.free(hostname);
    }
};

pub const TuiConfig = struct {
    scroll_speed: u32,
};

pub const LspServerConfig = struct {
    id: []const u8,
    disabled: bool = false,
    command: [][]const u8,
    extensions: [][]const u8,
    root_markers: [][]const u8,
    initialization_json: ?[]const u8 = null,

    pub fn deinit(self: *LspServerConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        freeStringSlice(allocator, self.command);
        freeStringSlice(allocator, self.extensions);
        freeStringSlice(allocator, self.root_markers);
        if (self.initialization_json) |value| allocator.free(value);
    }
};

pub const LspConfig = struct {
    enabled: bool,
    servers: []LspServerConfig,

    pub fn deinit(self: *LspConfig, allocator: std.mem.Allocator) void {
        for (self.servers) |*server| server.deinit(allocator);
        allocator.free(self.servers);
    }
};

pub const McpServerTransport = enum {
    local,
    remote,

    pub fn fromText(text: []const u8) ?McpServerTransport {
        if (std.mem.eql(u8, text, "local")) return .local;
        if (std.mem.eql(u8, text, "remote")) return .remote;
        return null;
    }

    pub fn asText(self: McpServerTransport) []const u8 {
        return switch (self) {
            .local => "local",
            .remote => "remote",
        };
    }
};

pub const McpServerConfig = struct {
    id: []const u8,
    transport: McpServerTransport,
    disabled: bool = false,
    command: [][]const u8,
    url: ?[]const u8 = null,
    timeout_ms: ?u32 = null,

    pub fn deinit(self: *McpServerConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        freeStringSlice(allocator, self.command);
        if (self.url) |value| allocator.free(value);
    }
};

pub const McpConfig = struct {
    servers: []McpServerConfig,

    pub fn deinit(self: *McpConfig, allocator: std.mem.Allocator) void {
        for (self.servers) |*server| server.deinit(allocator);
        allocator.free(self.servers);
    }
};

pub const FormatterDefinitionConfig = struct {
    name: []const u8,
    enabled: bool = true,
    extensions: [][]const u8,
    command: [][]const u8,

    pub fn deinit(self: *FormatterDefinitionConfig, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        freeStringSlice(allocator, self.extensions);
        freeStringSlice(allocator, self.command);
    }
};

pub const FormatterConfig = struct {
    definitions: []FormatterDefinitionConfig,

    pub fn deinit(self: *FormatterConfig, allocator: std.mem.Allocator) void {
        for (self.definitions) |*item| item.deinit(allocator);
        allocator.free(self.definitions);
    }
};

pub const ToolPolicy = struct {
    read_file_enabled: bool,
    write_file_enabled: bool,
    execute_shell_enabled: bool,
    list_files_enabled: bool,
    search_files_enabled: bool,
    fetch_url_enabled: bool,
    lsp_enabled: bool,
};

pub const AnthropicProviderConfig = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    timeout_ms: ?u32 = null,

    pub fn deinit(self: *AnthropicProviderConfig, allocator: std.mem.Allocator) void {
        if (self.base_url) |base_url| allocator.free(base_url);
        if (self.api_key) |api_key| allocator.free(api_key);
    }
};

pub const OpenAIProviderConfig = struct {
    base_url: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    timeout_ms: ?u32 = null,

    pub fn deinit(self: *OpenAIProviderConfig, allocator: std.mem.Allocator) void {
        if (self.base_url) |base_url| allocator.free(base_url);
        if (self.api_key) |api_key| allocator.free(api_key);
    }
};

pub const EffectiveConfig = struct {
    model: ModelConfig,
    default_agent: []const u8,
    permission: PermissionConfig,
    session: SessionConfig,
    server: ServerConfig,
    tui: TuiConfig,
    lsp: LspConfig,
    mcp: McpConfig,
    formatter: FormatterConfig,
    tools: ToolPolicy,
    anthropic: AnthropicProviderConfig,
    openai: OpenAIProviderConfig,

    pub fn deinit(self: *EffectiveConfig, allocator: std.mem.Allocator) void {
        if (self.model.default_model) |model| {
            allocator.free(model.provider_id);
            allocator.free(model.model_id);
        }
        if (self.model.small_model) |model| {
            allocator.free(model.provider_id);
            allocator.free(model.model_id);
        }
        allocator.free(self.default_agent);
        self.permission.deinit(allocator);
        self.session.deinit(allocator);
        self.server.deinit(allocator);
        self.lsp.deinit(allocator);
        self.mcp.deinit(allocator);
        self.formatter.deinit(allocator);
        self.anthropic.deinit(allocator);
        self.openai.deinit(allocator);
    }
};

pub fn buildEffectiveConfig(
    allocator: std.mem.Allocator,
    store: framework.ConfigStore,
    defaults: framework.ConfigDefaults,
    resolved_paths: *const paths.ResolvedPaths,
) !EffectiveConfig {
    const loader = framework.ConfigLoader.init(allocator, store, defaults);

    return .{
        .model = .{
            .default_model = try loadModelRef(allocator, loader, schema.keys.model_default),
            .small_model = try loadModelRef(allocator, loader, schema.keys.model_small),
        },
        .default_agent = try loadRequiredString(allocator, loader, schema.keys.agent_default),
        .permission = .{
            .rules = try loadPermissionRules(allocator, loader, schema.keys.permission_rules),
        },
        .session = .{
            .store_path = try resolveStorePath(allocator, loader, resolved_paths),
        },
        .server = .{
            .port = if (try loadOptionalInt(loader, schema.keys.server_port)) |value| @intCast(value) else null,
            .hostname = try loadOptionalString(allocator, loader, schema.keys.server_hostname),
        },
        .tui = .{
            .scroll_speed = @intCast((try loadOptionalInt(loader, schema.keys.tui_scroll_speed)) orelse 3),
        },
        .lsp = .{
            .enabled = (try loadOptionalBool(loader, schema.keys.lsp_enabled)) orelse true,
            .servers = try loadLspServers(allocator, loader, schema.keys.lsp_servers),
        },
        .mcp = .{
            .servers = try loadMcpServers(allocator, loader, schema.keys.mcp_servers),
        },
        .formatter = .{
            .definitions = try loadFormatterDefinitions(allocator, loader, schema.keys.formatter_definitions),
        },
        .tools = .{
            .read_file_enabled = (try loadOptionalBool(loader, schema.keys.tool_read_file_enabled)) orelse true,
            .write_file_enabled = (try loadOptionalBool(loader, schema.keys.tool_write_file_enabled)) orelse true,
            .execute_shell_enabled = (try loadOptionalBool(loader, schema.keys.tool_execute_shell_enabled)) orelse true,
            .list_files_enabled = (try loadOptionalBool(loader, schema.keys.tool_list_files_enabled)) orelse true,
            .search_files_enabled = (try loadOptionalBool(loader, schema.keys.tool_search_files_enabled)) orelse true,
            .fetch_url_enabled = (try loadOptionalBool(loader, schema.keys.tool_fetch_url_enabled)) orelse true,
            .lsp_enabled = (try loadOptionalBool(loader, schema.keys.tool_lsp_enabled)) orelse true,
        },
        .anthropic = .{
            .base_url = try loadOptionalString(allocator, loader, schema.keys.provider_anthropic_base_url),
            .api_key = try loadOptionalString(allocator, loader, schema.keys.provider_anthropic_api_key),
            .timeout_ms = if (try loadOptionalInt(loader, schema.keys.provider_anthropic_timeout_ms)) |value| @intCast(value) else null,
        },
        .openai = .{
            .base_url = try loadOptionalString(allocator, loader, schema.keys.provider_openai_base_url),
            .api_key = try loadOptionalString(allocator, loader, schema.keys.provider_openai_api_key),
            .timeout_ms = if (try loadOptionalInt(loader, schema.keys.provider_openai_timeout_ms)) |value| @intCast(value) else null,
        },
    };
}

fn resolveStorePath(
    allocator: std.mem.Allocator,
    loader: framework.ConfigLoader,
    resolved_paths: *const paths.ResolvedPaths,
) ![]const u8 {
    const raw = try loadRequiredString(allocator, loader, schema.keys.session_store_path);
    defer allocator.free(raw);

    const base_dir = if (resolved_paths.project_config_path) |config_path|
        std.fs.path.dirname(config_path) orelse resolved_paths.current_dir
    else
        resolved_paths.current_dir;

    return paths.resolveRelativeToBase(allocator, base_dir, raw);
}

fn loadModelRef(
    allocator: std.mem.Allocator,
    loader: framework.ConfigLoader,
    key: []const u8,
) !?provider.ModelRef {
    const raw = try loadOptionalString(allocator, loader, key);
    if (raw == null) return null;
    errdefer allocator.free(raw.?);

    const slash_index = std.mem.indexOfScalar(u8, raw.?, '/') orelse return error.InvalidModelRef;
    const model_ref: provider.ModelRef = .{
        .provider_id = try allocator.dupe(u8, raw.?[0..slash_index]),
        .model_id = try allocator.dupe(u8, raw.?[slash_index + 1 ..]),
    };
    allocator.free(raw.?);
    return model_ref;
}

fn loadRequiredString(
    allocator: std.mem.Allocator,
    loader: framework.ConfigLoader,
    key: []const u8,
) ![]const u8 {
    const value = try loadOptionalString(allocator, loader, key);
    return value orelse error.MissingRequiredConfigValue;
}

fn loadOptionalString(
    allocator: std.mem.Allocator,
    loader: framework.ConfigLoader,
    key: []const u8,
) !?[]const u8 {
    var loaded = try loader.loadValue(key);
    defer loaded.deinit(allocator);
    const json = loaded.effectiveValueJson() orelse return null;
    const parsed = try framework.ConfigValueParser.parseJsonValue(allocator, .string, json);
    defer parsed.deinit(allocator);
    return @as(?[]const u8, try allocator.dupe(u8, parsed.string));
}

fn loadOptionalInt(loader: framework.ConfigLoader, key: []const u8) !?i64 {
    var loaded = try loader.loadValue(key);
    defer loaded.deinit(loader.allocator);
    const json = loaded.effectiveValueJson() orelse return null;
    const parsed = try framework.ConfigValueParser.parseJsonValue(loader.allocator, .integer, json);
    defer parsed.deinit(loader.allocator);
    return parsed.integer;
}

fn loadOptionalBool(loader: framework.ConfigLoader, key: []const u8) !?bool {
    var loaded = try loader.loadValue(key);
    defer loaded.deinit(loader.allocator);
    const json = loaded.effectiveValueJson() orelse return null;
    const parsed = try framework.ConfigValueParser.parseJsonValue(loader.allocator, .boolean, json);
    defer parsed.deinit(loader.allocator);
    return parsed.boolean;
}

fn loadPermissionRules(
    allocator: std.mem.Allocator,
    loader: framework.ConfigLoader,
    key: []const u8,
) ![]permission.PermissionRule {
    var loaded = try loader.loadValue(key);
    defer loaded.deinit(allocator);
    const json_text = loaded.effectiveValueJson() orelse return allocator.alloc(permission.PermissionRule, 0);
    const parsed = try framework.ConfigValueParser.parseJsonValue(allocator, .array, json_text);
    defer parsed.deinit(allocator);
    if (parsed != .array) return error.InvalidPermissionRules;

    const result = try allocator.alloc(permission.PermissionRule, parsed.array.len);
    errdefer allocator.free(result);
    for (parsed.array, 0..) |item, index| {
        if (item != .object) return error.InvalidPermissionRules;
        result[index] = try parsePermissionRule(allocator, item.object);
        errdefer result[index].deinit(allocator);
    }
    return result;
}

fn parsePermissionRule(allocator: std.mem.Allocator, fields: []const framework.ValidationField) !permission.PermissionRule {
    return .{
        .permission = try allocator.dupe(u8, objectString(fields, "permission") orelse return error.InvalidPermissionRules),
        .pattern = try allocator.dupe(u8, objectString(fields, "pattern") orelse return error.InvalidPermissionRules),
        .action = permission.PermissionAction.fromText(objectString(fields, "action") orelse return error.InvalidPermissionRules) orelse return error.InvalidPermissionRules,
    };
}

fn loadLspServers(
    allocator: std.mem.Allocator,
    loader: framework.ConfigLoader,
    key: []const u8,
) ![]LspServerConfig {
    var loaded = try loader.loadValue(key);
    defer loaded.deinit(allocator);
    const json_text = loaded.effectiveValueJson() orelse return allocator.alloc(LspServerConfig, 0);
    const parsed = try framework.ConfigValueParser.parseJsonValue(allocator, .array, json_text);
    defer parsed.deinit(allocator);
    if (parsed != .array) return error.InvalidLspServerConfig;

    const result = try allocator.alloc(LspServerConfig, parsed.array.len);
    errdefer allocator.free(result);

    for (parsed.array, 0..) |item, index| {
        if (item != .object) return error.InvalidLspServerConfig;
        result[index] = try parseLspServerConfig(allocator, item.object);
        errdefer result[index].deinit(allocator);
    }
    return result;
}

fn loadMcpServers(
    allocator: std.mem.Allocator,
    loader: framework.ConfigLoader,
    key: []const u8,
) ![]McpServerConfig {
    var loaded = try loader.loadValue(key);
    defer loaded.deinit(allocator);
    const json_text = loaded.effectiveValueJson() orelse return allocator.alloc(McpServerConfig, 0);
    const parsed = try framework.ConfigValueParser.parseJsonValue(allocator, .array, json_text);
    defer parsed.deinit(allocator);
    if (parsed != .array) return error.InvalidMcpServerConfig;

    const result = try allocator.alloc(McpServerConfig, parsed.array.len);
    errdefer allocator.free(result);

    for (parsed.array, 0..) |item, index| {
        if (item != .object) return error.InvalidMcpServerConfig;
        result[index] = try parseMcpServerConfig(allocator, item.object);
        errdefer result[index].deinit(allocator);
    }
    return result;
}

fn loadFormatterDefinitions(
    allocator: std.mem.Allocator,
    loader: framework.ConfigLoader,
    key: []const u8,
) ![]FormatterDefinitionConfig {
    var loaded = try loader.loadValue(key);
    defer loaded.deinit(allocator);
    const json_text = loaded.effectiveValueJson() orelse return allocator.alloc(FormatterDefinitionConfig, 0);
    const parsed = try framework.ConfigValueParser.parseJsonValue(allocator, .array, json_text);
    defer parsed.deinit(allocator);
    if (parsed != .array) return error.InvalidFormatterConfig;

    const result = try allocator.alloc(FormatterDefinitionConfig, parsed.array.len);
    errdefer allocator.free(result);
    for (parsed.array, 0..) |item, index| {
        if (item != .object) return error.InvalidFormatterConfig;
        result[index] = try parseFormatterDefinitionConfig(allocator, item.object);
        errdefer result[index].deinit(allocator);
    }
    return result;
}

fn parseLspServerConfig(allocator: std.mem.Allocator, fields: []const framework.ValidationField) !LspServerConfig {
    return .{
        .id = try allocator.dupe(u8, objectString(fields, "id") orelse return error.InvalidLspServerConfig),
        .disabled = objectBool(fields, "disabled") orelse false,
        .command = try objectStringArray(allocator, fields, "command"),
        .extensions = try objectStringArray(allocator, fields, "extensions"),
        .root_markers = try objectOptionalStringArray(allocator, fields, "root_markers"),
        .initialization_json = if (objectString(fields, "initialization_json")) |value| try allocator.dupe(u8, value) else null,
    };
}

fn parseMcpServerConfig(allocator: std.mem.Allocator, fields: []const framework.ValidationField) !McpServerConfig {
    const transport = McpServerTransport.fromText(objectString(fields, "type") orelse return error.InvalidMcpServerConfig) orelse
        return error.InvalidMcpServerConfig;
    const command = try objectOptionalStringArray(allocator, fields, "command");
    errdefer freeStringSlice(allocator, command);
    const url = if (objectString(fields, "url")) |value| try allocator.dupe(u8, value) else null;
    errdefer if (url) |value| allocator.free(value);

    if (transport == .local and command.len == 0) return error.InvalidMcpServerConfig;
    if (transport == .remote and url == null) return error.InvalidMcpServerConfig;

    return .{
        .id = try allocator.dupe(u8, objectString(fields, "id") orelse return error.InvalidMcpServerConfig),
        .transport = transport,
        .disabled = objectBool(fields, "disabled") orelse false,
        .command = command,
        .url = url,
        .timeout_ms = if (objectInt(fields, "timeout_ms")) |value| @intCast(value) else null,
    };
}

fn parseFormatterDefinitionConfig(allocator: std.mem.Allocator, fields: []const framework.ValidationField) !FormatterDefinitionConfig {
    return .{
        .name = try allocator.dupe(u8, objectString(fields, "name") orelse return error.InvalidFormatterConfig),
        .enabled = objectBool(fields, "enabled") orelse true,
        .extensions = try objectStringArray(allocator, fields, "extensions"),
        .command = try objectStringArray(allocator, fields, "command"),
    };
}

fn objectString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn objectBool(fields: []const framework.ValidationField, key: []const u8) ?bool {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .boolean) return field.value.boolean;
    }
    return null;
}

fn objectInt(fields: []const framework.ValidationField, key: []const u8) ?i64 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .integer) return field.value.integer;
    }
    return null;
}

fn objectStringArray(
    allocator: std.mem.Allocator,
    fields: []const framework.ValidationField,
    key: []const u8,
) ![][]const u8 {
    for (fields) |field| {
        if (!std.mem.eql(u8, field.key, key)) continue;
        if (field.value != .array) return error.InvalidLspServerConfig;
        return cloneStringArray(allocator, field.value.array);
    }
    return error.InvalidLspServerConfig;
}

fn objectOptionalStringArray(
    allocator: std.mem.Allocator,
    fields: []const framework.ValidationField,
    key: []const u8,
) ![][]const u8 {
    for (fields) |field| {
        if (!std.mem.eql(u8, field.key, key)) continue;
        if (field.value != .array) return error.InvalidLspServerConfig;
        return cloneStringArray(allocator, field.value.array);
    }
    return allocator.alloc([]const u8, 0);
}

fn cloneStringArray(allocator: std.mem.Allocator, items: []const framework.ValidationValue) ![][]const u8 {
    const cloned = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(cloned);

    for (items, 0..) |item, index| {
        if (item != .string) return error.InvalidLspServerConfig;
        cloned[index] = try allocator.dupe(u8, item.string);
    }

    return cloned;
}

fn freeStringSlice(allocator: std.mem.Allocator, items: [][]const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}
