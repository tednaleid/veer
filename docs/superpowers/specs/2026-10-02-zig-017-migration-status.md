# Zig 0.17 migration: status

Status of moving veer from Zig 0.16.0 to 0.17.0. First written on 2026-10-02
against veer 0.3.0, when the work was parked on a tree-sitter build failure.
Updated on 2026-11-22 against veer 0.4.0, when the branch was unblocked with a
fork of `zig-tree-sitter`.

## Summary

The source changes are on branch `zig-0.17`, and `just check` passes on
Homebrew's Zig 0.17.0 from a clean package fetch: all 386 tests, lint, and
every smoke test. The four release targets cross-compile.

The build depends on a fork, `tednaleid/zig-tree-sitter`, described below.
Dropping that fork is the open follow-up.

## The tree-sitter fork

`zig-tree-sitter` upstream (HEAD `b562510` on 2026-11-22) depends on the
tree-sitter core repo at commit `24a64db` (0.27.0). That repo's `build.zig`
uses `b.build_root`, which 0.17 removed from `std.Build`:

```
zig-pkg/tree_sitter-0.27.0-.../build.zig:133:21: error: no field named 'build_root' in struct 'Build'
    var dir = try b.build_root.handle.openDir(io, "lib/src", .{ .iterate = true });
```

Core fixed this on master in `e70c5ab` ("build(zig)!: update to Zig 0.17",
2026-11-07), which is 0.28.0-dev and unreleased. The 0.27.x tags, through
0.27.2, still fail. `zig-tree-sitter` has not moved its pin and had no open
pull requests on 2026-11-22.

The fork is `https://github.com/tednaleid/zig-tree-sitter`, branch `zig-0.17`,
commit `f799095`. It is upstream HEAD `b562510` plus one commit that changes
only `build.zig.zon`, repointing the `tree_sitter` dependency at core master
commit `32594ac`. veer's `build.zig.zon` pins the fork by commit.

Consequences to keep in mind:

- veer links an unreleased tree-sitter core (0.28.0-dev). The vendored
  tree-sitter-bash grammar works with it: the shell parser tests pass.
- The fork does not track upstream. Fixes to `zig-tree-sitter` do not reach
  veer until the fork is rebased or dropped.

### How to check whether the fork can be dropped

```
gh api repos/tree-sitter/zig-tree-sitter/contents/build.zig.zon --jq .content | base64 -d | grep -A2 '\.tree_sitter = '
```

The fork can be dropped when upstream pins a core commit that declares
`minimum_zig_version` 0.17.0 or later (core 0.28.0 and up). Ideally upstream
also tags a release. Then:

1. `zig fetch --save=zig-tree-sitter <upstream url>#<commit or tag>`
2. Remove the fork comment in `build.zig.zon` and the "Forked dependencies"
   section in `CLAUDE.md`.
3. Run `just check`.
4. Delete the `tednaleid/zig-tree-sitter` repository on GitHub.

Opening a pull request upstream with the fork's one commit would speed this
up. Nothing has been filed.

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

## Remaining

- Drop the fork, as described above.
- zig-toml and zig-clap are pinned to master commits because neither has a
  tagged 0.17 release. Prefer a tag when one exists. zig-clap master now
  requires 0.18-dev; the newest commit that still supports 0.17 is `f136e02`.
- `mise uninstall zig@0.16.0` and remove `~/.local/zig/0.17.0`. Neither is
  needed now that Homebrew ships 0.17.0.

## Deprecations not yet addressed

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
