const std = @import("std");
const framework = @import("framework");
const constants = @import("constants.zig");
const anchor = @import("anchor.zig");
const json = @import("../json.zig");
const result_model = @import("../result.zig");
const context_model = @import("../context.zig");

pub const EditOperation = enum {
    replace,
    append,
    prepend,
};

pub const EditRequest = struct {
    operation: EditOperation,
    anchor_text: []u8,
    content: []u8,

    pub fn deinit(self: *EditRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.anchor_text);
        allocator.free(self.content);
    }
};

pub fn backend() context_model.HashlineEditBackend {
    return .{
        .ptr = undefined,
        .edit = edit,
    };
}

pub fn edit(_: *anyopaque, ctx: *const context_model.ToolExecutionContext, params: []const framework.ValidationField) anyerror!result_model.ToolResult {
    return editResult(ctx.allocator, ctx.working_dir, params);
}

pub fn editResult(
    allocator: std.mem.Allocator,
    working_dir: []const u8,
    params: []const framework.ValidationField,
) !result_model.ToolResult {
    const raw_path = paramString(params, "path") orelse return error.MissingPath;
    const resolved = try context_model.resolvePath(allocator, working_dir, raw_path);
    defer allocator.free(resolved);

    const edits_field = findField(params, "edits") orelse return error.MissingEdits;
    if (edits_field.value != .array) return error.InvalidEditArray;

    const parsed_edits = try parseEdits(allocator, edits_field.value.array);
    defer {
        for (parsed_edits) |*item| item.deinit(allocator);
        allocator.free(parsed_edits);
    }

    const outcome_json = try applyToPath(allocator, resolved, parsed_edits);
    defer allocator.free(outcome_json);

    return .{
        .title = try allocator.dupe(u8, "edit_file"),
        .output_text = if (std.mem.indexOf(u8, outcome_json, constants.mismatch_code) != null)
            try allocator.dupe(u8, "Hash mismatch detected. Re-read the file and retry with refreshed anchors.")
        else
            try allocator.dupe(u8, "Anchored edit applied"),
        .metadata_json = try allocator.dupe(u8, outcome_json),
    };
}

fn applyToPath(allocator: std.mem.Allocator, path: []const u8, edits: []const EditRequest) ![]u8 {
    const original = try std.Io.Dir.cwd().readFileAlloc(std.Io.Threaded.global_single_threaded.*.io(), path, allocator, .limited(1024 * 1024));
    defer allocator.free(original);

    var line_list = try splitLines(allocator, original);
    defer freeOwnedLines(allocator, &line_list);

    if (try findMismatchReport(allocator, line_list.items, edits)) |report| {
        var mutable_report = report;
        defer mutable_report.deinit();
        return validationFailureJson(allocator, mutable_report);
    }

    var owned_edits = try allocator.alloc(EditRequest, edits.len);
    defer allocator.free(owned_edits);
    for (edits, 0..) |edit_item, index| {
        owned_edits[index] = .{
            .operation = edit_item.operation,
            .anchor_text = edit_item.anchor_text,
            .content = edit_item.content,
        };
    }
    std.sort.block(EditRequest, owned_edits, {}, lessThanEdit);

    for (owned_edits) |edit_item| {
        try applyEdit(allocator, &line_list, edit_item);
    }

    const rendered = try joinLines(allocator, line_list.items, original.len > 0 and original[original.len - 1] == '\n');
    defer allocator.free(rendered);
    var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), path, .{ .truncate = true });
    defer file.close(std.Io.Threaded.global_single_threaded.*.io());
    try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), rendered);

    return json.stringifyAlloc(allocator, .{
        .ok = true,
        .path = path,
        .editCount = edits.len,
    });
}

fn findMismatchReport(allocator: std.mem.Allocator, lines: []const []const u8, edits: []const EditRequest) !?framework.ValidationReport {
    for (edits) |edit_item| {
        const normalized = try anchor.normalizeAnchorText(allocator, edit_item.anchor_text);
        defer allocator.free(normalized);
        anchor.validateAnchor(allocator, lines, normalized) catch |err| switch (err) {
            error.HashMismatch => return try anchor.mismatchReport(allocator, lines, edit_item.anchor_text),
            error.HashlineOutOfBounds, error.InvalidHashlineAnchor => {
                var report = framework.ValidationReport.init(allocator);
                try report.addIssue(
                    framework.core.validation.ValidationIssue
                        .init("edits.anchor", "HASHLINE_ANCHOR_INVALID", "Hashline anchor is invalid or out of bounds", .@"error")
                        .withHint("re-read the file and retry with a fresh anchor"),
                );
                return report;
            },
            else => return err,
        };
    }
    return null;
}

fn applyEdit(allocator: std.mem.Allocator, lines: *std.ArrayListUnmanaged([]u8), edit_item: EditRequest) !void {
    const parsed_anchor = try anchor.parseAnchor(edit_item.anchor_text);
    const index = parsed_anchor.line_no - 1;
    const fragments = try splitContentFragments(allocator, edit_item.content);
    errdefer {
        for (fragments) |line| allocator.free(line);
        allocator.free(fragments);
    }
    defer allocator.free(fragments);

    switch (edit_item.operation) {
        .replace => {
            allocator.free(lines.items[index]);
            _ = lines.orderedRemove(index);
            try lines.insertSlice(allocator, index, fragments);
        },
        .append => {
            try lines.insertSlice(allocator, index + 1, fragments);
        },
        .prepend => {
            try lines.insertSlice(allocator, index, fragments);
        },
    }
}

fn splitContentFragments(allocator: std.mem.Allocator, content: []const u8) ![][]u8 {
    var fragments = std.mem.splitScalar(u8, content, '\n');
    var items: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (items.items) |line| allocator.free(line);
        items.deinit(allocator);
    }
    while (fragments.next()) |fragment| {
        try items.append(allocator, try allocator.dupe(u8, fragment));
    }
    return items.toOwnedSlice(allocator);
}

fn splitLines(allocator: std.mem.Allocator, contents: []const u8) !std.ArrayListUnmanaged([]u8) {
    const normalized = if (contents.len > 0 and contents[contents.len - 1] == '\n')
        contents[0 .. contents.len - 1]
    else
        contents;

    var parts: std.ArrayListUnmanaged([]u8) = .empty;
    errdefer {
        for (parts.items) |line| allocator.free(line);
        parts.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, normalized, '\n');
    while (lines.next()) |line| {
        try parts.append(allocator, try allocator.dupe(u8, std.mem.trimEnd(u8, line, "\r")));
    }
    return parts;
}

fn freeOwnedLines(allocator: std.mem.Allocator, lines: *std.ArrayListUnmanaged([]u8)) void {
    for (lines.items) |line| allocator.free(line);
    lines.deinit(allocator);
}

fn joinLines(allocator: std.mem.Allocator, lines: []const []const u8, trailing_newline: bool) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    for (lines, 0..) |line, index| {
        if (index > 0) try out.append(allocator, '\n');
        try out.appendSlice(allocator, line);
    }
    if (trailing_newline) try out.append(allocator, '\n');
    return allocator.dupe(u8, out.items);
}

fn parseEdits(allocator: std.mem.Allocator, values: []const framework.ValidationValue) ![]EditRequest {
    var edits: std.ArrayListUnmanaged(EditRequest) = .empty;
    errdefer {
        for (edits.items) |*item| item.deinit(allocator);
        edits.deinit(allocator);
    }

    for (values) |value| {
        if (value != .object) return error.InvalidEditItem;
        const op_text = objectString(value.object, "op") orelse return error.MissingEditOperation;
        const raw_anchor = objectString(value.object, "anchor") orelse objectString(value.object, "ref") orelse return error.MissingEditAnchor;
        const content = objectString(value.object, "content") orelse return error.MissingEditContent;
        const anchor_text = try anchor.normalizeAnchorText(allocator, raw_anchor);

        try edits.append(allocator, .{
            .operation = parseOperation(op_text),
            .anchor_text = anchor_text,
            .content = try allocator.dupe(u8, content),
        });
    }

    return edits.toOwnedSlice(allocator);
}

fn parseOperation(raw: []const u8) EditOperation {
    if (std.mem.eql(u8, raw, "append")) return .append;
    if (std.mem.eql(u8, raw, "prepend")) return .prepend;
    return .replace;
}

fn objectString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn findField(fields: []const framework.ValidationField, key: []const u8) ?framework.ValidationField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key)) return field;
    }
    return null;
}

fn paramString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    const field = findField(fields, key) orelse return null;
    if (field.value != .string) return null;
    return field.value.string;
}

fn lessThanEdit(_: void, lhs: EditRequest, rhs: EditRequest) bool {
    const left_anchor = anchor.parseAnchor(lhs.anchor_text) catch return false;
    const right_anchor = anchor.parseAnchor(rhs.anchor_text) catch return false;
    return left_anchor.line_no > right_anchor.line_no;
}

fn validationFailureJson(allocator: std.mem.Allocator, report: framework.ValidationReport) ![]u8 {
    _ = report;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    try out.appendSlice(allocator, "{\"ok\":false,\"validation_report\":");
    try out.appendSlice(allocator, "{}");
    try out.append(allocator, '}');
    return allocator.dupe(u8, out.items);
}

test "hashline backend applies anchored replace successfully" {
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const root_path = try tmp_dir.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(root_path);
    const file_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "sample.txt" });
    defer std.testing.allocator.free(file_path);
    {
        var file = try std.Io.Dir.cwd().createFile(std.Io.Threaded.global_single_threaded.*.io(), file_path, .{});
        defer file.close(std.Io.Threaded.global_single_threaded.*.io());
        try file.writeStreamingAll(std.Io.Threaded.global_single_threaded.*.io(), "alpha\nbeta\n");
    }

    const anchor_text = try anchor.formatAnchor(std.testing.allocator, 2, "beta");
    defer std.testing.allocator.free(anchor_text);
    var edit_request = EditRequest{
        .operation = .replace,
        .anchor_text = try std.testing.allocator.dupe(u8, anchor_text),
        .content = try std.testing.allocator.dupe(u8, "gamma"),
    };
    defer edit_request.deinit(std.testing.allocator);

    const response_json = try applyToPath(std.testing.allocator, file_path, (&[_]EditRequest{edit_request})[0..]);
    defer std.testing.allocator.free(response_json);

    const contents = try std.Io.Dir.cwd().readFileAlloc(std.testing.allocator, file_path, 1024);
    defer std.testing.allocator.free(contents);
    try std.testing.expect(std.mem.indexOf(u8, contents, "gamma") != null);
}
