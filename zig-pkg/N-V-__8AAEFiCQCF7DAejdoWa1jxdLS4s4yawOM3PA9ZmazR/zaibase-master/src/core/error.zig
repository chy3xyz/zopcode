const std = @import("std");
const validation_report = @import("validation/report.zig");

pub const Domain = enum {
    core,
    validation,
    config,
    runtime,
    service,
    provider,
    channel,
    tool,
    security,
    logging,
};

pub const code = struct {
    pub const CORE_INVALID_REQUEST = "CORE_INVALID_REQUEST";
    pub const CORE_METHOD_NOT_FOUND = "CORE_METHOD_NOT_FOUND";
    pub const CORE_METHOD_NOT_ALLOWED = "CORE_METHOD_NOT_ALLOWED";
    pub const CORE_TIMEOUT = "CORE_TIMEOUT";
    pub const CORE_INTERNAL_ERROR = "CORE_INTERNAL_ERROR";

    pub const VALIDATION_FAILED = "VALIDATION_FAILED";
    pub const VALIDATION_UNKNOWN_FIELD = "VALIDATION_UNKNOWN_FIELD";
    pub const VALIDATION_TYPE_MISMATCH = "VALIDATION_TYPE_MISMATCH";
    pub const VALIDATION_VALUE_OUT_OF_RANGE = "VALIDATION_VALUE_OUT_OF_RANGE";
    pub const VALIDATION_RISK_CONFIRMATION_REQUIRED = "VALIDATION_RISK_CONFIRMATION_REQUIRED";

    pub const CONFIG_LOAD_FAILED = "CONFIG_LOAD_FAILED";
    pub const CONFIG_PARSE_FAILED = "CONFIG_PARSE_FAILED";
    pub const CONFIG_FIELD_UNKNOWN = "CONFIG_FIELD_UNKNOWN";
    pub const CONFIG_WRITE_FAILED = "CONFIG_WRITE_FAILED";
    pub const CONFIG_MIGRATION_FAILED = "CONFIG_MIGRATION_FAILED";

    pub const RUNTIME_TASK_NOT_FOUND = "RUNTIME_TASK_NOT_FOUND";
    pub const RUNTIME_TASK_CANCELLED = "RUNTIME_TASK_CANCELLED";
    pub const RUNTIME_TASK_FAILED = "RUNTIME_TASK_FAILED";
    pub const RUNTIME_SHUTTING_DOWN = "RUNTIME_SHUTTING_DOWN";

    pub const SERVICE_OPERATION_FAILED = "SERVICE_OPERATION_FAILED";
    pub const PROVIDER_OPERATION_FAILED = "PROVIDER_OPERATION_FAILED";
    pub const CHANNEL_OPERATION_FAILED = "CHANNEL_OPERATION_FAILED";
    pub const TOOL_OPERATION_FAILED = "TOOL_OPERATION_FAILED";

    pub const SECURITY_PATH_NOT_ALLOWED = "SECURITY_PATH_NOT_ALLOWED";
    pub const SECURITY_COMMAND_NOT_ALLOWED = "SECURITY_COMMAND_NOT_ALLOWED";
    pub const SECURITY_SECRET_REF_INVALID = "SECURITY_SECRET_REF_INVALID";
    pub const SECURITY_POLICY_DENIED = "SECURITY_POLICY_DENIED";

    pub const LOGGING_WRITE_FAILED = "LOGGING_WRITE_FAILED";
};

pub const AppError = struct {
    code: []const u8,
    message: []const u8,
    user_message: ?[]const u8 = null,
    retryable: bool = false,
    target: ?[]const u8 = null,
    details_json: ?[]const u8 = null,

    const Self = @This();

    pub fn init(error_code: []const u8, message: []const u8) Self {
        return .{
            .code = error_code,
            .message = message,
        };
    }

    pub fn withUserMessage(self: Self, user_message: []const u8) Self {
        var next = self;
        next.user_message = user_message;
        return next;
    }

    pub fn withRetryable(self: Self, retryable: bool) Self {
        var next = self;
        next.retryable = retryable;
        return next;
    }

    pub fn withTarget(self: Self, target: []const u8) Self {
        var next = self;
        next.target = target;
        return next;
    }

    pub fn withDetailsJson(self: Self, details_json: []const u8) Self {
        var next = self;
        next.details_json = details_json;
        return next;
    }
};

pub const MappingContext = struct {
    message: ?[]const u8 = null,
    user_message: ?[]const u8 = null,
    target: ?[]const u8 = null,
    details_json: ?[]const u8 = null,
    retryable: ?bool = null,
};

pub const InternalErrorKind = enum {
    invalid_request,
    method_not_found,
    method_not_allowed,
    timeout,
    validation_failed,
    validation_unknown_field,
    validation_type_mismatch,
    validation_value_out_of_range,
    validation_risk_confirmation_required,
    config_load_failed,
    config_parse_failed,
    config_field_unknown,
    config_write_failed,
    config_migration_failed,
    runtime_task_not_found,
    runtime_task_cancelled,
    runtime_task_failed,
    runtime_shutting_down,
    service_operation_failed,
    provider_operation_failed,
    channel_operation_failed,
    tool_operation_failed,
    security_path_not_allowed,
    security_command_not_allowed,
    security_secret_ref_invalid,
    security_policy_denied,
    logging_write_failed,
    internal,
};

const KnownErrorName = enum {
    InvalidRequest,
    InvalidParams,
    MethodNotFound,
    MethodNotAllowed,
    Timeout,
    RequestTimeout,
    ConnectionTimedOut,
    ValidationError,
    ValidationFailed,
    ValidationUnknownField,
    UnknownField,
    ValidationTypeMismatch,
    TypeMismatch,
    ValidationValueOutOfRange,
    ValueOutOfRange,
    ValidationRiskConfirmationRequired,
    RiskConfirmationRequired,
    ConfigLoadFailed,
    ConfigParseFailed,
    ConfigFieldUnknown,
    ConfigWriteFailed,
    ConfigMigrationFailed,
    TaskNotFound,
    TaskCancelled,
    TaskFailed,
    ShuttingDown,
    ServiceOperationFailed,
    ProviderOperationFailed,
    ChannelOperationFailed,
    ToolOperationFailed,
    PathNotAllowed,
    CommandNotAllowed,
    SecretRefInvalid,
    PolicyDenied,
    SecurityDenied,
    LoggingWriteFailed,
    InternalError,
};

const ErrorDescriptor = struct {
    code: []const u8,
    message: []const u8,
    user_message: ?[]const u8,
    retryable: bool,
};

pub const ValidationReport = validation_report.ValidationReport;

pub fn hasKnownCodePrefix(error_code: []const u8) bool {
    return domainForCode(error_code) != null;
}

pub fn kindForErrorName(error_name: []const u8) ?InternalErrorKind {
    const known = std.meta.stringToEnum(KnownErrorName, error_name) orelse return null;

    return switch (known) {
        .InvalidRequest, .InvalidParams => .invalid_request,
        .MethodNotFound => .method_not_found,
        .MethodNotAllowed => .method_not_allowed,
        .Timeout, .RequestTimeout, .ConnectionTimedOut => .timeout,
        .ValidationError, .ValidationFailed => .validation_failed,
        .ValidationUnknownField, .UnknownField => .validation_unknown_field,
        .ValidationTypeMismatch, .TypeMismatch => .validation_type_mismatch,
        .ValidationValueOutOfRange, .ValueOutOfRange => .validation_value_out_of_range,
        .ValidationRiskConfirmationRequired, .RiskConfirmationRequired => .validation_risk_confirmation_required,
        .ConfigLoadFailed => .config_load_failed,
        .ConfigParseFailed => .config_parse_failed,
        .ConfigFieldUnknown => .config_field_unknown,
        .ConfigWriteFailed => .config_write_failed,
        .ConfigMigrationFailed => .config_migration_failed,
        .TaskNotFound => .runtime_task_not_found,
        .TaskCancelled => .runtime_task_cancelled,
        .TaskFailed => .runtime_task_failed,
        .ShuttingDown => .runtime_shutting_down,
        .ServiceOperationFailed => .service_operation_failed,
        .ProviderOperationFailed => .provider_operation_failed,
        .ChannelOperationFailed => .channel_operation_failed,
        .ToolOperationFailed => .tool_operation_failed,
        .PathNotAllowed => .security_path_not_allowed,
        .CommandNotAllowed => .security_command_not_allowed,
        .SecretRefInvalid => .security_secret_ref_invalid,
        .PolicyDenied, .SecurityDenied => .security_policy_denied,
        .LoggingWriteFailed => .logging_write_failed,
        .InternalError => .internal,
    };
}

pub fn domainForCode(error_code: []const u8) ?Domain {
    if (std.mem.startsWith(u8, error_code, "CORE_")) return .core;
    if (std.mem.startsWith(u8, error_code, "VALIDATION_")) return .validation;
    if (std.mem.startsWith(u8, error_code, "CONFIG_")) return .config;
    if (std.mem.startsWith(u8, error_code, "RUNTIME_")) return .runtime;
    if (std.mem.startsWith(u8, error_code, "SERVICE_")) return .service;
    if (std.mem.startsWith(u8, error_code, "PROVIDER_")) return .provider;
    if (std.mem.startsWith(u8, error_code, "CHANNEL_")) return .channel;
    if (std.mem.startsWith(u8, error_code, "TOOL_")) return .tool;
    if (std.mem.startsWith(u8, error_code, "SECURITY_")) return .security;
    if (std.mem.startsWith(u8, error_code, "LOGGING_")) return .logging;
    return null;
}

fn descriptorForKind(kind: InternalErrorKind) ErrorDescriptor {
    return switch (kind) {
        .invalid_request => .{
            .code = code.CORE_INVALID_REQUEST,
            .message = "invalid request",
            .user_message = "请求格式无效",
            .retryable = false,
        },
        .method_not_found => .{
            .code = code.CORE_METHOD_NOT_FOUND,
            .message = "method not found",
            .user_message = "请求的方法不存在",
            .retryable = false,
        },
        .method_not_allowed => .{
            .code = code.CORE_METHOD_NOT_ALLOWED,
            .message = "method not allowed",
            .user_message = "当前入口不允许调用该方法",
            .retryable = false,
        },
        .timeout => .{
            .code = code.CORE_TIMEOUT,
            .message = "request timed out",
            .user_message = "请求处理超时",
            .retryable = true,
        },
        .validation_failed => .{
            .code = code.VALIDATION_FAILED,
            .message = "request validation failed",
            .user_message = "输入参数不符合要求",
            .retryable = false,
        },
        .validation_unknown_field => .{
            .code = code.VALIDATION_UNKNOWN_FIELD,
            .message = "unknown field",
            .user_message = "存在未识别的输入字段",
            .retryable = false,
        },
        .validation_type_mismatch => .{
            .code = code.VALIDATION_TYPE_MISMATCH,
            .message = "type mismatch",
            .user_message = "输入字段类型不正确",
            .retryable = false,
        },
        .validation_value_out_of_range => .{
            .code = code.VALIDATION_VALUE_OUT_OF_RANGE,
            .message = "value out of range",
            .user_message = "输入值超出允许范围",
            .retryable = false,
        },
        .validation_risk_confirmation_required => .{
            .code = code.VALIDATION_RISK_CONFIRMATION_REQUIRED,
            .message = "risk confirmation required",
            .user_message = "该操作需要风险确认",
            .retryable = false,
        },
        .config_load_failed => .{
            .code = code.CONFIG_LOAD_FAILED,
            .message = "config load failed",
            .user_message = "配置加载失败",
            .retryable = false,
        },
        .config_parse_failed => .{
            .code = code.CONFIG_PARSE_FAILED,
            .message = "config parse failed",
            .user_message = "配置解析失败",
            .retryable = false,
        },
        .config_field_unknown => .{
            .code = code.CONFIG_FIELD_UNKNOWN,
            .message = "config field unknown",
            .user_message = "配置字段不存在",
            .retryable = false,
        },
        .config_write_failed => .{
            .code = code.CONFIG_WRITE_FAILED,
            .message = "config write failed",
            .user_message = "配置写入失败",
            .retryable = false,
        },
        .config_migration_failed => .{
            .code = code.CONFIG_MIGRATION_FAILED,
            .message = "config migration failed",
            .user_message = "配置迁移失败",
            .retryable = false,
        },
        .runtime_task_not_found => .{
            .code = code.RUNTIME_TASK_NOT_FOUND,
            .message = "task not found",
            .user_message = "任务不存在",
            .retryable = false,
        },
        .runtime_task_cancelled => .{
            .code = code.RUNTIME_TASK_CANCELLED,
            .message = "task cancelled",
            .user_message = "任务已取消",
            .retryable = false,
        },
        .runtime_task_failed => .{
            .code = code.RUNTIME_TASK_FAILED,
            .message = "task failed",
            .user_message = "任务执行失败",
            .retryable = false,
        },
        .runtime_shutting_down => .{
            .code = code.RUNTIME_SHUTTING_DOWN,
            .message = "runtime shutting down",
            .user_message = "系统正在关闭，暂时无法处理请求",
            .retryable = true,
        },
        .service_operation_failed => .{
            .code = code.SERVICE_OPERATION_FAILED,
            .message = "service operation failed",
            .user_message = "服务操作失败",
            .retryable = false,
        },
        .provider_operation_failed => .{
            .code = code.PROVIDER_OPERATION_FAILED,
            .message = "provider operation failed",
            .user_message = "provider 操作失败",
            .retryable = false,
        },
        .channel_operation_failed => .{
            .code = code.CHANNEL_OPERATION_FAILED,
            .message = "channel operation failed",
            .user_message = "channel 操作失败",
            .retryable = false,
        },
        .tool_operation_failed => .{
            .code = code.TOOL_OPERATION_FAILED,
            .message = "tool operation failed",
            .user_message = "工具调用失败",
            .retryable = false,
        },
        .security_path_not_allowed => .{
            .code = code.SECURITY_PATH_NOT_ALLOWED,
            .message = "path not allowed",
            .user_message = "访问路径不被允许",
            .retryable = false,
        },
        .security_command_not_allowed => .{
            .code = code.SECURITY_COMMAND_NOT_ALLOWED,
            .message = "command not allowed",
            .user_message = "该命令不被允许执行",
            .retryable = false,
        },
        .security_secret_ref_invalid => .{
            .code = code.SECURITY_SECRET_REF_INVALID,
            .message = "secret ref invalid",
            .user_message = "secret 引用无效",
            .retryable = false,
        },
        .security_policy_denied => .{
            .code = code.SECURITY_POLICY_DENIED,
            .message = "policy denied",
            .user_message = "安全策略拒绝了本次请求",
            .retryable = false,
        },
        .logging_write_failed => .{
            .code = code.LOGGING_WRITE_FAILED,
            .message = "logging write failed",
            .user_message = "日志写入失败",
            .retryable = true,
        },
        .internal => .{
            .code = code.CORE_INTERNAL_ERROR,
            .message = "internal error",
            .user_message = "发生内部错误",
            .retryable = false,
        },
    };
}

pub fn fromKind(kind: InternalErrorKind, context: MappingContext) AppError {
    const descriptor = descriptorForKind(kind);

    var app_error = AppError.init(
        descriptor.code,
        context.message orelse descriptor.message,
    ).withRetryable(context.retryable orelse descriptor.retryable);

    if (context.user_message orelse descriptor.user_message) |user_message| {
        app_error = app_error.withUserMessage(user_message);
    }

    if (context.target) |target| {
        app_error = app_error.withTarget(target);
    }

    if (context.details_json) |details_json| {
        app_error = app_error.withDetailsJson(details_json);
    }

    return app_error;
}

pub fn fromErrorName(error_name: []const u8, context: MappingContext) AppError {
    if (kindForErrorName(error_name)) |kind| {
        return fromKind(kind, context);
    }

    var fallback_context = context;
    if (fallback_context.message == null) {
        fallback_context.message = error_name;
    }

    return fromKind(.internal, fallback_context);
}

pub fn fromInternalError(err: anytype, context: MappingContext) AppError {
    return fromErrorName(@errorName(err), context);
}

pub fn fromValidationReport(report: *const ValidationReport) AppError {
    if (report.requiresRiskConfirmation()) {
        if (report.primaryIssue()) |issue| {
            return fromKind(.validation_risk_confirmation_required, .{
                .target = if (issue.path.len > 0) issue.path else null,
                .details_json = issue.details_json,
            });
        }

        return fromKind(.validation_risk_confirmation_required, .{});
    }

    if (report.primaryIssue()) |issue| {
        return fromKind(validationKindForIssueCode(issue.code), .{
            .target = if (issue.path.len > 0) issue.path else null,
            .details_json = issue.details_json,
        });
    }

    return fromKind(.validation_failed, .{});
}

pub fn fromTimeout(message: ?[]const u8) AppError {
    return fromKind(.timeout, .{ .message = message });
}

pub fn fromSecurityDenied(message: ?[]const u8, target: ?[]const u8) AppError {
    return fromKind(.security_policy_denied, .{
        .message = message,
        .target = target,
    });
}

pub fn internal(message: []const u8) AppError {
    return fromKind(.internal, .{ .message = message });
}

pub fn methodNotFound(method: []const u8) AppError {
    return fromKind(.method_not_found, .{ .target = method });
}

pub fn timeout(message: []const u8) AppError {
    return fromKind(.timeout, .{ .message = message });
}

pub fn validationFailed(message: []const u8, details_json: ?[]const u8) AppError {
    return fromKind(.validation_failed, .{
        .message = message,
        .details_json = details_json,
    });
}

fn validationKindForIssueCode(issue_code: []const u8) InternalErrorKind {
    if (std.mem.eql(u8, issue_code, code.VALIDATION_UNKNOWN_FIELD) or
        std.mem.eql(u8, issue_code, "UNKNOWN_FIELD"))
    {
        return .validation_unknown_field;
    }

    if (std.mem.eql(u8, issue_code, code.VALIDATION_TYPE_MISMATCH) or
        std.mem.eql(u8, issue_code, "TYPE_MISMATCH"))
    {
        return .validation_type_mismatch;
    }

    if (std.mem.eql(u8, issue_code, code.VALIDATION_VALUE_OUT_OF_RANGE) or
        std.mem.eql(u8, issue_code, "VALUE_OUT_OF_RANGE"))
    {
        return .validation_value_out_of_range;
    }

    if (std.mem.eql(u8, issue_code, code.VALIDATION_RISK_CONFIRMATION_REQUIRED) or
        std.mem.eql(u8, issue_code, "RISK_CONFIRMATION_REQUIRED"))
    {
        return .validation_risk_confirmation_required;
    }

    return .validation_failed;
}

test "known code prefixes map to expected domains" {
    try std.testing.expect(hasKnownCodePrefix(code.CORE_INTERNAL_ERROR));
    try std.testing.expect(hasKnownCodePrefix(code.VALIDATION_FAILED));
    try std.testing.expect(hasKnownCodePrefix(code.CONFIG_WRITE_FAILED));
    try std.testing.expect(hasKnownCodePrefix(code.RUNTIME_TASK_FAILED));
    try std.testing.expect(hasKnownCodePrefix(code.SECURITY_POLICY_DENIED));
    try std.testing.expect(!hasKnownCodePrefix("UNKNOWN_ERROR"));

    try std.testing.expect(domainForCode(code.CORE_TIMEOUT) == .core);
    try std.testing.expect(domainForCode(code.LOGGING_WRITE_FAILED) == .logging);
}

test "known internal error names map to stable kinds" {
    try std.testing.expect(kindForErrorName("MethodNotFound") == .method_not_found);
    try std.testing.expect(kindForErrorName("Timeout") == .timeout);
    try std.testing.expect(kindForErrorName("UnknownField") == .validation_unknown_field);
    try std.testing.expect(kindForErrorName("PolicyDenied") == .security_policy_denied);
    try std.testing.expect(kindForErrorName("NoSuchThing") == null);
}

test "app error builder keeps optional fields" {
    const app_error = AppError.init(code.CONFIG_WRITE_FAILED, "failed to persist config")
        .withUserMessage("配置写入失败")
        .withRetryable(true)
        .withTarget("logging.level")
        .withDetailsJson("{\"path\":\"logging.level\"}");

    try std.testing.expectEqualStrings(code.CONFIG_WRITE_FAILED, app_error.code);
    try std.testing.expectEqualStrings("failed to persist config", app_error.message);
    try std.testing.expect(app_error.user_message != null);
    try std.testing.expectEqualStrings("配置写入失败", app_error.user_message.?);
    try std.testing.expect(app_error.retryable);
    try std.testing.expect(app_error.target != null);
    try std.testing.expectEqualStrings("logging.level", app_error.target.?);
    try std.testing.expect(app_error.details_json != null);
}

test "helper constructors set stable defaults" {
    const internal_error = internal("panic while dispatching command");
    try std.testing.expectEqualStrings(code.CORE_INTERNAL_ERROR, internal_error.code);
    try std.testing.expect(!internal_error.retryable);

    const timeout_error = timeout("command exceeded timeout");
    try std.testing.expectEqualStrings(code.CORE_TIMEOUT, timeout_error.code);
    try std.testing.expect(timeout_error.retryable);

    const validation_error = validationFailed(
        "request validation failed",
        "{\"issues\":[{\"path\":\"gateway.port\"}]}",
    );
    try std.testing.expectEqualStrings(code.VALIDATION_FAILED, validation_error.code);
    try std.testing.expect(validation_error.details_json != null);
}

test "internal error mapping covers common dispatcher failures" {
    const DispatchError = error{
        MethodNotFound,
        Timeout,
        UnknownField,
        PolicyDenied,
        UnexpectedFailure,
    };

    const method_error = fromInternalError(DispatchError.MethodNotFound, .{
        .target = "config.set",
    });
    try std.testing.expectEqualStrings(code.CORE_METHOD_NOT_FOUND, method_error.code);
    try std.testing.expectEqualStrings("config.set", method_error.target.?);

    const timeout_error = fromInternalError(DispatchError.Timeout, .{
        .message = "dispatcher timed out",
    });
    try std.testing.expectEqualStrings(code.CORE_TIMEOUT, timeout_error.code);
    try std.testing.expect(timeout_error.retryable);
    try std.testing.expectEqualStrings("dispatcher timed out", timeout_error.message);

    const validation_error = fromInternalError(DispatchError.UnknownField, .{
        .target = "gateway.port",
        .details_json = "{\"path\":\"gateway.port\"}",
    });
    try std.testing.expectEqualStrings(code.VALIDATION_UNKNOWN_FIELD, validation_error.code);
    try std.testing.expectEqualStrings("gateway.port", validation_error.target.?);
    try std.testing.expect(validation_error.details_json != null);

    const security_error = fromInternalError(DispatchError.PolicyDenied, .{
        .message = "bridge caller is not allowed",
        .target = "service.restart",
    });
    try std.testing.expectEqualStrings(code.SECURITY_POLICY_DENIED, security_error.code);
    try std.testing.expectEqualStrings("service.restart", security_error.target.?);

    const fallback_error = fromInternalError(DispatchError.UnexpectedFailure, .{});
    try std.testing.expectEqualStrings(code.CORE_INTERNAL_ERROR, fallback_error.code);
    try std.testing.expectEqualStrings("UnexpectedFailure", fallback_error.message);
}

test "specialized mapping helpers keep stable defaults" {
    const timeout_error = fromTimeout(null);
    try std.testing.expectEqualStrings(code.CORE_TIMEOUT, timeout_error.code);
    try std.testing.expect(timeout_error.retryable);
    try std.testing.expectEqualStrings("request timed out", timeout_error.message);

    const security_error = fromSecurityDenied(null, "dangerous.command");
    try std.testing.expectEqualStrings(code.SECURITY_POLICY_DENIED, security_error.code);
    try std.testing.expectEqualStrings("dangerous.command", security_error.target.?);
}

test "validation report maps to stable app error codes" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try report.add("gateway.port", "UNKNOWN_FIELD", "field is not allowed", .@"error");

    const app_error = fromValidationReport(&report);
    try std.testing.expectEqualStrings(code.VALIDATION_UNKNOWN_FIELD, app_error.code);
    try std.testing.expectEqualStrings("gateway.port", app_error.target.?);
}

test "validation report mapping preserves issue details json" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try report.addIssue(
        validation_report.ValidationIssue.init(
            "params.provider",
            "TYPE_MISMATCH",
            "field type does not match the schema",
            .@"error",
        ).withDetailsJson("{\"expected\":\"string\",\"actual\":\"boolean\"}"),
    );

    const app_error = fromValidationReport(&report);
    try std.testing.expect(app_error.details_json != null);
    try std.testing.expectEqualStrings("{\"expected\":\"string\",\"actual\":\"boolean\"}", app_error.details_json.?);
}

test "validation report can require explicit confirmation" {
    var report = ValidationReport.init(std.testing.allocator);
    defer report.deinit();

    try report.add("service.restart", "RISK_CONFIRMATION_REQUIRED", "requires explicit confirmation", .warn);

    const app_error = fromValidationReport(&report);
    try std.testing.expectEqualStrings(code.VALIDATION_RISK_CONFIRMATION_REQUIRED, app_error.code);
    try std.testing.expectEqualStrings("service.restart", app_error.target.?);
}


