# Remaining Work

What's left after the schema v2 redesign. Organized by priority.

## 1. Fuzz Testing (Stage B)

Add fuzz tests using Zig 0.15 built-in `std.testing.fuzz()`:

- **Shell parser**: Feed random byte sequences to `shell.parse()`, verify no panics. Most important target (wraps tree-sitter C code).
- **Matcher**: Feed random CommandInfo + Rule combinations to `matchRule()`, verify no panics.
- **Glob matcher**: Feed random pattern + text to `globMatch()`, verify no panics or infinite loops.
- **Regex matcher**: Feed random patterns to `regexMatch()`, verify no panics.

Run with: `zig build --fuzz` / `just fuzz`

## 2. CLI Commands (Stage B)

- `veer test "<command>"` -- test a command against rules without crafting JSON.
- `veer validate` -- load config and report all validation errors.

## 3. Argument-Preserving Rewrites

`rewrite_to` currently does full string replacement only. For swapping a binary while keeping
args (e.g., `chmod 755 foo` -> `stat foo`), we need a mechanism like `rewrite_command = "stat"`
that replaces only the command name. This needs careful design around which flags to preserve.

## 4. Non-Bash Tool Matching

Currently non-Bash tools match on tool name only. Investigate what `tool_input` looks like
for each Claude Code tool:
- Write: file_path, content
- Read: file_path
- Edit: file_path, old_string, new_string
- Glob: pattern
- Grep: pattern, path

Many of these may benefit from the same matching rules (e.g., blocking Write to `.env` paths).
Worth investigating the full tool_input schema before designing.

## 5. Versioning Discipline

Pre-release at 0.1.0 so breaking changes are expected. Once shipped:
- Schema contract tests that fail on accidental breaking changes
- Clear semver discipline: breaking schema changes = major bump
- Migration path documentation for any breaking change
- Consider a schema version field in config.toml for forward compatibility

## 6. Implementation Gaps

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
