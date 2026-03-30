const std = @import("std");

pub const MODULE_NAME = "question";

pub const types = @import("types.zig");
pub const runtime = @import("runtime.zig");

pub const QuestionOption = types.QuestionOption;
pub const QuestionInfo = types.QuestionInfo;
pub const QuestionAnswer = types.QuestionAnswer;
pub const QuestionRequest = types.QuestionRequest;
pub const QuestionAskInput = types.QuestionAskInput;
pub const QuestionRuntime = runtime.QuestionRuntime;
pub const QuestionRuntimeDependencies = runtime.Dependencies;
pub const QUESTION_ASKED_EVENT_TOPIC = runtime.QUESTION_ASKED_EVENT_TOPIC;
pub const QUESTION_REPLIED_EVENT_TOPIC = runtime.QUESTION_REPLIED_EVENT_TOPIC;
pub const QUESTION_REJECTED_EVENT_TOPIC = runtime.QUESTION_REJECTED_EVENT_TOPIC;
pub const cloneStringSlice = types.cloneStringSlice;
pub const freeStringSlice = types.freeStringSlice;
pub const freeAnswers = types.freeAnswers;

test "question module exports are available" {
    try std.testing.expectEqualStrings("question", MODULE_NAME);
}
