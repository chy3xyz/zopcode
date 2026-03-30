pub const read_file = @import("read_file.zig");
pub const write_file = @import("write_file.zig");
pub const list_files = @import("list_files.zig");
pub const search_files = @import("search_files.zig");
pub const fetch_url = @import("fetch_url.zig");
pub const repo_health_check = @import("repo_health_check.zig");
pub const execute_shell = @import("execute_shell.zig");
pub const edit_file = @import("edit_file.zig");
pub const lsp = @import("lsp.zig");
pub const mcp_resource = @import("mcp_resource.zig");
pub const question = @import("question.zig");
pub const revert_files = @import("revert_files.zig");
pub const skill = @import("skill.zig");

const tool_model = @import("../tool.zig");

const builtin_tools = [_]tool_model.ToolDefinition{
    read_file.definition(),
    write_file.definition(),
    list_files.definition(),
    search_files.definition(),
    fetch_url.definition(),
    repo_health_check.definition(),
    execute_shell.definition(),
    edit_file.definition(),
    lsp.definition(),
    mcp_resource.definition(),
    question.definition(),
    revert_files.definition(),
    skill.definition(),
};

pub fn builtins() []const tool_model.ToolDefinition {
    return builtin_tools[0..];
}
