# Zig 0.17 migration: parked status

Status of moving veer from Zig 0.16.0 to 0.17.0, and what to do when the work
resumes. Written against veer 0.3.0, two days after Zig 0.17.0 was released
(2026-10-01).

## Summary

The source changes are done on branch `zig-0.17`, and `just check` passes on
0.17.0: all 367 tests, lint, and every smoke test. The branch cannot merge
yet. The tree-sitter core repo's build script does not compile on 0.17, and
the passing run depends on a hand edit to the fetched copy of that package.

The work is parked until tree-sitter ships a fix.

## Environment

- Homebrew had no 0.17.0 bottle on release day. The official tarball
  (checksum verified against `https://ziglang.org/download/index.json`) is
  installed at `~/.local/zig/0.17.0/`. It is not on PATH.
- Homebrew's 0.16.0 is untouched and is still what `just` uses by default.
- To run against 0.17: `PATH=~/.local/zig/0.17.0:$PATH just check`.

## The blocker

`zig-tree-sitter` (pinned at `0cf5817`, release 0.26.0) depends on the
tree-sitter core repo at commit `24a64db` (0.27.0). That repo's `build.zig`
uses `b.build_root`, which 0.17 removed from `std.Build`:

```
zig-pkg/tree_sitter-0.27.0-.../build.zig:133:21: error: no field named 'build_root' in struct 'Build'
    var dir = try b.build_root.handle.openDir(io, "lib/src", .{ .iterate = true });
```

On 2026-10-02, tree-sitter master still had this line, and zig-tree-sitter
had no 0.17 commits. Its CI pins 0.16.0.

The local workaround edits that line in the worktree's `zig-pkg/` copy:

```zig
var dir = try b.root.openDir(io, "lib/src", .{ .iterate = true });
```

`zig-pkg/` is gitignored, so this edit is not on the branch. A fresh clone,
CI, or a refetch of the package gets the unpatched file and fails to build.
To reproduce the passing state in a new checkout, run `zig build` once to
fetch, then reapply the edit above.

The fix upstream is the same one-line change. Filing an issue or PR on
`tree-sitter/tree-sitter` would speed this up. Nothing has been filed yet.

### How to check whether it is fixed

```
gh api repos/tree-sitter/tree-sitter/contents/build.zig --jq .content | base64 -d | grep -n build_root
gh api repos/tree-sitter/zig-tree-sitter/contents/build.zig.zon --jq .content | base64 -d | grep -A2 '\.tree_sitter'
```

The fix has landed when the first command prints nothing and zig-tree-sitter
pins a tree-sitter commit that contains the fix. Ideally zig-tree-sitter also
tags a release that declares 0.17 support. If tree-sitter fixes it but
zig-tree-sitter does not bump its pin, we can pin zig-tree-sitter to a fork
commit that only changes the pin. Treat that as a last resort.

## Changes on the branch

All verified by compiling and testing on 0.17.0.

| File | Change | Reason |
|------|--------|--------|
| `build.zig` | `if (b.args) \|args\| run_cmd.addArgs(args);` becomes `run_cmd.addPassthruArgs();` | `b.args` was removed. Passthrough args are no longer visible during the configure phase. |
| `src/display/table.zig` | `.{0} ** MAX_COLS` becomes `@splat(0)` | Array multiplication (`**`) was removed. |
| `src/engine/path.zig` | `std.StaticBitSet(n)` with `.initEmpty()` becomes `std.bit_set.Static(n)` with `.empty` | `initEmpty` was removed. The type was renamed. |
| `src/engine/matcher.zig` | `@cImport` of `veer_regex.h` becomes `extern fn veer_regex_match(pattern: [*:0]const u8, text: [*:0]const u8) callconv(.c) c_int;` | `@cImport` was removed. This matches the existing `extern fn tree_sitter_bash()` in `shell.zig`. Callers now pass `buf[0..len :0]` instead of `&buf`, because translate-c's `[*c]` pointer no longer applies. |
| `build.zig.zon` | zig-toml `a73c942` to `c661327` (master) | Master has "Fix compile errors in zig 0.17dev". There is no tagged 0.17 release. |
| `build.zig.zon` | zig-clap tag `0.12.0` to `05faf39` (master) | The 0.12.0 tag does not compile on 0.17. Master declares a 0.17 minimum. There is no tagged 0.17 release. |
| `src/config/config.zig` | Two copies of the `toml.ErrorInfo` switch are merged into `ParseDetail.fromErrorInfo`, which copies each field-path segment. `ParseDetail.deinit` frees the segments. | See below. |

### The config.zig change

This is the one change that is not mechanical. Two tests caught it
(`invalid enum value reports the field path` and
`parseFileOnly reports the field path for a schema error`).

The zig-toml bump changes who owns the field path in `error_info`. The old
version copied only the outer slice, and the segments were comptime field
names. The new version copies each segment into the parser's allocator and
frees them in `parser.deinit()`. veer copied only the outer slice, so after
`defer parser.deinit()` ran the segments pointed to freed memory. The test
allocator poisons freed memory, so the `"action"` comparison failed.

The new `ErrorInfo.unknown_fields` variant is mapped to `null`. It is only
produced when `Options.disallow_unknown_fields` is set, and veer does not set
it.

### Behavior changes from the zig-toml bump

These come with the 16 upstream commits between the old and new pins. None of
them broke a test, but they change what configs veer accepts:

- Newlines and trailing commas inside inline tables.
- `\xHH` and `\e` escapes in strings.
- Optional seconds in time values.
- An empty file now parses as an empty document instead of failing.
- Opt-in strict mode for unknown keys (`disallow_unknown_fields`), not
  enabled.

Strict mode could be useful later: it would turn a misspelled rule key into a
config error instead of silently ignoring it. That is a separate decision.

## When resuming

1. Confirm the tree-sitter fix as described above, then bump
   `zig-tree-sitter` in `build.zig.zon` with
   `zig fetch --save=zig-tree-sitter <url>#<commit>`.
2. Delete the worktree's patched `zig-pkg/tree_sitter-0.27.0-*` directory so
   the build uses the real upstream copy. Then run
   `PATH=~/.local/zig/0.17.0:$PATH just check` and confirm 367 tests still
   pass.
3. Check whether zig-toml and zig-clap have tagged 0.17 releases. Prefer a
   tag over the master commits pinned now.
4. Update the version pins:
   - `.github/workflows/ci.yml` (three `version: 0.16.0` lines) and
     `release.yml` to `0.17.0`.
   - `CLAUDE.md`: the required version, the stdlib path, and the "breaking
     changes from 0.15" list. Replace that list with notes on the 0.16 to
     0.17 differences above (`addPassthruArgs`, no `@cImport`, no `**`,
     `@splat`, `bit_set.Static` and `.empty`, `SafeAllocator`,
     `Allocator.print`).
   - `README.md` lines 66 and 803.
5. Install 0.17 through Homebrew once it is bottled, and remove
   `~/.local/zig/0.17.0`.

## Worth changing in the same branch

These are deprecations in 0.17, not errors. Each one is cheap.

**`std.heap.DebugAllocator` is deprecated in favor of
`std.heap.SafeAllocator`.** It is used at `src/main.zig:27` and
`src/bench.zig:10`. The replacement is
`var gpa: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});`.
`deinit` returns `usize`, so `defer _ = gpa.deinit();` still compiles. The
release notes report a stdlib test build ran about 25% faster with half the
memory after the switch. CLAUDE.md also mentions
`DebugAllocator` and needs the same update.

**`std.fmt.allocPrint(a, fmt, args)` is deprecated in favor of
`a.print(fmt, args)`.** There are 58 call sites in `src/`. The change is
mechanical and reads better (`allocator.print("{s}/veer/config.toml", .{xdg})`).
Do it as its own commit so the diff is easy to review.

**`-Doptimize=ReleaseSmall` and `ReleaseFast` are deprecated** in favor of
`small` and `fast`, and are scheduled for removal after 0.18.0. They appear in
the `Justfile`, `ci.yml`, and `release.yml`. Renaming them now avoids a forced
change in the next migration.

**Not worth acting on:**

- The fuzzer did not change in 0.17, so the CI fuzz job in
  `.github/workflows/ci.yml` stays disabled. See `docs/fuzzing.md`.
- There are no changes to `std.Io`, `std.process.Init`, or the `Smith` fuzz
  API that affect veer.
- The comments in `vendor/regex/veer_regex.{h,c}` mention `@cImport`. They
  still correctly explain why the wrapper exists (`regex_t` is opaque under C
  translation), so leave them.
