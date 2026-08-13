# Zig 0.16 Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task.

**Goal:** Move veer from Zig 0.15.2 to 0.16.0, drop 0.15 support, and return the macOS release runners to `macos-latest`.

**Architecture:** Zig 0.16 makes `Io` an explicit parameter on every filesystem and timing call, removes `std.io` in favour of `std.Io`, and deletes `realpath`/`getCwd`. veer constructs one `std.Io.Threaded` in `main` and threads `io` alongside the allocator it already threads. Tests use the ready-made `std.testing.io`.

**Spec:** `docs/superpowers/specs/2026-08-13-zig-016-migration-design.md`

---

## Global Constraints

- **Zig 0.16.0 only**, at `/opt/homebrew/Cellar/zig/0.16.0/bin/zig`. Stdlib reference: `/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/`. It is the authority; read it rather than guessing an API.
- **NEVER use `--no-verify`.** See "Committing" below: this migration commits once, at the end, when green.
- **No behavior changes.** Not one rule, matcher, or output string moves. A diff that changes what veer does is out of scope.
- **Test count must stay 325.** Tests may change shape where `tmpDir`/`realPath` force it, but each must assert what it asserted before. A dropped test is a failure.
- Preserve `// ABOUTME:` headers, no emoji, no em dashes, comments state what is true now.

## Committing

The branch does not compile until the migration finishes, so no intermediate commit can pass the pre-commit hook, and `--no-verify` is forbidden. **Subagents must not commit.** Each leaves its work in the working tree and reports; the orchestrator commits once when `just check` is green.

## Working state

Work in the existing worktree `.claude/worktrees/zig016` on branch `zig-0.16-probe`, which already contains, uncommitted and verified:

- `build.zig.zon`: `zig-tree-sitter` at v0.26.0, `clap` at 0.12.0, `toml` unchanged.
- `build.zig`: twelve `addCSourceFile`/`addCSourceFiles`/`addIncludePath` calls moved from the `Compile` step to its `Module`.
- `src/display/table.zig`: fully migrated, serves as the reference for the writer idiom.

## Proven idioms

Verified against 0.16.0 by compiling, not inferred.

```zig
// Writers
var stream = std.Io.Writer.fixed(&buf);   // was std.io.fixedBufferStream(&buf)
try t.render(&stream);                    // was t.render(stream.writer())
const out = stream.buffered();            // was stream.getWritten()
try writer.splatByteAll(' ', n);          // was writer.writeByteNTimes(' ', n)

// Io construction, once in main
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();
const io = threaded.io();

// Filesystem, io first after the receiver
std.Io.Dir.cwd()                          // was std.fs.cwd()
dir.openFile(io, sub_path, .{})           // was dir.openFile(sub_path, .{})
dir.createDirPath(io, sub_path)           // was dir.makePath(sub_path)
dir.realPath(io, &buf)                    // was dir.realpathAlloc(alloc, ".") -> returns a length
std.process.currentPathAlloc(io, alloc)   // was std.process.getCwdAlloc(alloc)

// Misc
std.heap.DebugAllocator                   // was std.heap.GeneralPurposeAllocator
list.print(gpa, fmt, args)                // was list.writer().print(fmt, args)
```

`writer: anytype` parameters **do not change**: `*std.Io.Writer` satisfies them. Confirmed by `table.zig`.

In tests, use `std.testing.io`. Test functions need no new parameter.

## Method

The compiler is the checklist. After each task run:

```
/opt/homebrew/Cellar/zig/0.16.0/bin/zig build test 2>&1 | grep -c "error:"
```

and report the count. It must fall monotonically. **Expect new errors to appear as old ones are fixed** — Zig stops analysis early, so 111 is a floor, not a total. That is not a regression; report it and continue.

---

### Task 1: Toolchain switch

Non-code. Everything that names the Zig version.

- `Justfile`: any pinned zig path or version.
- `.github/workflows/ci.yml` and `release.yml`: `mlugg/setup-zig` version to `0.16.0`.
- `CLAUDE.md`: "Requires Zig 0.15.2" and the stdlib reference path become 0.16.0. Delete the "Does not build on Zig 0.16" paragraph and the 0.15-vs-0.14 differences list; replace with the 0.16 idioms above.
- `README.md`: build requirements, and **delete the entire "Zig 0.16 compatibility" section** — it is now false.

Leave the `macos-15` pin alone; Task 7 handles it.

### Task 2: Io construction and threading

The structural task. Do this before the mechanical buckets so they have an `io` to use.

1. In `src/main.zig`, replace `std.heap.GeneralPurposeAllocator` with `std.heap.DebugAllocator`, construct the `Io.Threaded`, and get `io`.
2. Thread `io: std.Io` as a parameter, immediately after `allocator`, through every production function that performs filesystem work. Expect: `config/config.zig` (upward discovery), `cli/install.zig`, `claude/hook.zig`, `claude/transcript.zig`, `cli/check.zig`, `cli/scan.zig`, and their callers in `main.zig`.
3. Tests call these functions with `std.testing.io`.

Do not add `io` to functions that do no I/O. The engine (`src/engine/`) should need it only where it reads the environment or the clock.

### Task 3: The writer bucket

53 occurrences of `std.io`. Apply the writer idioms above. `src/display/table.zig` is already done and is the reference.

Watch for members that no longer exist on `Io.Writer` (`writeByteNTimes` was one); look up the replacement in `Io/Writer.zig` rather than improvising.

### Task 4: The path bucket

39 `realpathAlloc` occurrences plus `std.fs.cwd`, `makePath`, `openFileAbsolute`.

Most are the test idiom `tmp.dir.realpathAlloc(std.testing.allocator, ".")`, used to get a tmpdir's absolute path. `realPath` now writes into a caller buffer and returns a length, so settle one helper for this and use it everywhere rather than open-coding 39 variants. `TmpDir` exposes `sub_path`, `dir`, and `parent_dir` if a path must be reconstructed instead.

### Task 5: The long tail

`std.posix.getenv` (3), `std.time.Timer` (1, now via `std.Io.Clock`), `std.process.Child.run` (1), `ArrayList.writer()` (1), and whatever the earlier tasks uncovered.

`Child.run` is used by `install.zig` for `git rev-parse --git-path info/exclude`. Its behavior must not change: still returns null and skips silently when not in a git repo.

### Task 6: Fuzz test signatures

3 occurrences. Bodies take `*std.testing.Smith` instead of `[]const u8`. Read `std/testing.zig` for the new shape and keep each fuzz target asserting what it did before.

### Task 7: Green, then unpin the runner

1. `just check` must pass: 325 tests, lint, and every smoke recipe including `check-gate` and `check-local-install-exclude`.
2. `just bench` must run.
3. Revert the `macos-15` pin in `.github/workflows/release.yml` to `macos-latest` and delete the comment explaining the pin.
4. Orchestrator commits.

The unpin cannot be verified locally. If CI fails on `macos-26`, restore the pin with a comment naming 0.16 as also unable to build there; that outcome does not block the rest.

## Verification

Success is `just check` green with **exactly 325 tests** on Zig 0.16.0, plus `just bench` running, plus a release workflow that builds all four platform targets on unpinned runners.

The smoke recipes matter more than usual: they drive a built binary through the real hook protocol, which is where an `io` threading mistake would surface that unit tests miss.
