const std = @import("std");

pub const MODULE_NAME = "lsp";

pub const types = @import("types.zig");
pub const protocol = @import("protocol.zig");
pub const server = @import("server.zig");
pub const client = @import("client.zig");
pub const runtime = @import("runtime.zig");

pub const StatusKind = types.StatusKind;
pub const Status = types.Status;
pub const Position = types.Position;
pub const Operation = types.Operation;
pub const OperationRequest = types.OperationRequest;
pub const Diagnostic = types.Diagnostic;
pub const freeDiagnostics = types.freeDiagnostics;
pub const LspClient = client.LspClient;
pub const ClientFactory = client.ClientFactory;
pub const DiagnosticsSink = client.DiagnosticsSink;
pub const StdioLspClient = client.StdioLspClient;
pub const LspRuntime = runtime.LspRuntime;
pub const LspRuntimeDependencies = runtime.Dependencies;
pub const LSP_UPDATED_EVENT_TOPIC = runtime.LSP_UPDATED_EVENT_TOPIC;
pub const LSP_DIAGNOSTICS_UPDATED_EVENT_TOPIC = runtime.LSP_DIAGNOSTICS_UPDATED_EVENT_TOPIC;

test "lsp module exports are available" {
    try std.testing.expectEqualStrings("lsp", MODULE_NAME);
}
