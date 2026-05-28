# zopcode

A modular AI coding agent built with Zig, providing LLM provider abstraction, built-in tools, session management, and a terminal UI.

**Status:** Foundation stage · 129 Zig source files · Zig 0.17

---

## Features

- **Modular architecture** — 20+ subsystems: agent, loop, tools, session, provider, server, client, TUI, LSP, MCP, PTY, and more
- **Multi-provider LLM** — Pluggable provider abstraction with built-in Anthropic and OpenAI clients
- **Built-in tools** — 14 tools: file read/write/edit (Hashline), shell execution, search, LSP, MCP, URL fetch, and more
- **Session management** — Full message history, compaction, snapshots, and event-driven architecture
- **Terminal UI** — Interactive TUI with dashboard, permission handling, and question/answer flow
- **HTTP server** — Headless operation mode with 40+ DTO endpoints for remote attachment
- **Agent loop** — Configurable execution strategies with verification gates and state persistence
- **MCP & LSP** — Model Context Protocol and Language Server Protocol integration scaffolds

## Architecture

```
main.zig
  ├── tui/          Terminal UI (local + remote attach)
  ├── server/       HTTP API server
  └── AppContext     Central composition root
        ├── agent/         Agent profiles & category routing
        ├── loop/          Execution loop runtime
        ├── tools/         Tool registry & 14 built-in tools
        ├── session/       Session, message, history, compaction
        ├── provider/      LLM provider abstraction
        ├── config/        Schema, defaults, loading, runtime
        ├── client/        Local + HTTP transport clients
        ├── orchestration/ Subtask orchestration
        ├── permission/    Permission rules & evaluation
        ├── question/      Interactive Q&A
        ├── pty/           Pseudo-terminal support
        ├── lsp/           Language Server Protocol
        ├── mcp/           Model Context Protocol
        ├── prompt/        System prompt assembly
        ├── skill/         Skill runtime
        ├── plugin/        Plugin runtime
        ├── project/       Workspace management
        ├── formatter/     Output formatting
        └── llm/           LLM client (stub)
```

## Quick Start

### Prerequisites

- [Zig 0.17+](https://ziglang.org/download/)

### Build

```bash
git clone https://github.com/chy3xyz/zopcode.git
cd zopcode
zig build
```

### Run

```bash
# Terminal UI
zig build run

# HTTP server (default port 4096)
zig build run -- serve

# HTTP server (custom port)
zig build run -- serve 8080
```

### Test

```bash
zig build test
```

## Project Structure

| Path | Description |
|------|-------------|
| `src/` | All source code (129 `.zig` files) |
| `src/main.zig` | Entry point — CLI dispatching |
| `src/root.zig` | Package root — re-exports all public types |
| `src/app_context.zig` | Composition root (~1400 lines) |
| `src/tools/builtin/` | 14 built-in tool implementations |
| `src/provider/builtin/` | Anthropic & OpenAI provider clients |
| `tests/` | Unit tests (empty — tests live inline) |
| `docs/` | Detailed module documentation |
| `zig-pkg/` | `zaibase` framework dependency |

## Module Status

| Module | Completion | Description |
|--------|------------|-------------|
| agent/ | 95% | Profiles, registry, built-in agents, category routing |
| loop/ | 90% | Full lifecycle, verification, state persistence |
| tools/ | 90% | 14 built-in tools, registry, execution |
| session/ | 90% | Full model, history, compaction, events |
| config/ | 85% | Schema, defaults, loading, resolution |
| provider/ | 85% | Registry, auth, Anthropic/OpenAI built-in |
| server/ | 85% | HTTP API with 40+ DTOs |
| client/ | 85% | Local + HTTP transports |
| tui/ | 70% | Functional terminal UI |
| lsp/ | 50% | Types, protocol, client/server |
| mcp/ | 50% | Types, transport, runtime |
| orchestration/ | 50% | Subtask orchestration |
| permission/ | 50% | Rules, evaluation, runtime |
| project/ | 50% | Workspace management |
| pty/ | 40% | PTY types and runtime |
| prompt/ | 40% | Assembly functions |
| skill/ | 20% | Runtime scaffold |
| llm/ | 5% | Empty module stub |

**Overall: ~60% complete.**

## Built-in Tools

| Tool | Description |
|------|-------------|
| `read_file` | Read file contents |
| `write_file` | Write file contents |
| `edit_file` | Edit file via Hashline anchor-based replacement |
| `execute_shell` | Run shell commands |
| `search_files` | Regex search across files |
| `list_files` | List directory entries |
| `lsp` | LSP-based code intelligence |
| `question` | Interactive question/answer |
| `skill` | Skill invocation |
| `repo_health_check` | Repository health check |
| `revert_files` | Revert file changes |
| `fetch_url` | HTTP URL fetch |
| `mcp_resource` | MCP resource access |

## License

[MIT](LICENSE)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

---

Built with [Zig](https://ziglang.org/) 0.17 · Powered by the [zaibase](https://github.com/chy3xyz/zopcode) framework.
