# zig-opencode

A Zig AI coding agent scaffold built on top of the `framework` package.

**Status:** Foundation Stage  
**Overall Completion:** ~60% (modules vary from scaffold to well-developed)

---

## Table of Contents

1. [Project Overview](#project-overview)
2. [Completeness Assessment](#completeness-assessment)
3. [Architecture](#architecture)
4. [Quick Start](#quick-start)
5. [Module Documentation](#module-documentation)

---

## Project Overview

`zig-opencode` is a foundation-stage Zig AI coding agent scaffold. It provides:

- **Modular architecture** with 20+ subsystems (agent, loop, tools, session, etc.)
- **Provider abstraction** for multiple LLM backends (Anthropic, OpenAI)
- **Built-in tools** for file operations, shell execution, LSP integration
- **Session management** with history, compaction, and snapshot support
- **Terminal UI** for interactive agent control
- **HTTP server/client** for headless operation and remote attachment

### Entry Points

| File | Purpose |
|------|---------|
| `src/main.zig` | CLI entry point (`tui`, `serve`, or bootstrap) |
| `src/root.zig` | Package root - re-exports all public types |
| `src/app_context.zig` | Central composition context (~1400 lines) |

---

## Completeness Assessment

| Module | Status | Completion | Notes |
|--------|--------|------------|-------|
| **agent/** | ✅ Complete | 95% | Profiles, registry, built-in agents, category routing |
| **loop/** | ✅ Complete | 90% | Full lifecycle, verification, state persistence |
| **tools/** | ✅ Complete | 90% | 14 built-in tools, registry, execution |
| **session/** | ✅ Complete | 90% | Full model, history, compaction, events |
| **config/** | ✅ Complete | 85% | Schema, defaults, loading, resolution |
| **provider/** | ✅ Complete | 85% | Registry, auth, Anthropic/OpenAI built-in |
| **server/** | ✅ Complete | 85% | HTTP API with 40+ DTOs |
| **client/** | ✅ Complete | 85% | Local + HTTP transports |
| **tui/** | ⚠️ MVP | 70% | Functional terminal UI |
| **lsp/** | ⚠️ Partial | 50% | Types, protocol, client/server implemented |
| **mcp/** | ⚠️ Partial | 50% | Types, transport, runtime, tool adapter |
| **orchestration/** | ⚠️ Partial | 50% | Subtask orchestration types and service |
| **permission/** | ⚠️ Partial | 50% | Types, rule evaluation, runtime |
| **project/** | ⚠️ Partial | 50% | Workspace management |
| **pty/** | ⚠️ Partial | 40% | PTY support types and runtime |
| **prompt/** | ⚠️ Partial | 40% | Assembly functions |
| **skill/** | ⚠️ Minimal | 20% | Runtime scaffold only |
| **framework_integration/** | ❌ Minimal | 10% | ToolingBridge stub |
| **llm/** | ❌ Scaffold | 5% | Empty module stub |

**Overall:** ~60% complete. Core infrastructure (agent, loop, tools, session, config, provider) is well-developed. LLMs and framework integration are the main gaps.

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      main.zig                                │
│              (tui | serve | bootstrap)                       │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                      AppContext                              │
│              (src/app_context.zig ~1400 lines)              │
│  ┌─────────────┬──────────────┬──────────────┬───────────┐ │
│  │ agent_registry │provider_registry│ tool_registry │config  │
│  │ session_runtime │ loop_service │ orchestration_service │  │
│  │ lsp_runtime │ mcp_runtime │ pty_runtime │ permission    │ │
│  │ skill_runtime │ plugin_runtime │ formatter_runtime │     │ │
│  └─────────────┴──────────────┴──────────────┴───────────┘ │
└─────────────────────────────────────────────────────────────┘
                              │
        ┌─────────────────────┼─────────────────────┐
        ▼                     ▼                     ▼
┌─────────────┐        ┌─────────────┐        ┌─────────────┐
│    tui/    │        │   server/   │        │   client/   │
│ TerminalApp│        │ServerListener│        │   Client    │
└─────────────┘        └─────────────┘        └─────────────┘
```

### Key Interfaces

**AppContext** (`src/app_context.zig` L22-606):
- Central composition context
- Initializes and owns all subsystem runtimes
- Provides accessor methods for all components

**AgentProfile** (`src/agent/profile.zig` L7-31):
```zig
pub const AgentProfile = struct {
    id: []const u8,
    mode: AgentMode,
    description: []const u8,
    prompt_asset: []const u8,
    max_steps: ?usize = null,
    default_model: ?provider.ModelRef = null,
    allow_tools: []const []const u8 = &.{},
};
```

**ToolDefinition** (`src/tools/tool.zig` L9-36):
```zig
pub const ToolDefinition = struct {
    id: []const u8,
    description: []const u8,
    input_schema_json: []const u8 = "{}",
    params: []const framework.FieldDefinition = &.{},
    execution_mode: framework.CommandExecutionMode = .sync,
    execute_fn: ?SyncToolExecuteFn = null,
    async_execute_fn: ?AsyncToolExecuteFn = null,
};
```

---

## Quick Start

### Build

```bash
zig build
```

### Run TUI (Local)

```bash
zig build run
```

### Run TUI (Remote Attach)

```bash
zig build run -- tui --attach <session_id>
```

### Run HTTP Server

```bash
zig build run -- serve [port]
```

### Run Tests

```bash
zig build test
```

---

## Module Documentation

### agent/ - Agent Profiles & Registry ✅ 95%

**Files:**
- `root.zig` - Module entry, exports `AgentMode`, `AgentProfile`, `AgentRegistry`
- `profile.zig` - `AgentProfile` struct with agent configuration
- `registry.zig` - `AgentRegistry` for registering/resolving agent profiles
- `builtin.zig` - Built-in agents: `build`, `plan`, `explore`, `oracle`
- `category/` - Category-based routing and execution plans

**Key Types:**
- `AgentMode` enum: `build`, `plan`, `explore`, `subagent`
- `AgentProfile`: id, mode, description, prompt_asset, max_steps, default_model, allow_tools
- `CategoryId`, `CategoryExecutionPlan`

**Status:** Most complete module. Profile system, registry, built-in agents, and category routing all implemented with tests.

---

### loop/ - Agent Loop Runtime ✅ 90%

**Files:**
- `root.zig` - Exports `LoopStrategy`, `LoopPhase`, `LoopState`, `LoopService`
- `types.zig` - Loop strategy, phase, state types
- `state_store.zig` - `LoopStateStore`, `FileLoopStateStore`
- `service.zig` - `LoopService` (~540 lines) - manages agent execution loops

**Key Types:**
```zig
pub const LoopStrategy = enum {
    continue_same_session,
    reset_new_session,
};

pub const LoopPhase = enum {
    running,
    verification_pending,
    completed,
    cancelled,
    failed,
};

pub const LoopState = struct {
    loop_id: []const u8,
    root_session_id: []const u8,
    current_session_id: []const u8,
    agent_id: ?[]const u8 = null,
    category: ?[]const u8 = null,
    model: ?provider.ModelRef = null,
    continuation_prompt: []const u8,
    completion_signal: []const u8,
    strategy: LoopStrategy,
    iteration: u32,
    max_iterations: ?u32 = null,
    active: bool,
    phase: LoopPhase,
    // ...
};
```

**Status:** Well-developed. Full loop lifecycle management, state persistence, verification flow, watcher thread, and extensive tests.

---

### tools/ - Tool Registry & Built-in Tools ✅ 90%

**Files:**
- `root.zig` - Module entry, exports `ToolDefinition`, `ToolRegistry`, `ToolRuntime`
- `tool.zig` - `ToolDefinition` struct
- `registry.zig` - `ToolRegistry`
- `runtime.zig` - `ToolRuntime` for tool execution
- `context.zig` - `ToolExecutionContext`
- `result.zig` - `ToolResult`
- `builtin/` - 14 built-in tools

**Built-in Tools:**
| Tool | File | Description |
|------|------|-------------|
| `read_file` | `builtin/read_file.zig` | Read file contents |
| `write_file` | `builtin/write_file.zig` | Write file contents |
| `edit_file` | `builtin/edit_file.zig` | Edit file (Hashline backend) |
| `execute_shell` | `builtin/execute_shell.zig` | Shell command execution |
| `search_files` | `builtin/search_files.zig` | File search |
| `list_files` | `builtin/list_files.zig` | List directory contents |
| `lsp` | `builtin/lsp.zig` | LSP-based tools |
| `question` | `builtin/question.zig` | Question/answer |
| `skill` | `builtin/skill.zig` | Skill invocation |
| `repo_health_check` | `builtin/repo_health_check.zig` | Health check |
| `revert_files` | `builtin/revert_files.zig` | Revert changes |
| `fetch_url` | `builtin/fetch_url.zig` | URL fetch |
| `mcp_resource` | `builtin/mcp_resource.zig` | MCP resource access |

**Status:** Well-developed. 14 built-in tools, registry, execution context, Hashline integration for edit_file.

---

### session/ - Session Management ✅ 90%

**Files:**
- `root.zig` - Module entry with extensive exports
- `schema.zig` - `SessionId`, `MessageId`, `PartId` ID generation
- `session.zig` - `SessionCreateRequest`, `SessionForkRequest`, `SessionInfo`
- `message.zig` - `MessageRole`, `MessageAppendRequest`, `MessageInfo`
- `part.zig` - `TextPart`, `ReasoningPart`, `ToolCallPart`, `ToolResultPart`
- `store.zig` - `SessionStore`, `FileSessionStore`
- `history.zig` - `MessageWithParts`, `ConversationMessage`, `HistoryService`
- `compaction.zig` - `CompactionPolicy`, session compaction
- `snapshot.zig` - `SnapshotRecord`, `FileSnapshotStore`
- `events.zig` - Event types and publish/subscribe functions
- `runtime.zig` - `SessionRuntime` (~460 lines)
- `status.zig` - `SessionStatus`, `SessionStatusIndex`

**Key Types:**
- `MessageRole`: `user`, `assistant`
- `SessionInfo`: id, created_at, status, model, agent_id
- `MessageInfo`: id, role, created_at, parts

**Status:** Well-developed. Full session model, message handling, part types, history, compaction, events, runtime with tool task execution.

---

### config/ - Configuration ✅ 85%

**Files:**
- `root.zig` - Module entry
- `schema.zig` - Config key definitions
- `defaults.zig` - Bootstrap defaults
- `paths.zig` - `ResolvedPaths`
- `loader.zig` - Config file loading
- `view.zig` - `EffectiveConfig`
- `runtime.zig` - `ConfigRuntime`

**Config Keys** (`src/config/schema.zig`):
```zig
pub const keys = struct {
    pub const model_default = "model.default";
    pub const model_small = "model.small";
    pub const agent_default = "agent.default";
    pub const permission_rules = "permission.rules";
    pub const session_store_path = "session.store.path";
    pub const server_port = "server.port";
    pub const lsp_enabled = "lsp.enabled";
    pub const lsp_servers = "lsp.servers";
    pub const mcp_servers = "mcp.servers";
    pub const formatter_definitions = "formatter.definitions";
    pub const provider_anthropic_base_url = "provider.anthropic.base_url";
    pub const tool_read_file_enabled = "tools.read_file.enabled";
    // ... more
};
```

**Status:** Well-developed. Schema, defaults, paths resolution, loading, effective config view.

---

### provider/ - LLM Provider Abstraction ✅ 85%

**Files:**
- `root.zig` - Module entry
- `model.zig` - `ModelRef`, `ModelInfo`, `ProviderMessage`, `ProviderToolDefinition`
- `provider.zig` - `ProviderInfo`, `AuthKind`
- `client.zig` - `ProviderRequest`, `ProviderStreamEvent`, `LlmEventSink`, `ProviderClient`
- `registry.zig` - `ProviderRegistry` (~200 lines)
- `auth.zig` - `ProviderAuthRuntime`
- `transform.zig` - Request/response transformation
- `builtin/anthropic.zig` - Anthropic client factory
- `builtin/openai.zig` - OpenAI client factory

**Key Types:**
- `ProviderRegistry`: `register()`, `get()`, `defaultModel()`, `makeClient()`, `catalog()`
- `ModelRef`: `provider_id` + `model_id`
- `AuthKind`: `.none`, `.api_key`

**Status:** Well-developed. Full provider abstraction, built-in Anthropic/OpenAI, auth runtime, client creation.

---

### server/ - HTTP API ✅ 85%

**Files:**
- `root.zig` - Module entry, DTO exports
- `dto.zig` - 40+ DTO types
- `services.zig` - `ServerServices`
- `http.zig` - HTTP handling
- `listener.zig` - `ServerListener`

**Status:** Well-developed. Comprehensive HTTP API surface with DTOs.

---

### client/ - Client Abstraction ✅ 85%

**Files:**
- `root.zig` - `Client` struct
- `transport.zig` - `ClientTransport` interface
- `local.zig` - `LocalTransport`
- `http.zig` - `HttpTransport`

**Status:** Well-developed. Full client abstraction with local and HTTP transports.

---

### tui/ - Terminal UI ⚠️ 70%

**Files:**
- `root.zig` - Module entry, exports `TerminalViewModel`, `TerminalApp`
- `model.zig` - `TerminalViewModel` state management
- `render.zig` - Rendering logic
- `terminal.zig` - `TerminalApp` with `runLocal()`, `runAttached()`

**Status:** MVP stage. Functional TUI with dashboard, permission handling, question replies.

---

### lsp/ - Language Server Protocol ⚠️ 50%

**Files:**
- `root.zig` - Module entry
- `types.zig` - `Status`, `Position`, `Operation`, `Diagnostic`
- `protocol.zig` - LSP protocol definitions
- `server.zig` - LSP server implementation
- `client.zig` - `LspClient`, `StdioLspClient`
- `runtime.zig` - `LspRuntime`

**Status:** Partial. Types, protocol, client/server, runtime implemented.

---

### mcp/ - Model Context Protocol ⚠️ 50%

**Files:**
- `root.zig` - Module entry
- `types.zig` - `Status`, `ToolInfo`, `ResourceInfo`, `ToolCallResult`
- `transport.zig` - `McpClient`, `StdioMcpClient`
- `runtime.zig` - `McpRuntime`
- `tool_adapter.zig` - Tool adaptation layer

**Status:** Partial. Core types, transport, runtime, tool adapter present.

---

### orchestration/ - Subtask Orchestration ⚠️ 50%

**Files:**
- `root.zig` - Module entry
- `types.zig` - `ChildRequest`, `ChildHandle`, `ChildResult`, `AggregatedResult`
- `aggregate.zig` - Result aggregation
- `wait.zig` - Wait handling
- `service.zig` - `OrchestrationService`

**Status:** Partial. Subtask orchestration types and service.

---

### permission/ - Permission System ⚠️ 50%

**Files:**
- `root.zig` - Module entry
- `types.zig` - `PermissionAction`, `PermissionRequest`, `PermissionRule`
- `rules.zig` - `evaluate()`, `wildcardMatch()`
- `runtime.zig` - `PermissionRuntime`

**Status:** Partial. Types, rule evaluation, runtime.

---

### project/ - Project Management ⚠️ 50%

**Files:**
- `root.zig` - Module entry
- `types.zig` - `ProjectInfo`, `WorkspaceInfo`, `VcsStatus`
- `runtime.zig` - `ProjectRuntime`, `VcsExecutor`

**Status:** Partial. Project and workspace types, runtime.

---

### pty/ - PTY Support ⚠️ 40%

**Files:**
- `root.zig` - Module entry
- `types.zig` - `PtyInfo`, `OutputChunk`
- `backend.zig` - `PtyHandle`, `BackendFactory`
- `runtime.zig` - `PtyRuntime`

**Status:** Partial. PTY support types and runtime.

---

### prompt/ - Prompt Assembly ⚠️ 40%

**Files:**
- `root.zig` - Module entry
- `system.zig` - System prompt handling
- `reminders.zig` - Reminder handling
- `assembly.zig` - `AssembledPrompt`, `PromptAssets`

**Status:** Partial. Prompt assembly types and functions.

---

### skill/ - Skill System ⚠️ 20%

**Files:**
- `root.zig` - Module entry
- `runtime.zig` - `SkillRuntime`, `SkillInfo`

**Status:** Minimal. Runtime scaffold only.

---

### llm/ - LLM Module ❌ 5%

**Files:**
- `root.zig` - Empty scaffold

```zig
pub const MODULE_NAME = "llm";
pub const ModuleStage = enum { scaffold };
pub const MODULE_STAGE: ModuleStage = .scaffold;
```

**Status:** Empty scaffold. No actual LLM functionality.

---

### framework_integration/ - ❌ 10%

**Files:**
- `root.zig` - Module entry
- `tooling_bridge.zig` - `ToolingBridge`

**Status:** Minimal. Just the bridge to framework tooling.

---

## Dependencies

- **framework** - Core dependency, provides `AppContext`, `CommandExecutionMode`, `FieldDefinition`, etc.
- **Zig standard library**

## Build Configuration

```zig
// build.zig
const framework_dep = b.dependency("framework", .{
    .target = target,
    .optimize = optimize,
});
const framework_mod = framework_dep.module("framework");
```

---

## TODO / Gaps

1. **llm/** - Currently empty scaffold, needs actual LLM integration
2. **framework_integration/** - Minimal, needs deeper framework integration
3. **skill/** - Just a scaffold, needs runtime implementation
4. More complete MCP client implementation
5. Enhanced LSP integration
6. Better error handling and recovery
7. More comprehensive test coverage