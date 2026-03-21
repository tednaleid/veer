# Remaining Work

What's left after the initial 7-stage implementation. Organized by priority.

## 1. Test Hardening: rule.match

The matching engine is veer's most critical code path. Current test coverage has significant gaps.

### Missing test coverage

| Match type | Current tests | Gaps |
|-----------|--------------|------|
| `command` | 2 (exact match, no match) | Matching inside pipelines, subshells, command substitution |
| `command_glob` | 2 (brace expansion, wildcard) | `?` single char, nested braces, empty pattern |
| `command_regex` | 1 (anchored `^python[23]?$`) | Unanchored patterns, `.` wildcard, `+` quantifier, alternation `(a\|b)`, character ranges `[a-z]` |
| `pipeline_contains` | 1 (2-stage match + negative) | 3+ stage pipeline (e.g., `curl \| tee \| bash`), single-command pipeline, duplicate commands in pipeline |
| `has_flag` | 1 (with `command` AND) | `has_flag` alone without `command`, combined flags (`-rf` vs `-r -f`), long flags (`--force`) |
| `arg_pattern` | **0** | Basic arg matching, glob in arg pattern, quoted args, no-match case |
| `ast` | **0** | `has_node` with each node type, `min_depth`, `min_count`, combinations |
| AND logic | 1 (command + has_flag) | command + glob, command + arg_pattern, three-field combinations, all-fields-miss edge case |

### Fuzz testing

Zig 0.15 has built-in fuzz testing via `std.testing.fuzz()`. Add fuzz tests for:

- **Shell parser**: Feed random byte sequences to `shell.parse()`, verify it never panics and always returns valid CommandInfo or an error. This is the most important fuzz target since it wraps tree-sitter C code.
- **Matcher**: Feed random CommandInfo + Rule combinations to `matchRule()`, verify no panics.
- **Glob matcher**: Feed random pattern + text to `globMatch()`, verify no panics or infinite loops.
- **Regex matcher**: Feed random patterns to `regexMatch()`, verify no panics (the C wrapper should handle bad patterns gracefully).

Run with: `zig build --fuzz`

Add a Justfile recipe: `just fuzz`

## 2. Simplification: Remove priority field

The `priority` field in rules adds complexity without clear value.

**Current behavior**: Rules are sorted by priority (lower first) after merging project + global configs. First match wins.

**Problem**: Priority is redundant. Project rules already come first in the merge. Within each config, definition order is natural and predictable. Users have to think about a numeric ordering system when they could just reorder rules in the file.

**Proposed change**: Remove the `priority` field entirely. Evaluate rules in definition order. Project rules always come first (they override global rules with the same ID, and are evaluated before non-overridden global rules).

**Migration**: The `priority` field becomes a no-op if present in existing configs (zig-toml ignores unknown fields, or we keep it as an ignored field for backwards compatibility).

**Files to change**: `rule.zig` (remove field), `config.zig` (remove sort), `engine.zig` (already evaluates in slice order), `README.md`, test fixtures.

## 3. Implementation gaps

### loadMerged() -- auto-discover configs

Currently `veer check` requires `--config <path>`. It should auto-discover:

1. `.veer/config.toml` (project, relative to cwd)
2. `~/.config/veer/config.toml` (global, or `$XDG_CONFIG_HOME/veer/config.toml`)

Merge them: project rules first, global rules that aren't overridden second. If neither exists, run with no rules (allow everything).

This is needed for real-world usability -- the hook protocol just calls `veer check` with no arguments.

**Files**: `config.zig` (add loadMerged), `main.zig` (use loadMerged as default in runCheck, runList)

### SqliteStore wiring

The store layer works but `main.zig` passes `null` to the engine. Wire it up:

1. After loading config, if `settings.stats` is true, open SqliteStore at `.veer/veer.db`
2. Pass store to `engine.check()`
3. Close store on exit

**Files**: `main.zig` (runCheck)

### veer scan auto-discovery

Currently requires `--transcript <path>`. Should auto-find transcripts:

1. Encode current working directory path (replace `/` with `-`, prepend `-`)
2. Look in `~/.claude/projects/<encoded-path>/`
3. Parse all `*.jsonl` files in that directory
4. For `--global`, iterate all subdirectories under `~/.claude/projects/`

**Files**: `scan.zig`, `main.zig` (runScan)

### veer stats --reset

Delete all rows from the checks table. Confirm before deleting.

**Files**: `store.zig` (add reset to interface), `memory_store.zig`, `sqlite_store.zig`, `stats.zig`

## 4. Documentation updates

- Update stage spec files (1-7) to reference `reject` instead of `warn`/`deny`
- Update contract.md success criteria (check off completed items, update action names)
- Update veer-prd.md and veer-spec.md to reflect reject action (or mark them as historical/superseded by README.md)
