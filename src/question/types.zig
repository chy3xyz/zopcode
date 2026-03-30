const std = @import("std");

pub const QuestionOption = struct {
    label: []const u8,
    description: []const u8,

    pub fn clone(self: QuestionOption, allocator: std.mem.Allocator) !QuestionOption {
        return .{
            .label = try allocator.dupe(u8, self.label),
            .description = try allocator.dupe(u8, self.description),
        };
    }

    pub fn deinit(self: *QuestionOption, allocator: std.mem.Allocator) void {
        allocator.free(self.label);
        allocator.free(self.description);
    }
};

pub const QuestionInfo = struct {
    header: []const u8,
    question: []const u8,
    options: []QuestionOption,
    multiple: bool = false,

    pub fn clone(self: QuestionInfo, allocator: std.mem.Allocator) !QuestionInfo {
        const options = try allocator.alloc(QuestionOption, self.options.len);
        errdefer allocator.free(options);
        for (self.options, 0..) |item, index| {
            options[index] = try item.clone(allocator);
        }
        return .{
            .header = try allocator.dupe(u8, self.header),
            .question = try allocator.dupe(u8, self.question),
            .options = options,
            .multiple = self.multiple,
        };
    }

    pub fn deinit(self: *QuestionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.header);
        allocator.free(self.question);
        for (self.options) |*item| item.deinit(allocator);
        allocator.free(self.options);
    }
};

pub const QuestionAnswer = struct {
    selections: [][]const u8,

    pub fn clone(self: QuestionAnswer, allocator: std.mem.Allocator) !QuestionAnswer {
        return .{
            .selections = try cloneStringSlice(allocator, self.selections),
        };
    }

    pub fn deinit(self: *QuestionAnswer, allocator: std.mem.Allocator) void {
        freeStringSlice(allocator, self.selections);
    }
};

pub const QuestionRequest = struct {
    id: []const u8,
    session_id: []const u8,
    message_id: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    questions: []QuestionInfo,

    pub fn clone(self: QuestionRequest, allocator: std.mem.Allocator) !QuestionRequest {
        const questions = try allocator.alloc(QuestionInfo, self.questions.len);
        errdefer allocator.free(questions);
        for (self.questions, 0..) |item, index| {
            questions[index] = try item.clone(allocator);
        }
        return .{
            .id = try allocator.dupe(u8, self.id),
            .session_id = try allocator.dupe(u8, self.session_id),
            .message_id = if (self.message_id) |value| try allocator.dupe(u8, value) else null,
            .call_id = if (self.call_id) |value| try allocator.dupe(u8, value) else null,
            .questions = questions,
        };
    }

    pub fn deinit(self: *QuestionRequest, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.session_id);
        if (self.message_id) |value| allocator.free(value);
        if (self.call_id) |value| allocator.free(value);
        for (self.questions) |*item| item.deinit(allocator);
        allocator.free(self.questions);
    }
};

pub const QuestionAskInput = struct {
    session_id: []const u8,
    message_id: ?[]const u8 = null,
    call_id: ?[]const u8 = null,
    questions: []QuestionInfo,
};

pub fn cloneStringSlice(allocator: std.mem.Allocator, items: [][]const u8) ![][]const u8 {
    const cloned = try allocator.alloc([]const u8, items.len);
    errdefer allocator.free(cloned);
    for (items, 0..) |item, index| {
        cloned[index] = try allocator.dupe(u8, item);
    }
    return cloned;
}

pub fn freeStringSlice(allocator: std.mem.Allocator, items: [][]const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

pub fn freeAnswers(allocator: std.mem.Allocator, answers: []QuestionAnswer) void {
    for (answers) |*answer| answer.deinit(allocator);
    allocator.free(answers);
}

test "question answer owns nested selections" {
    var answer = QuestionAnswer{
        .selections = try cloneStringSlice(std.testing.allocator, @constCast(&[_][]const u8{"yes"})),
    };
    defer answer.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), answer.selections.len);
}
