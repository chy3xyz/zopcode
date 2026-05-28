# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/).

## [0.1.0] - 2025-05-29

### Added
- **Modular architecture** — 20+ subsystems with centralized `AppContext`
- **Agent system** — Profile registry, built-in agents (build, plan, explore, oracle), category routing
- **Agent loop** — Execution loop with verification gates, state persistence, configurable strategies
- **Tool framework** — Registry, execution context, 14 built-in tools
  - File I/O: `read_file`, `write_file`, `edit_file` (Hashline)
  - Shell: `execute_shell`
  - Search: `search_files`, `list_files`
  - Integration: `lsp`, `mcp_resource`, `fetch_url`
  - Interactive: `question`, `skill`, `repo_health_check`, `revert_files`
- **Session management** — Message history, compaction, snapshots, event-driven architecture
- **Provider abstraction** — Pluggable LLM backend with built-in Anthropic and OpenAI clients
- **Configuration** — Schema, defaults, file loading, effective config resolution
- **HTTP server** — Headless mode with 40+ DTO endpoints
- **Client abstraction** — Local + HTTP transport clients
- **Terminal UI** — Dashboard, permission handling, Q&A flow
- **MCP & LSP** — Model Context Protocol and Language Server Protocol scaffolds
- **PTY support** — Pseudo-terminal runtime
- **Permission system** — Rule evaluation and runtime
- **Prompt assembly** — System prompt construction
- **Project management** — Workspace management
- **Formatter** — Output formatting

### Changed
- Migrated to Zig 0.17 `std.Io` APIs (file I/O, networking, threading)
- Renamed project from `zig-opencode` to `zopcode`

### Added (0.2.0)
- **LLM runtime** — Streaming completion API with callback-based event forwarding, model catalog, health check
- **ScriptBridge** — Framework tool integration (RepoHealthCheck + ScriptMarkdownFetch)
- **Open source prep** — LICENSE, CONTRIBUTING.md, CHANGELOG.md, README rewrite

### Dependencies
- `zaibase` framework (bundled in `zig-pkg/`)
