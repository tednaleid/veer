# Implementation Spec: veer - Stage 6: Transcript Mining (veer scan)

**Contract**: `docs/spec/contract.md`
**References**: `docs/spec/veer-prd.md` (scan command, settings reader, JSONL format), `docs/spec/veer-spec.md` (transcript parser, settings reader)
**Depends on**: Stage 1 (shell parser for command extraction), Stage 2 (config for TOML output)
**Estimated Effort**: M

## Technical Approach

`veer scan` mines Claude Code JSONL session transcripts to discover command patterns and suggest rules. This is the bootstrapping story: instead of writing rules from scratch, users run `scan` to see what their agent actually does, then generate rule stubs.

Three components:
1. **Transcript parser** -- streams JSONL files line-by-line, extracts Bash tool_use commands
2. **Settings reader** -- reads Claude Code's `settings.json` to classify commands as allowed/denied/would-prompt
3. **Scan command** -- orchestrates: find transcript files, parse them, aggregate results, output as table or TOML

Performance target: > 50,000 lines/sec for JSONL parsing. Stream line-by-line, never load full files into memory.

## Feedback Strategy

**Inner-loop command**: `zig build test`
**Playground**: Test blocks in transcript.zig and settings.zig, plus JSONL fixture files in `test/transcripts/`
**Why this approach**: The transcript parser is a streaming data transformation. Tests with fixture files validate extraction accuracy. Settings reader is straightforward JSON parsing.

## File Changes

### New Files

| File Path | Purpose |
|-----------|---------|
| `src/claude/transcript.zig` | JSONL stream parser: extract Bash commands from transcripts |
| `src/claude/settings.zig` | Claude Code settings.json reader + command classification |
| `src/cli/scan.zig` | `veer scan` command implementation |
| `test/transcripts/simple_session.jsonl` | Test fixture: basic session with Bash tool_use |
| `test/transcripts/mixed_tools.jsonl` | Test fixture: session with Bash + Read + Write tools |
| `test/transcripts/compacted_session.jsonl` | Test fixture: session with compaction boundaries |
| `test/settings/permissive.json` | Test fixture: settings.json with broad allowedTools |
| `test/settings/restrictive.json` | Test fixture: settings.json with many deniedTools |

### Modified Files

| File Path | Changes |
|-----------|---------|
| `src/main.zig` | Add dispatch for scan command |
| `build.zig` | Add new modules to test list |

## Implementation Details

### Transcript Parser (src/claude/transcript.zig)

Follow `docs/spec/veer-spec.md` lines 790-870.

```zig
const std = @import("std");

pub const BashCommand = struct {
    command: []const u8,
    timestamp: ?[]const u8,
    session_id: ?[]const u8,
};

/// Stream-parse a JSONL transcript, yielding Bash commands via callback.
/// Processes line-by-line. Never loads the full file into memory.
pub fn streamCommands(
    allocator: std.mem.Allocator,
    reader: anytype,
    callback: anytype, // fn(BashCommand) void
) !u64 {
    var count: u64 = 0;
    var line_buf: [1024 * 64]u8 = undefined; // 64KB line buffer

    while (reader.readUntilDelimiterOrEof(&line_buf, '\n')) |maybe_line| {
        const line = maybe_line orelse break;
        if (line.len == 0) continue;

        // Parse as JSON, skip malformed lines
        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch continue;
        defer parsed.deinit();

        // Extract: type == "assistant", content[].type == "tool_use",
        // name == "Bash", input.command
        // See docs/spec/veer-prd.md lines 586-598 for format details
        // ...

        count += 1;
    }
    return count;
}
```

**JSONL format** (from `docs/spec/veer-prd.md` lines 586-598):
- Each line is a JSON object
- Look for `type == "assistant"` records
- In `message.content[]`, find blocks where `type == "tool_use"` and `name == "Bash"`
- Extract `input.command` as the command string
- Extract `timestamp` and `sessionId` from the root object
- Skip malformed lines gracefully
- Handle compaction boundaries (`type: "system", subtype: "compact_boundary"`)

**Transcript file discovery**:
- Project transcripts: `~/.claude/projects/<encoded-path>/*.jsonl`
- The encoded path is derived from the project directory path
- For `--global`: iterate all directories under `~/.claude/projects/`

**Feedback loop**:
- **Playground**: JSONL fixtures in `test/transcripts/` + test blocks
- **Experiment**: Parse fixture with known commands, verify extraction count and command strings
- **Check command**: `zig build test`

### Settings Reader (src/claude/settings.zig)

From `docs/spec/veer-prd.md` lines 566-584.

```zig
const std = @import("std");

pub const Permission = enum {
    allowed,
    denied,
    prompt, // Would prompt the user
};

pub const SettingsReader = struct {
    allowed_tools: []const []const u8,
    denied_tools: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, path: []const u8) !SettingsReader {
        // Read and parse settings.json
        // Extract allowedTools and deniedTools arrays
    }

    /// Classify a command against Claude Code's permission rules.
    pub fn classify(self: SettingsReader, tool_name: []const u8, command: []const u8) Permission {
        // Check deniedTools first (e.g., "Bash(python3:*)")
        // Then allowedTools (e.g., "Bash(grep:*)", "Bash(just *)")
        // If neither matches: prompt
    }
};
```

**Glob matching for tool permissions**: Claude Code uses patterns like `Bash(grep:*)`, `Bash(just *)`. Parse these as: tool name in parens, then a glob pattern for the command. Match the base command against the glob.

**Feedback loop**:
- **Playground**: Test fixtures in `test/settings/` + test blocks
- **Experiment**: Classify known commands against permissive and restrictive settings, verify classification
- **Check command**: `zig build test`

### Scan Command (src/cli/scan.zig)

From `docs/spec/veer-prd.md` lines 114-175.

```
Usage: veer scan [--project <path>] [--global] [--since <duration>]
                 [--min-count <n>] [--output <format>] [--permissions]
```

**Algorithm:**
1. Find JSONL transcript files (project or global)
2. Stream each file through transcript parser
3. For each extracted command, parse via shell.parse() to get base command
4. Aggregate: command frequency, common flags, pipeline patterns
5. If `--permissions`: classify each command via settings reader
6. Filter by `--min-count` and `--since`
7. Output as table (default) or TOML rule stubs

**Table output** (from PRD lines 141-150):
```
Command         Count  Last Seen    Permission   Suggestion
-----
pytest          147    2h ago       denied       -> just test
python3         89     4h ago       denied       -> just run
curl | bash     3      5d ago       would-prompt -> deny + warn
```

**TOML output** (from PRD lines 152-175):
Generate `[[rule]]` stubs with comments showing frequency and permission status. The user reviews and customizes before adding to config.

**Feedback loop**:
- **Playground**: Test blocks using in-memory JSONL data and the scan pipeline
- **Experiment**: Feed fixture transcripts through scan, verify aggregated counts and output format
- **Check command**: `zig build test`

## Testing Requirements

### Transcript Parser Tests

Follow pattern from `docs/spec/veer-spec.md` lines 850-870.

- Extract 2 Bash commands from JSONL with 4 lines (2 Bash, 1 Read, 1 user) -> count=2
- Skip malformed JSON lines -> no crash, skip gracefully
- Handle empty lines -> skip
- Handle very long lines (>64KB) -> handle or skip without crash
- Handle compaction boundary lines -> skip gracefully
- Extract timestamps and session IDs correctly

### Settings Reader Tests

- Permissive settings: `grep` classified as `allowed`, unknown command as `prompt`
- Restrictive settings: `python3` classified as `denied`, `just test` as `allowed`
- Missing settings file -> return empty reader (all commands classify as `prompt`)
- Glob matching: `Bash(just *)` matches `just test`, `just run`; doesn't match `justfile`

### Scan Command Tests

- Scan fixture transcripts -> correct frequency counts
- `--min-count` filter -> excludes low-frequency commands
- `--output toml` -> valid TOML rule stubs
- `--permissions` -> includes permission classification column
- No transcripts found -> informative message

## Error Handling

| Scenario | Handling |
|----------|----------|
| JSONL file read error | Log warning, skip file, continue with remaining files |
| Malformed JSON line | Skip line, continue parsing |
| Settings file not found | Continue without permission classification |
| No transcript files found | Print informative message ("No session transcripts found...") |
| Shell parse failure for a command | Record command with "unparseable" marker, continue |

## Validation Commands

```bash
zig build test

# Manual: scan real transcripts (if Claude Code sessions exist)
zig build run -- scan
zig build run -- scan --output toml
zig build run -- scan --permissions --min-count 5
```
