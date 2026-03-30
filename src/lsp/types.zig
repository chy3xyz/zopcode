const std = @import("std");

pub const StatusKind = enum {
    connected,
    @"error",
    disabled,

    pub fn asText(self: StatusKind) []const u8 {
        return switch (self) {
            .connected => "connected",
            .@"error" => "error",
            .disabled => "disabled",
        };
    }
};

pub const Status = struct {
    id: []const u8,
    root: []const u8,
    status: StatusKind,
    error_message: ?[]const u8 = null,

    pub fn clone(self: Status, allocator: std.mem.Allocator) !Status {
        return .{
            .id = try allocator.dupe(u8, self.id),
            .root = try allocator.dupe(u8, self.root),
            .status = self.status,
            .error_message = if (self.error_message) |value| try allocator.dupe(u8, value) else null,
        };
    }

    pub fn deinit(self: *Status, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.root);
        if (self.error_message) |value| allocator.free(value);
    }
};

pub const Position = struct {
    file_path: []const u8,
    line: u32,
    character: u32,
};

pub const Operation = enum {
    go_to_definition,
    find_references,
    hover,
    document_symbols,
    workspace_symbols,
    go_to_implementation,

    pub fn fromText(value: []const u8) ?Operation {
        if (std.mem.eql(u8, value, "go_to_definition")) return .go_to_definition;
        if (std.mem.eql(u8, value, "find_references")) return .find_references;
        if (std.mem.eql(u8, value, "hover")) return .hover;
        if (std.mem.eql(u8, value, "document_symbols")) return .document_symbols;
        if (std.mem.eql(u8, value, "workspace_symbols")) return .workspace_symbols;
        if (std.mem.eql(u8, value, "go_to_implementation")) return .go_to_implementation;
        return null;
    }
};

pub const OperationRequest = struct {
    operation: Operation,
    file_path: ?[]const u8 = null,
    line: ?u32 = null,
    character: ?u32 = null,
    query: ?[]const u8 = null,
};

pub const Diagnostic = struct {
    file_path: []const u8,
    line: u32,
    character: u32,
    severity: ?u8 = null,
    message: []const u8,

    pub fn clone(self: Diagnostic, allocator: std.mem.Allocator) !Diagnostic {
        return .{
            .file_path = try allocator.dupe(u8, self.file_path),
            .line = self.line,
            .character = self.character,
            .severity = self.severity,
            .message = try allocator.dupe(u8, self.message),
        };
    }

    pub fn deinit(self: *Diagnostic, allocator: std.mem.Allocator) void {
        allocator.free(self.file_path);
        allocator.free(self.message);
    }

    pub fn pretty(self: Diagnostic, allocator: std.mem.Allocator) ![]u8 {
        const level = switch (self.severity orelse 1) {
            1 => "ERROR",
            2 => "WARN",
            3 => "INFO",
            4 => "HINT",
            else => "UNKNOWN",
        };
        return std.fmt.allocPrint(allocator, "{s} [{d}:{d}] {s}", .{
            level,
            self.line + 1,
            self.character + 1,
            self.message,
        });
    }
};

pub fn freeDiagnostics(allocator: std.mem.Allocator, items: []Diagnostic) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

test "status kind and operation text parsing stay stable" {
    try std.testing.expectEqualStrings("connected", StatusKind.connected.asText());
    try std.testing.expect(Operation.fromText("hover") != null);
    try std.testing.expect(Operation.fromText("missing") == null);
}
