const std = @import("std");
const framework = @import("framework");
const config = @import("../config/root.zig");

pub const FormatterInfo = struct {
    name: []const u8,
    enabled: bool,
    extensions: [][]const u8,

    pub fn clone(self: FormatterInfo, allocator: std.mem.Allocator) !FormatterInfo {
        const extensions = try allocator.alloc([]const u8, self.extensions.len);
        errdefer allocator.free(extensions);
        for (self.extensions, 0..) |item, index| {
            extensions[index] = try allocator.dupe(u8, item);
        }
        return .{
            .name = try allocator.dupe(u8, self.name),
            .enabled = self.enabled,
            .extensions = extensions,
        };
    }

    pub fn deinit(self: *FormatterInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        for (self.extensions) |item| allocator.free(item);
        allocator.free(self.extensions);
    }
};

pub const FormatResult = struct {
    formatter_name: []const u8,
    formatted: bool,
    stdout: []const u8,
    stderr: []const u8,
    exit_code: i32,

    pub fn deinit(self: *FormatResult, allocator: std.mem.Allocator) void {
        allocator.free(self.formatter_name);
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const CommandExecutor = struct {
    ptr: *anyopaque,
    run_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, cwd: []const u8, argv: [][]const u8) anyerror!RunOutput,
};

pub const RunOutput = struct {
    stdout: []u8,
    stderr: []u8,
    exit_code: i32,

    pub fn deinit(self: *RunOutput, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const Dependencies = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    workspace_dir: []const u8,
    formatter: config.FormatterConfig,
    executor: ?CommandExecutor = null,
};

pub const FormatterRuntime = struct {
    allocator: std.mem.Allocator,
    logger: *framework.Logger,
    workspace_dir: []u8,
    definitions: []config.FormatterDefinitionConfig,
    executor: CommandExecutor,

    const Self = @This();

    pub fn init(deps: Dependencies) !*Self {
        const self = try deps.allocator.create(Self);
        errdefer deps.allocator.destroy(self);
        self.* = .{
            .allocator = deps.allocator,
            .logger = deps.logger,
            .workspace_dir = try deps.allocator.dupe(u8, deps.workspace_dir),
            .definitions = try cloneDefinitions(deps.allocator, deps.formatter.definitions),
            .executor = deps.executor orelse .{ .ptr = undefined, .run_fn = runProcess },
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.allocator.free(self.workspace_dir);
        for (self.definitions) |*item| item.deinit(self.allocator);
        self.allocator.free(self.definitions);
    }

    pub fn status(self: *Self, allocator: std.mem.Allocator) ![]FormatterInfo {
        const items = try allocator.alloc(FormatterInfo, self.definitions.len);
        errdefer allocator.free(items);
        for (self.definitions, 0..) |item, index| {
            items[index] = .{
                .name = try allocator.dupe(u8, item.name),
                .enabled = item.enabled,
                .extensions = try cloneStringSlice(allocator, item.extensions),
            };
            errdefer items[index].deinit(allocator);
        }
        return items;
    }

    pub fn formatFile(self: *Self, allocator: std.mem.Allocator, file_path: []const u8) !?FormatResult {
        const definition = self.matchForPath(file_path) orelse return null;
        if (!definition.enabled) return null;

        const cwd = if (std.fs.path.dirname(file_path)) |dir_name|
            try allocator.dupe(u8, dir_name)
        else
            try allocator.dupe(u8, self.workspace_dir);
        defer allocator.free(cwd);

        const argv = try buildArgv(allocator, definition.command, file_path);
        defer freeStringSlice(allocator, argv);

        var run_output = try self.executor.run_fn(self.executor.ptr, allocator, cwd, argv);
        defer run_output.deinit(allocator);

        const formatted = run_output.exit_code == 0;
        self.logger.child("formatter").info("formatter executed", &.{
            framework.LogField.string("formatter", definition.name),
            framework.LogField.string("path", file_path),
            framework.LogField.int("exit_code", @intCast(run_output.exit_code)),
            framework.LogField.boolean("ok", formatted),
        });

        return .{
            .formatter_name = try allocator.dupe(u8, definition.name),
            .formatted = formatted,
            .stdout = try allocator.dupe(u8, run_output.stdout),
            .stderr = try allocator.dupe(u8, run_output.stderr),
            .exit_code = run_output.exit_code,
        };
    }

    pub fn matchForPath(self: *Self, file_path: []const u8) ?config.FormatterDefinitionConfig {
        const ext = std.fs.path.extension(file_path);
        for (self.definitions) |definition| {
            if (!definition.enabled) continue;
            for (definition.extensions) |candidate| {
                if (std.mem.eql(u8, candidate, ext)) return definition;
            }
        }
        return null;
    }
};

fn cloneDefinitions(allocator: std.mem.Allocator, input: []const config.FormatterDefinitionConfig) ![]config.FormatterDefinitionConfig {
    const result = try allocator.alloc(config.FormatterDefinitionConfig, input.len);
    errdefer allocator.free(result);
    for (input, 0..) |item, index| {
        result[index] = .{
            .name = try allocator.dupe(u8, item.name),
            .enabled = item.enabled,
            .extensions = try cloneStringSlice(allocator, item.extensions),
            .command = try cloneStringSlice(allocator, item.command),
        };
        errdefer result[index].deinit(allocator);
    }
    return result;
}

fn cloneStringSlice(allocator: std.mem.Allocator, input: [][]const u8) ![][]const u8 {
    const result = try allocator.alloc([]const u8, input.len);
    errdefer allocator.free(result);
    for (input, 0..) |item, index| {
        result[index] = try allocator.dupe(u8, item);
    }
    return result;
}

fn freeStringSlice(allocator: std.mem.Allocator, items: [][]const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn buildArgv(allocator: std.mem.Allocator, command: [][]const u8, file_path: []const u8) ![][]const u8 {
    var saw_placeholder = false;
    var items: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    for (command) |item| {
        if (std.mem.eql(u8, item, "{path}")) {
            saw_placeholder = true;
            try items.append(allocator, try allocator.dupe(u8, file_path));
        } else {
            try items.append(allocator, try allocator.dupe(u8, item));
        }
    }
    if (!saw_placeholder) {
        try items.append(allocator, try allocator.dupe(u8, file_path));
    }
    return try items.toOwnedSlice(allocator);
}

fn runProcess(_: *anyopaque, allocator: std.mem.Allocator, cwd: []const u8, argv: [][]const u8) anyerror!RunOutput {
    const result = try std.process.run(allocator, std.Io.Threaded.global_single_threaded.*.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .stdout_limit = .limited(512 * 1024), .stderr_limit = .limited(512 * 1024)
    });
    const exit_code: i32 = switch (result.term) {
        .exited => |code| code,
        else => 1,
    };
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
        .exit_code = exit_code,
    };
}

test "formatter runtime tracks enabled and disabled formatter status" {
    var memory_sink = framework.MemorySink.init(std.testing.allocator, 16);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    const fmt_defs = [_]config.FormatterDefinitionConfig{
        .{ .name = "zigfmt", .enabled = true, .extensions = @constCast(&[_][]const u8{".zig"}), .command = @constCast(&[_][]const u8{"zig", "fmt", "{path}"}) },
        .{ .name = "prettier", .enabled = false, .extensions = @constCast(&[_][]const u8{".ts"}), .command = @constCast(&[_][]const u8{"prettier", "--write", "{path}"}) },
    };

    const runtime = try FormatterRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .workspace_dir = ".",
        .formatter = .{ .definitions = @constCast(fmt_defs[0..]) },
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    const statuses = try runtime.status(std.testing.allocator);
    defer {
        for (statuses) |*item| item.deinit(std.testing.allocator);
        std.testing.allocator.free(statuses);
    }
    try std.testing.expectEqual(@as(usize, 2), statuses.len);
    try std.testing.expect(statuses[0].enabled);
    try std.testing.expect(!statuses[1].enabled);
}

test "formatter runtime selects formatter by file extension and executes configured command" {
    const MockExecutor = struct {
        fn run(_: *anyopaque, allocator: std.mem.Allocator, cwd: []const u8, argv: [][]const u8) anyerror!RunOutput {
            _ = cwd;
            try std.testing.expectEqualStrings("mockfmt", argv[0]);
            try std.testing.expectEqualStrings("sample.zig", argv[1]);
            return .{
                .stdout = try allocator.dupe(u8, "formatted"),
                .stderr = try allocator.alloc(u8, 0),
                .exit_code = 0,
            };
        }
    };

    var memory_sink = framework.MemorySink.init(std.testing.allocator, 16);
    defer memory_sink.deinit();
    var logger = framework.Logger.init(memory_sink.asLogSink(), .trace);
    defer logger.deinit();

    const fmt_defs = [_]config.FormatterDefinitionConfig{
        .{ .name = "mockfmt", .enabled = true, .extensions = @constCast(&[_][]const u8{".zig"}), .command = @constCast(&[_][]const u8{"mockfmt"}) },
    };

    const runtime = try FormatterRuntime.init(.{
        .allocator = std.testing.allocator,
        .logger = &logger,
        .workspace_dir = ".",
        .formatter = .{ .definitions = @constCast(fmt_defs[0..]) },
        .executor = .{ .ptr = undefined, .run_fn = MockExecutor.run },
    });
    defer {
        runtime.deinit();
        std.testing.allocator.destroy(runtime);
    }

    var result = (try runtime.formatFile(std.testing.allocator, "sample.zig")).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(result.formatted);
    try std.testing.expectEqualStrings("mockfmt", result.formatter_name);
}
