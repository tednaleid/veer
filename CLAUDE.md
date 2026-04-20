# veer

A fast CLI tool (Zig) that acts as a Claude Code PreToolUse hook to redirect
agent tool calls toward safer alternatives.

## Build & Test

See `Justfile` for all build, test, and smoke test recipes. Key commands:

- `just check` -- run all tests + linting (used by CI and pre-commit hook)
- `just test` -- run all tests
- `just test-summary` -- run all tests with summary
- `just lint` -- check formatting
- `just build` -- build debug binary
- `just bump` -- bump version, generate release notes, tag, and push
- `just retag` -- re-trigger release workflow for an existing version

Red/green testing: write a failing test before implementing, then make it pass.
All commits should pass `just check`.

Requires **Zig 0.15.2** (install via `brew install zig@0.15`). The stdlib source
is the best API reference:
`/opt/homebrew/Cellar/zig@0.15/0.15.2/lib/zig/std/`

Does not build on Zig 0.16 -- see README "Zig 0.16 compatibility" for the
upstream blocker (`zig-tree-sitter` using removed/relocated Build APIs).

Zig 0.15 has breaking changes from 0.14 -- do not trust code examples from
earlier versions. Key differences:
- `addExecutable` takes a `root_module` (created via `b.createModule`), not `root_source_file`
- `ArrayList` is now unmanaged: use `std.ArrayListUnmanaged(T)`, init with `.empty`,
  pass allocator to `append(allocator, item)` and `deinit(allocator)`
- `std.io.getStdErr()` is gone; use `std.fs.File.stderr()`
- `File.writer()` requires a buffer argument; prefer `std.debug.print` for simple stderr output

## Architecture

- `src/engine/` -- Core matching engine. CommandInfo + rule matchers + shell parser.
- `src/config/` -- TOML config loading.
- `src/claude/` -- Claude Code integration (hook protocol, settings, transcripts).
- `src/store/` -- Storage abstraction. Never import sqlite3 outside this dir.
- `src/cli/` -- Command implementations.
- `src/display/` -- Terminal output (table, color).
- `vendor/` -- Vendored C code (SQLite, tree-sitter-bash). Do not modify.

## Key Conventions

- Tests live alongside source code in `test` blocks at bottom of each file.
- `src/test_all.zig` is the unified test root -- add new test modules there.
  Cross-directory imports don't work from individual test files in Zig 0.15.
- Use `std.testing.allocator` in all tests (detects leaks).
- Table-driven tests via `inline for` over anonymous struct tuples.
- The `Store` interface in `src/store/store.zig` is the ONLY way to access storage.
  Tests use `MemoryStore`. Production uses `SqliteStore`.
- `src/engine/` must not import anything from `src/store/` directly -- it receives
  a `Store` interface at init time.
- All C interop is isolated: SQLite in `src/store/sqlite_store.zig`,
  tree-sitter in `src/engine/shell.zig`.
- Smoke test recipes in the Justfile (check-allow, check-rewrite, check-deny)
  exercise the hook protocol end-to-end.
