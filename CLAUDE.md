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

Requires **Zig 0.16.0** (install via `brew install zig`). The stdlib source
is the best API reference:
`/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/`

Zig 0.16 has breaking changes from 0.15 -- do not trust code examples from
earlier versions. Key differences:
- `std.io` is gone; writers are `*std.Io.Writer`. Build one over a buffer with
  `std.Io.Writer.fixed(&buf)`, read back with `stream.buffered()`, and repeat a
  byte with `writer.splatByteAll(c, n)`.
- `Io` is an explicit parameter on every filesystem and timing call. Construct it
  once in `main` via `std.Io.Threaded` and thread `io: std.Io` through, positioned
  immediately after `allocator`. Tests use `std.testing.io`.
- Filesystem calls take `io` first: `std.Io.Dir.cwd()`, `dir.openFile(io, sub_path, .{})`,
  `dir.createDirPath(io, sub_path)`, `std.process.currentPathAlloc(io, allocator)`.
  `realpath`/`getCwd` are gone; `dir.realPath(io, &buf)` returns a length, and
  `dir.realPathFileAlloc(io, sub_path, allocator)` allocates instead.
- Fuzz bodies are `fn (context, *std.testing.Smith) anyerror!void`; get bytes with
  `smith.slice(&buf)`, which returns the filled length.
- `std.heap.GeneralPurposeAllocator` is now `std.heap.DebugAllocator`.
- Args and environment arrive through `main`'s parameter: `main(init: std.process.Init.Minimal)`.
  `std.process.ArgIterator` and `std.posix.getenv` are gone. Get an arg iterator with
  `init.args.iterateAllocator(allocator)` and read variables with
  `environ.getPosix("NAME")`, threading `environ: std.process.Environ` through like `io`.
  Tests build one from a literal block rather than reading the real environment:
  `.{ .block = .{ .slice = &[_:null]?[*:0]const u8{"HOME=/home/tester"} } }`.
- `addExecutable` takes a `root_module` (created via `b.createModule`), and C source
  and include paths attach to that Module, not to the `Compile` step.

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
  Cross-directory imports don't work from individual test files.
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
