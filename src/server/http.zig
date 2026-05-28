const std = @import("std");
const framework = @import("framework");
const pty_test_backend = @import("../pty/test_backend.zig");
const question = @import("../question/root.zig");
const session = @import("../session/root.zig");
const dto = @import("dto.zig");
const services_model = @import("services.zig");

pub const Method = enum {
    GET,
    POST,

    pub fn parse(text: []const u8) ?Method {
        if (std.mem.eql(u8, text, "GET")) return .GET;
        if (std.mem.eql(u8, text, "POST")) return .POST;
        return null;
    }
};

pub const Request = struct {
    method: Method,
    target: []const u8,
    body: ?[]const u8 = null,
};

pub const Response = struct {
    status: u16,
    content_type: []u8,
    body: []u8,

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        allocator.free(self.content_type);
        allocator.free(self.body);
    }
};

pub fn handleRequest(allocator: std.mem.Allocator, services: *services_model.ServerServices, request: Request) !Response {
    const split = splitTarget(request.target);

    if (request.method == .POST and std.mem.eql(u8, split.path, "/session")) {
        const parsed = if (request.body) |body|
            try std.json.parseFromSlice(dto.CreateSessionRequest, allocator, body, .{ .ignore_unknown_fields = true })
        else
            try std.json.parseFromSlice(dto.CreateSessionRequest, allocator, "{}", .{});
        defer parsed.deinit();

        var created = try services.createSession(parsed.value);
        defer created.deinit(allocator);
        return jsonResponse(allocator, 200, created);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/session/status")) {
        var statuses = try services.listStatuses();
        defer statuses.deinit(allocator);
        return jsonResponse(allocator, 200, statuses);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/lsp")) {
        var statuses = try services.listLspStatus();
        defer statuses.deinit(allocator);
        return jsonResponse(allocator, 200, statuses);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/formatter")) {
        var statuses = try services.listFormatterStatus();
        defer statuses.deinit(allocator);
        return jsonResponse(allocator, 200, statuses);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/mcp")) {
        var statuses = try services.listMcpStatus();
        defer statuses.deinit(allocator);
        return jsonResponse(allocator, 200, statuses);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/provider")) {
        var catalog = try services.listProviderCatalog();
        defer catalog.deinit(allocator);
        return jsonResponse(allocator, 200, catalog);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/provider/auth")) {
        var auth_items = try services.listProviderAuth();
        defer auth_items.deinit(allocator);
        return jsonResponse(allocator, 200, auth_items);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/plugin")) {
        var plugins = try services.listPlugins();
        defer plugins.deinit(allocator);
        return jsonResponse(allocator, 200, plugins);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/skill")) {
        var skills = try services.listSkills();
        defer skills.deinit(allocator);
        return jsonResponse(allocator, 200, skills);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/project")) {
        var info = try services.getProject();
        defer info.deinit(allocator);
        return jsonResponse(allocator, 200, info);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/workspace")) {
        var workspaces = try services.listWorkspaces();
        defer workspaces.deinit(allocator);
        return jsonResponse(allocator, 200, workspaces);
    }

    if (request.method == .POST and std.mem.eql(u8, split.path, "/workspace")) {
        const body = request.body orelse return error.MissingRequestBody;
        const parsed = try std.json.parseFromSlice(dto.CreateWorkspaceRequest, allocator, body, .{ .ignore_unknown_fields = true });
        defer parsed.deinit();
        var created = try services.createWorkspace(parsed.value);
        defer created.deinit(allocator);
        return jsonResponse(allocator, 200, created);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/pty")) {
        var ptys = try services.listPtys();
        defer ptys.deinit(allocator);
        return jsonResponse(allocator, 200, ptys);
    }

    if (request.method == .POST and std.mem.eql(u8, split.path, "/pty")) {
        const parsed = if (request.body) |body|
            try std.json.parseFromSlice(dto.CreatePtyRequest, allocator, body, .{ .ignore_unknown_fields = true })
        else
            try std.json.parseFromSlice(dto.CreatePtyRequest, allocator, "{}", .{});
        defer parsed.deinit();
        var created = try services.createPty(parsed.value);
        defer created.deinit(allocator);
        return jsonResponse(allocator, 200, created);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/permission")) {
        var permissions = try services.listPermissions();
        defer permissions.deinit(allocator);
        return jsonResponse(allocator, 200, permissions);
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/question")) {
        var questions = try services.listQuestions();
        defer questions.deinit(allocator);
        return jsonResponse(allocator, 200, questions);
    }

    if (request.method == .POST and std.mem.startsWith(u8, split.path, "/permission/")) {
        const rest = split.path["/permission/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const request_id = rest[0..slash];
            const suffix = rest[slash..];
            if (std.mem.eql(u8, suffix, "/reply")) {
                const body = request.body orelse return error.MissingRequestBody;
                const parsed = try std.json.parseFromSlice(dto.PermissionReplyRequest, allocator, body, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                var ack = try services.replyPermission(request_id, parsed.value);
                defer ack.deinit(allocator);
                return jsonResponse(allocator, 200, ack);
            }
        }
    }

    if (request.method == .POST and std.mem.startsWith(u8, split.path, "/provider/")) {
        const rest = split.path["/provider/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const provider_id = rest[0..slash];
            const suffix = rest[slash..];
            if (std.mem.eql(u8, suffix, "/auth")) {
                const body = request.body orelse return error.MissingRequestBody;
                const parsed = try std.json.parseFromSlice(dto.ProviderAuthSetRequest, allocator, body, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                var ack = try services.setProviderAuth(provider_id, parsed.value);
                defer ack.deinit(allocator);
                return jsonResponse(allocator, 200, ack);
            }
            if (std.mem.eql(u8, suffix, "/auth/remove")) {
                var ack = try services.removeProviderAuth(provider_id);
                defer ack.deinit(allocator);
                return jsonResponse(allocator, 200, ack);
            }
        }
    }

    if (request.method == .POST and std.mem.startsWith(u8, split.path, "/workspace/")) {
        const rest = split.path["/workspace/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const workspace_id = rest[0..slash];
            const suffix = rest[slash..];
            if (std.mem.eql(u8, suffix, "/remove")) {
                var ack = try services.removeWorkspace(workspace_id);
                defer ack.deinit(allocator);
                return jsonResponse(allocator, 200, ack);
            }
        }
    }

    if (std.mem.startsWith(u8, split.path, "/pty/")) {
        const rest = split.path["/pty/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const pty_id = rest[0..slash];
            const suffix = rest[slash..];
            if (request.method == .POST and std.mem.eql(u8, suffix, "/input")) {
                const body = request.body orelse return error.MissingRequestBody;
                const parsed = try std.json.parseFromSlice(dto.PtyInputRequest, allocator, body, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                var ack = try services.writePtyInput(pty_id, parsed.value);
                defer ack.deinit(allocator);
                return jsonResponse(allocator, 200, ack);
            }
            if (request.method == .POST and std.mem.eql(u8, suffix, "/remove")) {
                var ack = try services.removePty(pty_id);
                defer ack.deinit(allocator);
                return jsonResponse(allocator, 200, ack);
            }
            if (request.method == .GET and std.mem.eql(u8, suffix, "/output")) {
                const after_seq = parseQueryInt(split.query, "after_seq") orelse 0;
                const limit = parseQueryInt(split.query, "limit") orelse 64;
                const follow_ms = parseQueryInt(split.query, "follow_ms") orelse 0;
                var output = try services.readPtyOutput(pty_id, after_seq, @intCast(limit), follow_ms);
                defer output.deinit(allocator);
                return jsonResponse(allocator, 200, output);
            }
        } else if (request.method == .GET) {
            var info = (try services.getPty(rest)) orelse return notFound(allocator);
            defer info.deinit(allocator);
            return jsonResponse(allocator, 200, info);
        }
    }

    if (request.method == .POST and std.mem.startsWith(u8, split.path, "/question/")) {
        const rest = split.path["/question/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const request_id = rest[0..slash];
            const suffix = rest[slash..];
            if (std.mem.eql(u8, suffix, "/reply")) {
                const body = request.body orelse return error.MissingRequestBody;
                const parsed = try std.json.parseFromSlice(dto.QuestionReplyRequest, allocator, body, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                var ack = try services.replyQuestion(request_id, parsed.value);
                defer ack.deinit(allocator);
                return jsonResponse(allocator, 200, ack);
            }
            if (std.mem.eql(u8, suffix, "/reject")) {
                var ack = try services.rejectQuestion(request_id);
                defer ack.deinit(allocator);
                return jsonResponse(allocator, 200, ack);
            }
        }
    }

    if (request.method == .GET and std.mem.eql(u8, split.path, "/event")) {
        const after_seq = parseQueryInt(split.query, "after_seq") orelse 0;
        const limit = parseQueryInt(split.query, "limit") orelse 64;
        const follow_ms = parseQueryInt(split.query, "follow_ms") orelse 0;
        const events = try services.projectEvents(after_seq, @intCast(limit), follow_ms);
        defer {
            for (events) |*event| event.deinit(allocator);
            allocator.free(events);
        }
        return sseResponse(allocator, events);
    }

    if (std.mem.startsWith(u8, split.path, "/session/")) {
        const rest = split.path["/session/".len..];
        if (std.mem.indexOfScalar(u8, rest, '/')) |slash| {
            const session_id = rest[0..slash];
            const suffix = rest[slash..];

            if (request.method == .GET and std.mem.eql(u8, suffix, "/message")) {
                var history = try services.listHistory(session_id);
                defer history.deinit(allocator);
                return jsonResponse(allocator, 200, history);
            }
            if (request.method == .POST and std.mem.eql(u8, suffix, "/prompt")) {
                const body = request.body orelse return error.MissingRequestBody;
                const parsed = try std.json.parseFromSlice(dto.SubmitPromptRequest, allocator, body, .{ .ignore_unknown_fields = true });
                defer parsed.deinit();
                var accepted = try services.submitPrompt(session_id, parsed.value);
                defer accepted.deinit(allocator);
                return jsonResponse(allocator, 202, accepted);
            }
            if (request.method == .POST and std.mem.eql(u8, suffix, "/abort")) {
                var aborted = try services.abortSession(session_id);
                defer aborted.deinit(allocator);
                return jsonResponse(allocator, 200, aborted);
            }
        } else {
            if (request.method == .GET) {
                var session_info = (try services.getSession(rest)) orelse return notFound(allocator);
                defer session_info.deinit(allocator);
                return jsonResponse(allocator, 200, session_info);
            }
        }
    }

    return notFound(allocator);
}

fn jsonResponse(allocator: std.mem.Allocator, status: u16, value: anytype) !Response {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.print(allocator, "{f}", .{std.json.fmt(value, .{})});
    return .{
        .status = status,
        .content_type = try allocator.dupe(u8, "application/json"),
        .body = try allocator.dupe(u8, out.items),
    };
}

fn sseResponse(allocator: std.mem.Allocator, events: []const framework.RuntimeEvent) !Response {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);

    for (events) |event| {
        const dto_value = dto.RuntimeEventDto{
            .seq = event.seq,
            .topic = event.topic,
            .ts_unix_ms = event.ts_unix_ms,
            .payload_json = event.payload_json,
        };
        try out.appendSlice(allocator, "data: ");
        try out.print(allocator, "{f}", .{std.json.fmt(dto_value, .{})});
        try out.appendSlice(allocator, "\n\n");
    }

    return .{
        .status = 200,
        .content_type = try allocator.dupe(u8, "text/event-stream"),
        .body = try allocator.dupe(u8, out.items),
    };
}

fn notFound(allocator: std.mem.Allocator) !Response {
    return .{
        .status = 404,
        .content_type = try allocator.dupe(u8, "application/json"),
        .body = try allocator.dupe(u8, "{\"error\":\"not_found\"}"),
    };
}

const TargetParts = struct {
    path: []const u8,
    query: []const u8,
};

fn splitTarget(target: []const u8) TargetParts {
    if (std.mem.indexOfScalar(u8, target, '?')) |index| {
        return .{
            .path = target[0..index],
            .query = target[index + 1 ..],
        };
    }
    return .{
        .path = target,
        .query = "",
    };
}

fn parseQueryInt(query: []const u8, key: []const u8) ?u64 {
    var parts = std.mem.splitScalar(u8, query, '&');
    while (parts.next()) |part| {
        if (part.len == 0) continue;
        const eq_index = std.mem.indexOfScalar(u8, part, '=') orelse continue;
        if (!std.mem.eql(u8, part[0..eq_index], key)) continue;
        return std.fmt.parseInt(u64, part[eq_index + 1 ..], 10) catch null;
    }
    return null;
}

test "http route helpers handle create session and prompt submission" {
    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = services_model.ServerServices.init(std.testing.allocator, &fixture.app_context);

    var create = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = "/session",
        .body = "{\"title\":\"HTTP Session\"}",
    });
    defer create.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), create.status);

    const ParsedCreate = struct {
        session_id: []const u8,
    };
    const parsed_create = try std.json.parseFromSlice(ParsedCreate, std.testing.allocator, create.body, .{ .ignore_unknown_fields = true });
    defer parsed_create.deinit();

    const prompt_body = try std.fmt.allocPrint(std.testing.allocator, "{{\"text\":\"hello\"}}", .{});
    defer std.testing.allocator.free(prompt_body);
    const prompt_target = try std.fmt.allocPrint(std.testing.allocator, "/session/{s}/prompt", .{parsed_create.value.session_id});
    defer std.testing.allocator.free(prompt_target);
    var prompt = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = prompt_target,
        .body = prompt_body,
    });
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 202), prompt.status);

    const ParsedAccepted = struct {
        task_id: []const u8,
    };
    const parsed_prompt = try std.json.parseFromSlice(ParsedAccepted, std.testing.allocator, prompt.body, .{ .ignore_unknown_fields = true });
    defer parsed_prompt.deinit();

    var summary = try fixture.app_context.framework_app.task_runner.waitForCompletion(std.testing.allocator, parsed_prompt.value.task_id, 5000);
    defer summary.deinit(std.testing.allocator);
}

test "event endpoint projects runtime events as SSE and supports after_seq replay" {
    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = services_model.ServerServices.init(std.testing.allocator, &fixture.app_context);

    try session.publishSessionStatusEvent(std.testing.allocator, fixture.app_context.eventBus(), .{
        .session_id = "session_01",
        .status = "running",
        .request_id = "req_01",
    });
    const latest_seq = fixture.app_context.eventBus().latestSeq();

    try session.publishSessionStatusEvent(std.testing.allocator, fixture.app_context.eventBus(), .{
        .session_id = "session_01",
        .status = "completed",
        .request_id = "req_01",
    });

    const target = try std.fmt.allocPrint(std.testing.allocator, "/event?after_seq={d}", .{latest_seq});
    defer std.testing.allocator.free(target);
    var response = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = target,
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("text/event-stream", response.content_type);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "session.status") != null);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "completed") != null);
}

test "lsp status endpoint returns lsp status payload" {
    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = services_model.ServerServices.init(std.testing.allocator, &fixture.app_context);

    var response = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = "/lsp",
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type);
}

test "formatter status endpoint returns formatter status payload" {
    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = services_model.ServerServices.init(std.testing.allocator, &fixture.app_context);

    var response = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = "/formatter",
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type);
}

test "mcp status endpoint returns mcp status payload" {
    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = services_model.ServerServices.init(std.testing.allocator, &fixture.app_context);

    var response = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = "/mcp",
    });
    defer response.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expectEqualStrings("application/json", response.content_type);
    try std.testing.expect(std.mem.indexOf(u8, response.body, "failing-docs") != null);
}

test "provider catalog and auth endpoints return provider surfaces" {
    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = services_model.ServerServices.init(std.testing.allocator, &fixture.app_context);

    var catalog = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = "/provider",
    });
    defer catalog.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), catalog.status);
    try std.testing.expect(std.mem.indexOf(u8, catalog.body, "mock/mock-model") != null);

    {
        var auth_list = try handleRequest(std.testing.allocator, &services, .{
            .method = .GET,
            .target = "/provider/auth",
        });
        defer auth_list.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u16, 200), auth_list.status);
    }

    var set_auth = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = "/provider/anthropic/auth",
        .body = "{\"api_key\":\"secret\"}",
    });
    defer set_auth.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), set_auth.status);

    {
        var auth_list = try handleRequest(std.testing.allocator, &services, .{
            .method = .GET,
            .target = "/provider/auth",
        });
        defer auth_list.deinit(std.testing.allocator);
        try std.testing.expect(std.mem.indexOf(u8, auth_list.body, "anthropic") != null);
    }

    var remove_auth = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = "/provider/anthropic/auth/remove",
    });
    defer remove_auth.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), remove_auth.status);
}

test "pty endpoints create write read and remove sessions" {
    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var mock_state = pty_test_backend.State{};
    fixture.app_context.pty_runtime.backend_factory = pty_test_backend.factory(&mock_state);
    var services = services_model.ServerServices.init(std.testing.allocator, &fixture.app_context);

    var created = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = "/pty",
        .body = "{}",
    });
    defer created.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), created.status);

    const ParsedCreate = struct { id: []const u8 };
    const parsed = try std.json.parseFromSlice(ParsedCreate, std.testing.allocator, created.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var listed = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = "/pty",
    });
    defer listed.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, listed.body, parsed.value.id) != null);

    const input_target = try std.fmt.allocPrint(std.testing.allocator, "/pty/{s}/input", .{parsed.value.id});
    defer std.testing.allocator.free(input_target);
    var wrote = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = input_target,
        .body = "{\"data\":\"echo hi\\n\"}",
    });
    defer wrote.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), wrote.status);

    const output_target = try std.fmt.allocPrint(std.testing.allocator, "/pty/{s}/output?after_seq=0&limit=16&follow_ms=0", .{parsed.value.id});
    defer std.testing.allocator.free(output_target);
    var output = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = output_target,
    });
    defer output.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, output.body, "echo hi") != null);

    const remove_target = try std.fmt.allocPrint(std.testing.allocator, "/pty/{s}/remove", .{parsed.value.id});
    defer std.testing.allocator.free(remove_target);
    var removed = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = remove_target,
    });
    defer removed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), removed.status);
}

test "project and workspace endpoints return project/workspace surfaces" {
    const MockGit = struct {
        fn run(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8, argv: [][]const u8) anyerror!@import("../project/runtime.zig").RunOutput {
            if (std.mem.eql(u8, argv[2], "--show-toplevel")) {
                return .{
                    .stdout = try allocator.dupe(u8, "E:/repo\n"),
                    .stderr = try allocator.alloc(u8, 0),
                    .exit_code = 0,
                };
            }
            if (std.mem.eql(u8, argv[2], "--abbrev-ref")) {
                return .{
                    .stdout = try allocator.dupe(u8, "main\n"),
                    .stderr = try allocator.alloc(u8, 0),
                    .exit_code = 0,
                };
            }
            return .{
                .stdout = try allocator.dupe(u8, " M src/app.zig\n"),
                .stderr = try allocator.alloc(u8, 0),
                .exit_code = 0,
            };
        }
    };

    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    fixture.app_context.project_runtime.vcs_executor = .{ .ptr = undefined, .run_fn = MockGit.run };
    var services = services_model.ServerServices.init(std.testing.allocator, &fixture.app_context);

    var project_response = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = "/project",
    });
    defer project_response.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), project_response.status);
    try std.testing.expect(std.mem.indexOf(u8, project_response.body, "\"branch\":\"main\"") != null);

    var create_workspace = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = "/workspace",
        .body = "{\"name\":\"demo\"}",
    });
    defer create_workspace.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), create_workspace.status);

    const ParsedWorkspace = struct { id: []const u8 };
    const parsed = try std.json.parseFromSlice(ParsedWorkspace, std.testing.allocator, create_workspace.body, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();

    var list_workspace = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = "/workspace",
    });
    defer list_workspace.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, list_workspace.body, "demo") != null);

    const remove_target = try std.fmt.allocPrint(std.testing.allocator, "/workspace/{s}/remove", .{parsed.value.id});
    defer std.testing.allocator.free(remove_target);
    var remove_workspace = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = remove_target,
    });
    defer remove_workspace.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), remove_workspace.status);
}

test "permission and question endpoints list and reply pending interactions" {
    var fixture = try services_model.makeServerFixture(std.testing.allocator);
    defer fixture.deinit();
    var services = services_model.ServerServices.init(std.testing.allocator, &fixture.app_context);

    var pending_permission = try fixture.app_context.permissionRuntime().createPending(.{
        .session_id = "session_perm",
        .permission = "edit",
        .patterns = @constCast(&[_][]const u8{"src/main.zig"}),
    });
    defer pending_permission.deinit(std.testing.allocator);

    var permission_list = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = "/permission",
    });
    defer permission_list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), permission_list.status);
    try std.testing.expect(std.mem.indexOf(u8, permission_list.body, "session_perm") != null);

    const permission_reply_target = try std.fmt.allocPrint(std.testing.allocator, "/permission/{s}/reply", .{pending_permission.id});
    defer std.testing.allocator.free(permission_reply_target);
    var permission_reply = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = permission_reply_target,
        .body = "{\"reply\":\"once\"}",
    });
    defer permission_reply.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), permission_reply.status);

    const option_defs = [_]question.QuestionOption{
        .{ .label = "A", .description = "alpha" },
    };
    const question_defs = [_]question.QuestionInfo{
        .{
            .header = "Mode",
            .question = "Choose one",
            .options = @constCast(option_defs[0..]),
        },
    };
    var pending_question = try fixture.app_context.questionRuntime().createPending(.{
        .session_id = "session_question",
        .questions = @constCast(question_defs[0..]),
    });
    defer pending_question.deinit(std.testing.allocator);

    var question_list = try handleRequest(std.testing.allocator, &services, .{
        .method = .GET,
        .target = "/question",
    });
    defer question_list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), question_list.status);
    try std.testing.expect(std.mem.indexOf(u8, question_list.body, "session_question") != null);

    const question_reply_target = try std.fmt.allocPrint(std.testing.allocator, "/question/{s}/reply", .{pending_question.id});
    defer std.testing.allocator.free(question_reply_target);
    var question_reply = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = question_reply_target,
        .body = "{\"answers\":[{\"selections\":[\"A\"]}]}",
    });
    defer question_reply.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), question_reply.status);

    var pending_question_reject = try fixture.app_context.questionRuntime().createPending(.{
        .session_id = "session_question_reject",
        .questions = @constCast(question_defs[0..]),
    });
    defer pending_question_reject.deinit(std.testing.allocator);
    const question_reject_target = try std.fmt.allocPrint(std.testing.allocator, "/question/{s}/reject", .{pending_question_reject.id});
    defer std.testing.allocator.free(question_reject_target);
    var question_reject = try handleRequest(std.testing.allocator, &services, .{
        .method = .POST,
        .target = question_reject_target,
    });
    defer question_reject.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 200), question_reject.status);
}
