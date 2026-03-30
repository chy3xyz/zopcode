const std = @import("std");
const framework = @import("framework");
const context_model = @import("../context.zig");
const json = @import("../json.zig");
const question = @import("../../question/root.zig");
const result_model = @import("../result.zig");
const tool_model = @import("../tool.zig");

const option_fields = [_]framework.FieldDefinition{
    .{ .key = "label", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string } },
    .{ .key = "description", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string } },
};

const question_fields = [_]framework.FieldDefinition{
    .{ .key = "header", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string } },
    .{ .key = "question", .required = true, .value_kind = .string, .rules = &.{ .non_empty_string } },
    .{
        .key = "options",
        .required = true,
        .value_kind = .array,
        .rules = &.{.{ .array_length = .{ .min = 1 } }},
        .element_kind = .object,
        .element_fields = option_fields[0..],
    },
    .{ .key = "multiple", .required = false, .value_kind = .boolean },
};

const params = [_]framework.FieldDefinition{
    .{
        .key = "questions",
        .required = true,
        .value_kind = .array,
        .rules = &.{.{ .array_length = .{ .min = 1 } }},
        .element_kind = .object,
        .element_fields = question_fields[0..],
    },
};

pub fn definition() tool_model.ToolDefinition {
    return .{
        .id = "question",
        .description = "Ask one or more structured questions and wait for user answers",
        .input_schema_json = "{\"type\":\"object\",\"required\":[\"questions\"],\"properties\":{\"questions\":{\"type\":\"array\"}}}",
        .params = params[0..],
        .execution_mode = .async_task,
        .async_execute_fn = execute,
    };
}

fn execute(ctx: *const context_model.ToolExecutionContext, fields: []const framework.ValidationField) !result_model.ToolResult {
    const runtime = ctx.question_runtime orelse return error.QuestionRuntimeUnavailable;
    const session_id = ctx.session_id orelse return error.QuestionSessionRequired;
    const questions_field = findField(fields, "questions") orelse return error.QuestionListMissing;
    if (questions_field.value != .array) return error.QuestionListInvalid;
    const questions = try parseQuestions(ctx.allocator, questions_field.value.array);
    defer {
        for (questions) |*item| item.deinit(ctx.allocator);
        ctx.allocator.free(questions);
    }

    const answers = try runtime.ask(.{
        .session_id = session_id,
        .message_id = ctx.message_id,
        .call_id = ctx.call_id,
        .questions = questions,
    });
    defer question.freeAnswers(ctx.allocator, answers);

    const output_text = try renderAnswers(ctx.allocator, questions, answers);
    ctx.logger.child("tools").child("question").info("tool executed", &.{
        framework.LogField.string("session_id", session_id),
        framework.LogField.int("question_count", @intCast(questions.len)),
        framework.LogField.boolean("ok", true),
    });

    return .{
        .title = try std.fmt.allocPrint(ctx.allocator, "Asked {d} question{s}", .{ questions.len, if (questions.len == 1) "" else "s" }),
        .output_text = output_text,
        .metadata_json = try json.stringifyAlloc(ctx.allocator, .{
            .answers = answers,
        }),
    };
}

fn parseQuestions(allocator: std.mem.Allocator, items: []const framework.ValidationValue) ![]question.QuestionInfo {
    const parsed = try allocator.alloc(question.QuestionInfo, items.len);
    errdefer allocator.free(parsed);
    for (items, 0..) |item, index| {
        if (item != .object) return error.InvalidQuestionItem;
        parsed[index] = try parseQuestionObject(allocator, item.object);
        errdefer parsed[index].deinit(allocator);
    }
    return parsed;
}

fn parseQuestionObject(allocator: std.mem.Allocator, fields: []const framework.ValidationField) !question.QuestionInfo {
    const options_field = findField(fields, "options") orelse return error.MissingQuestionOptions;
    if (options_field.value != .array) return error.InvalidQuestionOptions;

    return .{
        .header = try allocator.dupe(u8, fieldString(fields, "header") orelse return error.MissingQuestionHeader),
        .question = try allocator.dupe(u8, fieldString(fields, "question") orelse return error.MissingQuestionText),
        .options = try parseOptions(allocator, options_field.value.array),
        .multiple = fieldBool(fields, "multiple") orelse false,
    };
}

fn parseOptions(allocator: std.mem.Allocator, items: []const framework.ValidationValue) ![]question.QuestionOption {
    const parsed = try allocator.alloc(question.QuestionOption, items.len);
    errdefer allocator.free(parsed);
    for (items, 0..) |item, index| {
        if (item != .object) return error.InvalidQuestionOption;
        parsed[index] = .{
            .label = try allocator.dupe(u8, fieldString(item.object, "label") orelse return error.MissingQuestionOptionLabel),
            .description = try allocator.dupe(u8, fieldString(item.object, "description") orelse return error.MissingQuestionOptionDescription),
        };
        errdefer parsed[index].deinit(allocator);
    }
    return parsed;
}

fn renderAnswers(
    allocator: std.mem.Allocator,
    questions: []const question.QuestionInfo,
    answers: []const question.QuestionAnswer,
) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(allocator);
    const writer = out.writer(allocator);
    try writer.writeAll("User answered your questions: ");
    for (questions, 0..) |item, index| {
        if (index > 0) try writer.writeAll(", ");
        try writer.writeByte('"');
        try writer.writeAll(item.question);
        try writer.writeAll("\"=\"");
        if (index < answers.len and answers[index].selections.len > 0) {
            for (answers[index].selections, 0..) |selection, sel_index| {
                if (sel_index > 0) try writer.writeAll(", ");
                try writer.writeAll(selection);
            }
        } else {
            try writer.writeAll("Unanswered");
        }
        try writer.writeByte('"');
    }
    try writer.writeAll(". You can now continue with the user's answers in mind.");
    return allocator.dupe(u8, out.items);
}

fn findField(fields: []const framework.ValidationField, key: []const u8) ?framework.ValidationField {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key)) return field;
    }
    return null;
}

fn fieldString(fields: []const framework.ValidationField, key: []const u8) ?[]const u8 {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .string) return field.value.string;
    }
    return null;
}

fn fieldBool(fields: []const framework.ValidationField, key: []const u8) ?bool {
    for (fields) |field| {
        if (std.mem.eql(u8, field.key, key) and field.value == .boolean) return field.value.boolean;
    }
    return null;
}
