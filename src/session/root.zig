const std = @import("std");

pub const MODULE_NAME = "session";

pub const schema = @import("schema.zig");
pub const session = @import("session.zig");
pub const message = @import("message.zig");
pub const part = @import("part.zig");
pub const store = @import("store.zig");
pub const history = @import("history.zig");
pub const compaction = @import("compaction.zig");
pub const snapshot = @import("snapshot.zig");
pub const events = @import("events.zig");
pub const prompt_input = @import("prompt_input.zig");
pub const status = @import("status.zig");
pub const runtime = @import("runtime.zig");

pub const SessionId = schema.SessionId;
pub const MessageId = schema.MessageId;
pub const PartId = schema.PartId;
pub const nextSessionId = schema.nextSessionId;
pub const nextMessageId = schema.nextMessageId;
pub const nextPartId = schema.nextPartId;

pub const SessionCreateRequest = session.SessionCreateRequest;
pub const SessionForkRequest = session.SessionForkRequest;
pub const SessionInfo = session.SessionInfo;
pub const initSessionFromCreateRequest = session.initFromCreateRequest;

pub const MessageRole = message.MessageRole;
pub const MessageAppendRequest = message.MessageAppendRequest;
pub const MessageInfo = message.MessageInfo;
pub const initMessageFromAppendRequest = message.initFromAppendRequest;

pub const MessagePart = part.MessagePart;
pub const TextPart = part.TextPart;
pub const ReasoningPart = part.ReasoningPart;
pub const ToolCallPart = part.ToolCallPart;
pub const ToolResultPart = part.ToolResultPart;
pub const SystemReminderPart = part.SystemReminderPart;
pub const SubtaskPart = part.SubtaskPart;
pub const SubtaskAggregatePart = part.SubtaskAggregatePart;
pub const CompactionSummaryPart = part.CompactionSummaryPart;
pub const textPart = part.text;
pub const reasoningPart = part.reasoning;
pub const toolCallPart = part.toolCall;
pub const toolResultPart = part.toolResult;
pub const compactionSummaryPart = part.compactionSummary;
pub const subtaskPart = part.subtask;
pub const subtaskAggregatePart = part.subtaskAggregate;

pub const SessionStore = store.SessionStore;
pub const FileSessionStore = store.FileSessionStore;
pub const PartAppendRequest = store.PartAppendRequest;
pub const PartRecord = store.PartRecord;
pub const TimelineRecords = store.TimelineRecords;

pub const MessageWithParts = history.MessageWithParts;
pub const ConversationPart = history.ConversationPart;
pub const ConversationMessage = history.ConversationMessage;
pub const HistoryService = history.HistoryService;
pub const PreparedPromptInput = prompt_input.PreparedPromptInput;
pub const preparePromptForProfile = prompt_input.prepareForProfile;
pub const SessionStatus = status.SessionStatus;
pub const SessionStatusInfo = status.SessionStatusInfo;
pub const SessionStatusUpdate = status.SessionStatusUpdate;
pub const SessionStatusIndex = status.SessionStatusIndex;
pub const SessionRuntime = runtime.SessionRuntime;
pub const SessionRuntimeDependencies = runtime.Dependencies;
pub const PromptRequest = runtime.PromptRequest;
pub const PromptPartInput = runtime.PromptPartInput;
pub const RunAgentRequest = runtime.RunAgentRequest;
pub const AgentTask = runtime.AgentTask;
pub const ToolTask = runtime.ToolTask;
pub const registerRunAgentCommand = runtime.registerRunAgentCommand;

pub const CompactionCheckRequest = compaction.CompactionCheckRequest;
pub const CompactionCheck = compaction.CompactionCheck;
pub const CompactionResult = compaction.CompactionResult;
pub const CompactionPolicy = compaction.CompactionPolicy;
pub const DisabledCompactionPolicy = compaction.DisabledCompactionPolicy;
pub const MessageCountCompactionPolicy = compaction.MessageCountCompactionPolicy;
pub const compactSession = compaction.compactSession;

pub const SnapshotId = schema.SnapshotId;
pub const nextSnapshotId = schema.nextSnapshotId;
pub const SnapshotRecord = snapshot.SnapshotRecord;
pub const RevertResult = snapshot.RevertResult;
pub const FileSnapshotStore = snapshot.FileSnapshotStore;
pub const SnapshotService = snapshot.SnapshotService;

pub const ToolCallEvent = events.ToolCallEvent;
pub const SessionCreatedEvent = events.SessionCreatedEvent;
pub const SessionUpdatedEvent = events.SessionUpdatedEvent;
pub const SessionMessageCreatedEvent = events.SessionMessageCreatedEvent;
pub const SessionPartAppendedEvent = events.SessionPartAppendedEvent;
pub const SessionTimelineEvent = events.SessionTimelineEvent;
pub const SessionStatusEvent = events.SessionStatusEvent;
pub const ToolResultEvent = events.ToolResultEvent;
pub const ProviderResponseEvent = events.ProviderResponseEvent;
pub const TOOL_CALL_EVENT_TOPIC = events.TOOL_CALL_EVENT_TOPIC;
pub const TOOL_RESULT_COMPLETED_EVENT_TOPIC = events.TOOL_RESULT_COMPLETED_EVENT_TOPIC;
pub const TOOL_RESULT_FAILED_EVENT_TOPIC = events.TOOL_RESULT_FAILED_EVENT_TOPIC;
pub const PROVIDER_RESPONSE_DELTA_TOPIC = events.PROVIDER_RESPONSE_DELTA_TOPIC;
pub const PROVIDER_RESPONSE_COMPLETED_TOPIC = events.PROVIDER_RESPONSE_COMPLETED_TOPIC;
pub const PROVIDER_RESPONSE_FAILED_TOPIC = events.PROVIDER_RESPONSE_FAILED_TOPIC;
pub const SESSION_CREATED_EVENT_TOPIC = events.SESSION_CREATED_EVENT_TOPIC;
pub const SESSION_UPDATED_EVENT_TOPIC = events.SESSION_UPDATED_EVENT_TOPIC;
pub const SESSION_MESSAGE_CREATED_EVENT_TOPIC = events.SESSION_MESSAGE_CREATED_EVENT_TOPIC;
pub const SESSION_PART_APPENDED_EVENT_TOPIC = events.SESSION_PART_APPENDED_EVENT_TOPIC;
pub const SESSION_STATUS_EVENT_TOPIC = events.SESSION_STATUS_EVENT_TOPIC;

pub const publishToolCallEvent = events.publishToolCallEvent;
pub const publishSessionCreatedEvent = events.publishSessionCreatedEvent;
pub const publishSessionUpdatedEvent = events.publishSessionUpdatedEvent;
pub const publishSessionMessageCreatedEvent = events.publishSessionMessageCreatedEvent;
pub const publishSessionPartAppendedEvent = events.publishSessionPartAppendedEvent;
pub const publishSessionStatusEvent = events.publishSessionStatusEvent;
pub const publishToolResultEvent = events.publishToolResultEvent;
pub const publishProviderResponseEvent = events.publishProviderResponseEvent;
pub const subscribeToolCallEvents = events.subscribeToolCallEvents;
pub const subscribeToolResultEvents = events.subscribeToolResultEvents;
pub const subscribeSessionTimelineEvents = events.subscribeSessionTimelineEvents;
pub const subscribeSessionStatusEvents = events.subscribeSessionStatusEvents;
pub const pollToolCallEvents = events.pollToolCallEvents;
pub const pollToolResultEvents = events.pollToolResultEvents;
pub const pollSessionTimelineEvents = events.pollSessionTimelineEvents;
pub const pollSessionStatusEvents = events.pollSessionStatusEvents;

pub const ModuleStage = enum {
    timeline,
    prompt_preparation,
    runtime_loop,
};

pub const MODULE_STAGE: ModuleStage = .runtime_loop;

test "session module exports timeline types" {
    try std.testing.expectEqualStrings("session", MODULE_NAME);
    try std.testing.expectEqualStrings("user", MessageRole.user.asText());
}
