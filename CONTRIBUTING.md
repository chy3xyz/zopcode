# Contributing to zopcode

Thank you for your interest in contributing to zopcode! This document provides guidelines for contributing.

## Getting Started

1. Fork the repository
2. Clone your fork
3. Create a feature branch: `git checkout -b feat/my-feature`
4. Make your changes
5. Run tests: `zig build test`
6. Commit and push
7. Open a Pull Request

## Prerequisites

- [Zig 0.17+](https://ziglang.org/download/)

## Development

### Build

```bash
zig build
```

### Test

```bash
zig build test
```

Tests live inline within `.zig` files. Search for `test "` blocks to find them.

### Run

```bash
zig build run                # TUI mode
zig build run -- serve       # HTTP server
zig build run -- serve 8080  # HTTP server on custom port
```

## Code Style

- Follow standard Zig conventions (`zig fmt`)
- Use descriptive variable names
- Keep functions focused and small
- Write inline tests for non-trivial logic
- Use `//` comments for complex sections
- All public API functions should have doc comments

## Project Structure

- `src/` — All source code, organized by subsystem
- `src/app_context.zig` — Central composition root
- `src/root.zig` — Package root, re-exports public types
- `docs/` — Module documentation

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) style:

```
feat(provider): add Google Gemini support
fix(session): handle empty message history
docs: update module status in README
refactor(tools): simplify edit_file hash matching
```

## Pull Requests

- Keep PRs focused on a single change
- Include a clear description of what changed and why
- Ensure `zig build test` passes
- Update documentation if adding/changing public API

## Issues

- Use GitHub Issues for bugs and feature requests
- Include Zig version, OS, and reproduction steps for bugs

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
