const std = @import("std");
const model = @import("model.zig");
const question = @import("../question/root.zig");

pub fn renderSummary(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    const project_name = if (vm.project) |project| project.name else "-";
    const branch = if (vm.project) |project| project.branch orelse "-" else "-";
    return std.fmt.allocPrint(allocator, "session={s} agent={s} model={s} status={s} tool={s} panel={s} project={s} branch={s} pending={d}", .{
        vm.active_session_id orelse "-",
        vm.active_agent_id orelse "-",
        vm.active_model orelse "-",
        vm.status,
        vm.recent_tool orelse "-",
        vm.active_panel.asText(),
        project_name,
        branch,
        vm.pendingInteractionCount(),
    });
}

pub fn renderSidebar(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "== Sidebar ==\n");
    try out.print(allocator, "Sessions: {d}\n", .{vm.session_statuses.len});
    try out.print(allocator, "Workspaces: {d}\n", .{vm.workspaces.len});
    try out.print(allocator, "Providers: {d}\n", .{if (vm.provider_catalog) |catalog| catalog.providers.len else 0});
    try out.print(allocator, "LSP: {d} | MCP: {d} | Formatter: {d}\n", .{
        vm.lsp_statuses.len,
        vm.mcp_statuses.len,
        vm.formatter_statuses.len,
    });
    try out.print(allocator, "Pending permissions: {d} | questions: {d}\n", .{
        vm.pending_permissions.len,
        vm.pending_questions.len,
    });

    return allocator.dupe(u8, out.items);
}

pub fn renderPanel(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    return switch (vm.active_panel) {
        .dashboard => renderDashboard(allocator, vm),
        .sessions => renderSessions(allocator, vm),
        .workspaces => renderWorkspaces(allocator, vm),
        .runtime => renderRuntime(allocator, vm),
        .pending => renderPending(allocator, vm),
    };
}

pub fn renderEventStream(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    return std.mem.join(allocator, "\n", vm.event_lines.items);
}

pub fn renderLatestResponse(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    return allocator.dupe(u8, vm.latest_response orelse "");
}

fn renderDashboard(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    try out.appendSlice(allocator, "== Dashboard ==\n");
    if (vm.project) |project| {
        try out.print(allocator, "Project: {s}\n", .{project.name});
        try out.print(allocator, "Root: {s}\n", .{project.project_root});
        try out.print(allocator, "VCS: {s} dirty={s} changed={d}\n", .{
            project.branch orelse "-",
            if (project.dirty) "yes" else "no",
            project.changed_file_count,
        });
    }
    if (vm.provider_catalog) |catalog| {
        try out.print(allocator, "Default model: {s}\n", .{catalog.default_model orelse "-"});
    }
    try out.print(allocator, "Pending interactions: {d}\n", .{vm.pendingInteractionCount()});
    return allocator.dupe(u8, out.items);
}

fn renderSessions(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "== Sessions ==\n");
    for (vm.session_statuses) |item| {
        try out.print(allocator, "{s} [{s}]\n", .{ item.session_id, item.status });
    }
    return allocator.dupe(u8, out.items);
}

fn renderWorkspaces(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "== Workspaces ==\n");
    for (vm.workspaces) |item| {
        try out.print(allocator, "{s} ({s})\n", .{ item.name, item.id });
    }
    return allocator.dupe(u8, out.items);
}

fn renderRuntime(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "== Runtime ==\n");
    if (vm.provider_catalog) |catalog| {
        try out.print(allocator, "Providers: {d}\n", .{catalog.providers.len});
        for (catalog.providers) |provider| {
            try out.print(allocator, "- {s} [{s}] default={s}\n", .{ provider.id, provider.status, provider.default_model });
        }
    }
    try out.print(allocator, "Formatter statuses: {d}\n", .{vm.formatter_statuses.len});
    for (vm.formatter_statuses) |status| {
        try out.print(allocator, "- {s} enabled={s}\n", .{ status.name, if (status.enabled) "yes" else "no" });
    }
    try out.print(allocator, "LSP statuses: {d}\n", .{vm.lsp_statuses.len});
    try out.print(allocator, "MCP statuses: {d}\n", .{vm.mcp_statuses.len});
    return allocator.dupe(u8, out.items);
}

fn renderPending(allocator: std.mem.Allocator, vm: *const model.TerminalViewModel) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "== Pending ==\n");

    if (vm.pending_permissions.len == 0 and vm.pending_questions.len == 0) {
        try out.appendSlice(allocator, "No pending interactions\n");
        return allocator.dupe(u8, out.items);
    }

    if (vm.pending_permissions.len > 0) {
        try out.appendSlice(allocator, "Permissions:\n");
        for (vm.pending_permissions) |item| {
            try out.print(allocator, "- {s}: {s} tool={s}\n", .{
                item.id,
                item.permission,
                item.tool_name orelse "-",
            });
        }
        try out.appendSlice(allocator, "Use /permission <id> once|reject\n");
    }

    if (vm.pending_questions.len > 0) {
        try out.appendSlice(allocator, "Questions:\n");
        for (vm.pending_questions) |item| {
            const header = if (item.questions.len > 0) item.questions[0].header else "-";
            try out.print(allocator, "- {s}: {s}\n", .{ item.id, header });
        }
        try out.appendSlice(allocator, "Use /question <id> A;B,C style answers\n");
    }

    return allocator.dupe(u8, out.items);
}

test "terminal render output includes sidebar and richer runtime state" {
    var vm = try model.TerminalViewModel.init(std.testing.allocator, 4);
    defer vm.deinit();
    try vm.setSession("session_01");
    try vm.setStatus("completed");
    try vm.replaceSessionStatuses(&.{
        .{ .session_id = "session_01", .status = "completed", .updated_at_ms = 1 },
    });
    try vm.replaceWorkspaces(&.{
        .{ .id = "workspace_01", .name = "demo", .path = "E:/demo", .created_at_ms = 1 },
    });
    try vm.replaceFormatterStatuses(&.{
        .{ .name = "zigfmt", .enabled = true, .extensions = @constCast(&[_][]const u8{".zig"}) },
    });
    vm.setPanel(.runtime);

    const summary = try renderSummary(std.testing.allocator, &vm);
    defer std.testing.allocator.free(summary);
    const sidebar = try renderSidebar(std.testing.allocator, &vm);
    defer std.testing.allocator.free(sidebar);
    const panel = try renderPanel(std.testing.allocator, &vm);
    defer std.testing.allocator.free(panel);

    try std.testing.expect(std.mem.indexOf(u8, summary, "panel=runtime") != null);
    try std.testing.expect(std.mem.indexOf(u8, sidebar, "Sessions: 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "Formatter statuses: 1") != null);
}

test "terminal render output shows pending interactions" {
    var vm = try model.TerminalViewModel.init(std.testing.allocator, 4);
    defer vm.deinit();
    vm.setPanel(.pending);
    try vm.replacePendingPermissions(&.{
        .{ .id = "perm_01", .session_id = "session_01", .permission = "edit", .tool_name = "write_file", .patterns = @constCast(&[_][]const u8{"src/main.zig"}) },
    });
    try vm.replacePendingQuestions(&.{
        .{ .id = "question_01", .session_id = "session_01", .questions = @constCast(&[_]question.QuestionInfo{
            .{ .header = "Mode", .question = "Choose", .options = @constCast(&[_]question.QuestionOption{.{ .label = "A", .description = "alpha" }}) },
        }) },
    });

    const panel = try renderPanel(std.testing.allocator, &vm);
    defer std.testing.allocator.free(panel);
    try std.testing.expect(std.mem.indexOf(u8, panel, "perm_01") != null);
    try std.testing.expect(std.mem.indexOf(u8, panel, "question_01") != null);
}
