# zig-opencode

`zig-opencode` is a Zig AI coding agent scaffold built on top of [`framework`](../framework).

Current status:

- foundation-stage project skeleton
- shared framework dependency wired through Zig package management
- composed `AppContext` that wraps `framework.AppContext`
- placeholder module entry points for `session`, `llm`, `agent`, `tools`, and `tui`

Planned capabilities arrive in later changes:

- LLM provider abstraction
- agent loop runtime
- builtin tools and Hashline editing
- session history management
- terminal UI
