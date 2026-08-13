# Zig 0.16 migration

Design for moving veer from Zig 0.15.2 to 0.16.0 and dropping 0.15 support.

Written against veer 0.2.0.

## Motivation

Two reasons, one of them already costing us.

**The release pipeline is on a pinned runner.** GitHub moved `macos-latest` to
`macos-26-arm64`. Zig 0.15.2 cannot link against that SDK: it fails on
libSystem symbols while compiling its own build runner, which broke the v0.2.0
release. The workaround pins the macOS jobs to `macos-15`. That image will be
retired eventually, and the pin is a countdown, not a fix.

**The blocker recorded in the README is stale.** It says `zig-tree-sitter`
cannot build on 0.16. That was true of the version we pin; it is not true of
the current release. The README also estimates the work at fifteen minutes,
which is wrong by an order of magnitude. Both claims are corrected here.

## Decisions

Settled, not open:

1. **Drop Zig 0.15 support entirely.** `std.io` no longer exists in 0.16, so
   source that compiles on both is not practical without a shim layer worth
   more than it saves. This is a hard cutover.
2. **Unpin the macOS release runners** in the same change, returning them to
   `macos-latest`, contingent on 0.16 building there. Verified in CI, since it
   cannot be verified locally.
3. Minimum toolchain becomes 0.16.0, updated in `CLAUDE.md`, `README.md`, the
   CI and release workflows, and the Homebrew install instructions.

## Verified before writing this

Every claim below was checked against Zig 0.16.0 in a probe worktree, not
inferred from documentation.

### Dependencies are solved

| Dependency | Action | Evidence |
|---|---|---|
| `zig-tree-sitter` | 0.25.0 to **v0.26.0** | Build script resolves clean. Upstream commit `b22ced81` "build(zig): update to zig 0.16" is an ancestor of the v0.26.0 tag. |
| `zig-clap` | 0.11.0 to **0.12.0** | 0.11.0 fails on a changed `@Type` builtin. 0.12.0 declares `minimum_zig_version = "0.16.0-dev.2261"`. |
| `zig-toml` | **unchanged** | The currently pinned commit compiles and round-trips a parse on 0.16. |

Pin `zig-clap` at 0.12.0 rather than tracking its `main`, which has already
moved to 0.17-dev.

A stale `tree_sitter-0.26.0` entry in the local `zig-pkg/` cache does use the
old build API and is easy to mistake for the bindings. It is the core
tree-sitter C library, a transitive dependency, and both packages are named
`tree_sitter`. Read the tag, not the cache.

### `build.zig` is already migrated and forward compatible

Twelve `addCSourceFile` / `addCSourceFiles` / `addIncludePath` calls move from
the `Compile` step to the `Module` it was built from. Verified to pass all 325
tests on **0.15.2 as well**, so this half carries no cutover risk.

### What remains

111 compile errors, all in veer's own source, none in any dependency.

## The shape of the work

### Io is a parameter now

This is the change that makes the migration a refactor rather than a rename.
In 0.16 every filesystem and timing operation takes an `Io`:

```zig
pub fn openFile(dir: Dir, io: Io, sub_path: []const u8, options: OpenFileOptions) ...
pub fn createDirPath(dir: Dir, io: Io, sub_path: []const u8) ...
pub fn realPath(dir: Dir, io: Io, out_buffer: []u8) ...
```

An `Io` is constructed once and threaded down:

```zig
var threaded: std.Io.Threaded = .init(gpa, .{});
defer threaded.deinit();
const io = threaded.io();
```

**Decision: thread `io` explicitly, as a parameter, exactly like `allocator`.**
veer already passes `allocator` through every layer, so `io` alongside it is
consistent and keeps functions testable. A module-level singleton would shrink
the diff but hide a dependency that the standard library deliberately made
visible, and it would make it impossible to run tests against a different `Io`
later.

**Tests use `std.testing.io`**, a ready-made instance the standard library
exposes under `builtin.is_test`. Test functions therefore need no new
parameter, which matters because most of the churn is in tests.

Production call sites that need it: `config.zig` (upward config discovery),
`install.zig` (settings, config stub, skill file, `.git/info/exclude`),
`hook.zig` (transcript and plan file reads), `transcript.zig`, `check.zig`,
`scan.zig`, and `main.zig` (which constructs the `Io`).

### API mapping

The table the implementation works from. Counts are error occurrences.

| Count | 0.15 | 0.16 |
|---|---|---|
| 53 | `std.io.fixedBufferStream(&buf)`, `.writer()`, `.getWritten()` | `std.Io.Writer.fixed(&buf)`, pass `&w` directly, `w.buffered()` |
| 39 | `dir.realpathAlloc(alloc, ".")` | `dir.realPath(io, &buf)` returning a length, or `realPathFileAlloc` |
| 4 | `std.fs.cwd()` | `std.Io.Dir.cwd()` |
| 4 | `dir.makePath(p)` | `dir.createDirPath(io, p)` |
| 3 | `std.posix.getenv` | `std.process` environment access |
| 3 | fuzz body `fn (void, []const u8)` | `fn (void, *std.testing.Smith)` |
| 1 | `std.time.Timer` | `io.now(clock)` via `std.Io.Clock` |
| 1 | `std.process.Child.run` | relocated; resolve at the call site |
| 1 | `std.fs.openFileAbsolute` | `std.Io.Dir.openFileAbsolute(io, ...)` |
| 1 | `ArrayList.writer()` | `list.print(gpa, fmt, args)` |
| - | `std.heap.GeneralPurposeAllocator` | `std.heap.DebugAllocator` |
| - | `std.process.getCwdAlloc` | `std.process.currentPathAlloc(io, alloc)` |

`realpath` and `getCwd` have no direct equivalents; the replacements above are
differently shaped, which is why those 39 sites are the second largest bucket
and need a settled idiom rather than a substitution.

### The writer question

veer threads `writer: anytype` through `src/cli/`. In 0.16 `std.Io.Writer` is a
concrete type with explicit buffering rather than a generic. The migration
keeps `anytype` where it already works and changes only construction, so CLI
signatures are expected to survive. This is the one assumption in this design
that the implementation may falsify; if signatures do have to change, that is a
mechanical widening across `src/cli/`, not a redesign.

## Sequencing

The cutover is atomic by necessity: the branch does not compile until the
source migration completes. Order within it:

1. Dependency bumps and `build.zig` module migration. Already proven; can land
   on `main` ahead of the rest because it works on 0.15.2 too.
2. Toolchain switch: `Justfile`, CI, release workflow, `CLAUDE.md`, `README`.
3. `Io` construction in `main.zig` and threading through the production call
   graph.
4. The mechanical buckets: writers, then paths, then the long tail.
5. Fuzz test signatures.
6. Unpin the macOS runners and confirm in CI.

## Testing

`just check` is the gate throughout, unchanged in content: 325 tests plus lint
plus every smoke recipe. The migration adds no behavior, so a passing suite
with an unchanged test count is the success criterion. Any test that has to
change shape (the `tmpDir` and `realPath` sites) must assert the same thing it
asserted before.

The smoke recipes matter more than usual here: they exercise the real hook
protocol end to end through a built binary, which is where an `Io` threading
mistake would surface that unit tests could miss.

## Risks

**The runner unpin cannot be verified locally.** If 0.16 also fails on
`macos-26`, the pin stays and decision 2 is deferred without affecting the
rest.

**`zig-toml` has no 0.16 release.** It works today on the pinned commit, but
its `main` tracks 0.17-dev, so a future bump needs the same verification this
one got.

**Error counts are a floor, not a total.** Zig stops analysis early, so fixing
the first bucket will reveal errors currently hidden behind it. The 111 figure
is what the test target reports today, not the total number of edits.

## Non-goals

**No behavior changes.** Not a single rule, matcher, or output format moves.
Any diff that changes what veer does is out of scope.

**No 0.17 preparation.** Both `zig-clap` and `zig-toml` upstreams have started
tracking 0.17-dev. That is a future migration and pinning against it now would
be speculative.

**No async adoption.** 0.16 makes `Io` explicit to enable async execution.
veer is a short-lived process on a hot path and gains nothing from it. It
constructs a single `Io.Threaded` and uses it synchronously.
