# Implementation Spec: veer - Stage 5: Management CLI + Install

**Contract**: `docs/spec/contract.md`
**References**: `docs/spec/veer-prd.md` (command specs, output examples), `docs/spec/veer-spec.md` (display module)
**Depends on**: Stage 2 (config), Stage 4 (storage for stats display)
**Estimated Effort**: M

## Technical Approach

This stage implements the user-facing commands for managing veer rules and registering the hook with Claude Code. Each command is a separate module in `src/cli/`. Display formatting (tables, colors) gets its own module in `src/display/`.

All commands (except `check`) are management operations -- they're not in the hot path, so performance is less critical than correctness and usability.

`veer add` is flag-based only for v1 (no interactive mode). It appends a rule to the TOML config file.

## Feedback Strategy

**Inner-loop command**: `zig build test`
**Playground**: Test blocks in each CLI module + display modules. Integration tests verify TOML file modification and settings.json modification.
**Why this approach**: Each command is independently testable. The most complex logic is in install (modifying settings.json) and add (modifying TOML), which need careful file I/O tests.

## File Changes

### New Files

| File Path | Purpose |
|-----------|---------|
| `src/cli/install.zig` | Register/unregister veer as Claude Code PreToolUse hook |
| `src/cli/add.zig` | Add a rule to config.toml via CLI flags |
| `src/cli/remove.zig` | Remove a rule by ID from config.toml |
| `src/cli/list.zig` | Display current rules with optional stats |
| `src/cli/stats.zig` | Display usage statistics |
| `src/display/table.zig` | Column-aligned table rendering |
| `src/display/color.zig` | ANSI color helpers (with NO_COLOR support) |

### Modified Files

| File Path | Changes |
|-----------|---------|
| `src/main.zig` | Add dispatch for install, add, remove, list, stats commands |
| `build.zig` | Add new modules to test list |

## Implementation Details

### veer install (src/cli/install.zig)

From `docs/spec/veer-prd.md` lines 177-208.

```
Usage: veer install [--project] [--global] [--force] [--uninstall]
```

**What it does:**
1. Determine target: `.claude/settings.json` (project, default) or `~/.claude/settings.json` (global)
2. Read existing settings.json (create if doesn't exist)
3. Parse as JSON
4. Check if a veer hook already exists in `hooks.PreToolUse`
5. If exists and not `--force`: print message and exit
6. If `--uninstall`: remove the veer hook entry, write back
7. Otherwise: add the hook entry, write back

**Hook entry to write** (from `docs/spec/veer-prd.md` lines 193-207):
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "veer check"
          }
        ]
      }
    ]
  }
}
```

Use the actual path to the veer binary (resolve via `std.fs.selfExePath()` or similar). Merge with existing hooks -- don't overwrite other PreToolUse hooks.

**Feedback loop**:
- **Playground**: Test blocks operating on temp directories with mock settings.json files
- **Experiment**: Install to temp dir, verify JSON output. Install twice without force (should warn). Uninstall, verify hook removed. Install alongside existing hooks.
- **Check command**: `zig build test`

### veer add (src/cli/add.zig)

From `docs/spec/veer-prd.md` lines 210-226.

```
Usage: veer add --action <action> --command <cmd> [--id <id>] [--name <name>]
               [--message <msg>] [--rewrite-to <cmd>] [--priority <n>]
               [--project] [--global]
```

**What it does:**
1. Parse CLI flags (use zig-clap)
2. Generate ID from command name if not provided (e.g., "use-just-test")
3. Generate name from action + command if not provided
4. Validate rule (same validation as config loading)
5. Read existing config.toml
6. Check for duplicate ID
7. Append rule as TOML to config file
8. Print confirmation

**TOML serialization**: Write the rule as a `[[rule]]` block appended to the config file. Format manually rather than using a TOML serializer -- it's straightforward string formatting and gives control over comments/formatting.

### veer remove (src/cli/remove.zig)

From `docs/spec/veer-prd.md` lines 249-255.

```
Usage: veer remove <rule-id> [--project] [--global]
```

Read config, find rule by ID, remove it, write back. If rule not found, print error message and exit 1.

**Implementation note**: Removing from TOML while preserving formatting is non-trivial. Approach: parse the TOML to find the rule, then use line-based removal (find the `[[rule]]` block with matching id, remove lines until the next `[[rule]]` or EOF). Alternatively, re-serialize the entire config -- simpler but loses comments.

### veer list (src/cli/list.zig)

From `docs/spec/veer-prd.md` lines 228-247.

```
Usage: veer list [--stats] [--project] [--global] [--all]
```

Load merged config. Display rules in a table. If `--stats`, also show hit count and last hit from the store.

**Output format** (from PRD):
```
Rules (project + global merged):

  ID                  Action   Command/Pattern       Message                              Hits  Last Hit
  -----
  use-just-test       rewrite  pytest                Use `just test` instead               47   2m ago
  no-curl-pipe-bash   deny     pipeline:curl|bash    Don't pipe curl to bash                2   3d ago
```

### veer stats (src/cli/stats.zig)

From `docs/spec/veer-prd.md` lines 257-294.

```
Usage: veer stats [--since <duration>] [--top <n>] [--reset]
```

Query the store for:
- Total checks, approved/warned/denied/rewritten counts
- Top triggered rules (by hit count)
- Dormant rules (0 hits in time window)
- Top unmatched commands (passed through with no rule)

`--reset`: Delete all stats data (after confirmation).

**Duration parsing**: Parse strings like "7d", "30d", "1w", "24h" into millisecond offsets.

### Display Module (src/display/table.zig, color.zig)

**table.zig**: Simple column-aligned table rendering (~100 lines).
- Accept column headers and rows
- Auto-calculate column widths from content
- Render with consistent spacing

**color.zig**: ANSI color helpers.
- Check `NO_COLOR` env var and `isatty()` -- disable colors if either indicates no color support
- Functions: `bold()`, `dim()`, `red()`, `green()`, `yellow()`, `reset()`
- Each returns the escape sequence string (or empty string if no color)

### main.zig Updates

Add dispatch for all new commands:
```zig
if (std.mem.eql(u8, command, "check")) { ... }
else if (std.mem.eql(u8, command, "install")) { ... }
else if (std.mem.eql(u8, command, "add")) { ... }
else if (std.mem.eql(u8, command, "remove")) { ... }
else if (std.mem.eql(u8, command, "list")) { ... }
else if (std.mem.eql(u8, command, "stats")) { ... }
else { printUsage(); }
```

Consider using zig-clap for top-level subcommand parsing.

## Testing Requirements

### Install Tests
- Install to empty settings.json -> creates hooks entry
- Install to settings.json with existing hooks -> preserves existing hooks, adds veer
- Install when veer hook already exists (no --force) -> prints warning, no change
- Install with --force when hook exists -> replaces hook
- Uninstall -> removes veer hook entry, preserves other hooks
- Install to non-existent file -> creates file with hook

### Add Tests
- Add a rewrite rule via flags -> TOML appended to config
- Add with duplicate ID -> error message
- Add without required fields -> validation error
- Add with auto-generated ID -> ID derived from command name

### Remove Tests
- Remove existing rule -> rule removed from TOML
- Remove non-existent rule -> error message

### List Tests
- List with rules -> formatted table output
- List with --stats -> includes hit counts
- List with no rules -> "No rules configured" message

### Stats Tests
- Stats with data -> correct counts
- Stats with --since filter -> only includes recent data
- Stats with no data -> "No check data recorded" message

### Display Tests
- Table with varying column widths -> correct alignment
- Color disabled when NO_COLOR set -> empty escape sequences

## Error Handling

| Scenario | Handling |
|----------|----------|
| settings.json not valid JSON | Error message, exit 1 |
| Config file not writable | Error message, exit 1 |
| Rule ID not found (remove) | Error message, exit 1 |
| No stats database | "No check data recorded yet" message |

## Validation Commands

```bash
zig build test

# Manual tests
zig build run -- install --project
zig build run -- add --action rewrite --command pytest --rewrite-to "just test" --message "Use just test."
zig build run -- list
zig build run -- list --stats
zig build run -- remove use-just-test
zig build run -- stats
zig build run -- install --uninstall
```
