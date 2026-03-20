# veer — Product Requirements Document

## What is veer?

**veer** is a fast CLI tool that acts as a PreToolUse hook for Claude Code. It intercepts tool calls before execution, evaluates them against user-defined rules, and either rewrites, warns, or denies them — emitting helpful redirect messages so the agent self-corrects. Think of it as a linter for agent behavior: "never ask an LLM to do the job of a linter."

veer uses shell AST parsing rather than regex to decompose commands into structural components, dramatically reducing false positives. It stores statistics in SQLite, reads Claude Code's `settings.json` for permission context, and can mine JSONL session transcripts to bootstrap rules from real usage history.

---

## Design Principles

1. **Speed above all** — veer sits in the hot path of every tool call. Target: single-digit milliseconds for `veer check`. Benchmark on every PR.
2. **Red/green TDD** — every feature starts with a failing test. Tests are the spec.
3. **AST over regex** — parse shell commands into syntax trees via tree-sitter-bash. Match rules against AST nodes, not string patterns. Fall back to glob/literal matching for simple cases.
4. **Gentle redirection** — veer is not a security wall. It's a nudge. Messages should help the agent succeed, not just block it.
5. **Single binary, zero runtime dependencies** — one static binary for each platform. Ship via `brew install`, direct download, or build from source.

---

## Hook Protocol (Claude Code PreToolUse)

### Input (stdin)

Claude Code sends a JSON object on stdin when a PreToolUse hook fires:

```json
{
  "sessionId": "abc-123",
  "tool_name": "Bash",
  "tool_input": {
    "command": "python3 -c 'import os; os.system(\"rm -rf /\")'"
  }
}
```

For non-Bash tools, `tool_input` contains tool-specific fields:
```json
{
  "tool_name": "Write",
  "tool_input": {
    "file_path": "/etc/passwd",
    "content": "..."
  }
}
```

### Output Contract

| Outcome | Exit Code | stdout | stderr |
|---------|-----------|--------|--------|
| **Allow** (no matching rule) | 0 | empty | empty |
| **Rewrite** (transparent replacement) | 0 | `{"updatedInput": {"command": "just test"}}` | empty |
| **Warn** (block + redirect message) | 2 | empty | redirect message for agent |
| **Deny** (block + firm message) | 2 | empty | denial message for agent |

The distinction between warn and deny is semantic (for stats/config clarity), not protocol-level — both use exit code 2. The message tone differs: warn suggests alternatives, deny is firmer.

**Rewrite** is the most powerful action: it silently replaces the tool input before Claude Code executes it. The agent never sees the swap. This is ideal for cases like redirecting `pytest` → `just test` where the replacement is always correct.

**Warn** blocks execution and sends a message that Claude sees as feedback. Claude typically adjusts its next attempt based on this message. This is ideal for cases where the right action depends on context ("use `just run <script>` instead").

**Deny** blocks execution with a firmer message. Use for things that should never happen (`curl | bash`).

---

## File Layout

```
~/.config/veer/
├── config.toml          # Global config and rules
├── veer.db              # SQLite stats database
└── cache/               # Optional cached data

<project>/.veer/
├── config.toml          # Project-level config and rules (merged with global)
└── veer.db              # Project-level stats database
```

Project-level config is merged with global config. Project rules take precedence (can override global rules by ID). Project stats are separate from global stats.

---

## Commands

### `veer check`

The hot-path command called by the PreToolUse hook. Must be fast.

```
Usage: veer check [--config <path>] [--stats] [--dry-run]

Reads tool call JSON from stdin.
Evaluates against all active rules.
Outputs result via exit code + stdout/stderr.

Flags:
  --config <path>   Override config file location
  --stats           Record this check in the stats database (default: true)
  --dry-run         Print what would happen without affecting stats
```

**Algorithm:**
1. Read JSON from stdin, parse tool name and input
2. If tool is `Bash`, parse `command` field into AST via tree-sitter-bash
3. Walk the AST to extract: base commands, flags, arguments, pipeline structure, redirections, subshells, command substitutions
4. For each active rule (ordered by priority):
   a. Match rule against extracted AST components
   b. On first match: execute rule action (rewrite/warn/deny)
   c. Record match in stats DB (async, non-blocking)
5. If no rule matches: exit 0 (allow), record as approved in stats

For non-Bash tools (Read, Write, Edit, etc.), match against `tool_name` and `tool_input` fields directly using the rule's `tool` and `pattern` fields.

### `veer scan`

Bootstrap command that mines Claude Code JSONL transcripts to discover command patterns and suggest rules.

```
Usage: veer scan [--project <path>] [--global] [--since <duration>]
                 [--min-count <n>] [--output <format>] [--permissions]

Flags:
  --project <path>  Scan transcripts for a specific project (default: current dir)
  --global          Scan all projects in ~/.claude/projects/
  --since <dur>     Only scan sessions newer than this (e.g., "30d", "1w")
  --min-count <n>   Only show commands seen at least N times (default: 3)
  --output <fmt>    Output format: "table" (default), "toml" (generates rule stubs)
  --permissions     Cross-reference against Claude Code settings.json
```

**What it does:**
1. Finds JSONL files in `~/.claude/projects/<encoded-path>/`
2. Streams each file line-by-line, extracts `tool_use` content blocks where `name == "Bash"`
3. Parses each `command` field via tree-sitter-bash to extract the base command(s)
4. Aggregates: command frequency, common flag patterns, pipeline patterns
5. If `--permissions`: reads `~/.claude/settings.json`, classifies each command as allowed/denied/would-prompt
6. Outputs a summary table or TOML rule stubs

**Example output (table):**
```
Command         Count  Last Seen    Permission   Suggestion
─────────────────────────────────────────────────────────────
pytest          147    2h ago       denied       → just test
python3         89     4h ago       denied       → just run
chmod +x        34     1d ago       allowed      (no rule needed)
curl | bash     3      5d ago       would-prompt → deny + warn
npm test        67     3h ago       allowed      → just test
uvx ruff        23     1d ago       denied       → just lint
```

**Example output (toml):**
```toml
# Auto-generated by veer scan on 2026-03-20
# Review and customize before adding to your config

[[rule]]
id = "use-just-test"
name = "Use just test instead of pytest"
action = "rewrite"
rewrite_to = "just test"
message = "Use `just test` instead of running pytest directly."
# Seen 147 times in last 30 days. Currently denied in settings.json.
[rule.match]
command = "pytest"

[[rule]]
id = "no-curl-pipe-bash"
name = "Block curl piped to bash"
action = "deny"
message = "Piping curl to bash is not permitted. Download the script first and review it."
# Seen 3 times in last 30 days.
[rule.match]
pipeline_contains = ["curl", "bash"]
```

### `veer install`

Registers veer as a PreToolUse hook in Claude Code's settings.

```
Usage: veer install [--project] [--global] [--force] [--uninstall]

Flags:
  --project   Install hook in .claude/settings.json for current project (default)
  --global    Install hook in ~/.claude/settings.json for all projects
  --force     Overwrite existing veer hook if present
  --uninstall Remove the veer hook
```

**What it writes to settings.json:**
```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "/usr/local/bin/veer check"
          }
        ]
      }
    ]
  }
}
```

### `veer add`

Add a new rule to the config.

```
Usage: veer add [--id <id>] [--action <action>] [--command <cmd>]
               [--message <msg>] [--rewrite-to <cmd>] [--project] [--global]
               [--priority <n>] [--pattern <pat>]

If flags are omitted, runs interactively with prompts.
```

**Example:**
```bash
veer add --action rewrite --command pytest --rewrite-to "just test" \
  --message "Use just test instead of running pytest directly."
```

### `veer list`

Display current rules with optional stats.

```
Usage: veer list [--stats] [--project] [--global] [--all] [--format <fmt>]
```

**Example output:**
```
Rules (project + global merged):

  ID                  Action   Command/Pattern       Message                              Hits  Last Hit
  ──────────────────────────────────────────────────────────────────────────────────────────────────────
  use-just-test       rewrite  pytest                Use `just test` instead               47   2m ago
  use-just-run        warn     python3               Use `just run` instead                23   1h ago
  no-curl-pipe-bash   deny     pipeline:curl|bash    Don't pipe curl to bash                2   3d ago
  no-rm-rf            warn     rm -rf                Use `trash` instead of rm -rf          0   never
  ↳ global            warn     chmod +x              Check if chmod is needed               1   2d ago
```

### `veer remove`

Remove a rule by ID.

```
Usage: veer remove <rule-id> [--project] [--global]
```

### `veer stats`

Display usage statistics and suggest new rules.

```
Usage: veer stats [--project] [--global] [--since <duration>]
                  [--suggest] [--top <n>] [--reset]
```

**What it shows:**
- Rule hit counts (which rules are firing, which are dormant)
- Top denied commands
- Top approved commands (passed through with no rule match)
- Dormant rules (0 hits in time window — consider removing?)
- Suggested rules based on patterns (frequent denied commands that could have redirects)

**Example output:**
```
Stats for last 7 days:

  Checks: 1,247 total | 1,089 approved | 112 warned | 46 denied

  Top triggered rules:
    use-just-test        47 hits (rewrite)  — last: 2m ago
    echo-separator        8 hits (warn)     — last: 15m ago
    no-curl-pipe-bash     2 hits (deny)     — last: 3d ago

  Dormant rules (0 hits in 7d):
    no-rm-rf             — consider removing?

  Unmatched commands worth reviewing:
    chmod +x             34 occurrences — always approved
    npx tsc              12 occurrences — always approved
    docker compose up     8 occurrences — would be denied by settings

  Suggested rules:
    docker compose → just up  (8 occurrences, currently denied)
```

---

## Config Format (TOML)

### Structure

```toml
[settings]
stats = true                   # Enable stats collection
log_level = "warn"             # "debug", "info", "warn", "error"
claude_settings_path = ""      # Auto-detected if empty
claude_projects_path = ""      # Auto-detected if empty

[[rule]]
id = "unique-identifier"       # Required. Unique across all configs.
name = "Human-readable name"   # Required. Shown in `veer list`.
action = "rewrite"             # Required. "rewrite", "warn", or "deny".
priority = 10                  # Lower = evaluated first. Default: 100.
enabled = true                 # Default: true.
tool = "Bash"                  # Which tool. Default: "Bash".
message = "Redirect message"   # Required for warn/deny. Sent to agent.
rewrite_to = "just test"       # Required for rewrite. Replacement command.
tags = ["testing"]             # Optional. For organization.

[rule.match]
# Use one or more of these fields. All specified fields must match (AND logic).
command = "pytest"                         # Exact base command name
command_glob = "{ruff,uvx}"                # Glob pattern (brace expansion, wildcards)
command_regex = "python[23]?"              # Regex (escape hatch, use sparingly)
pipeline_contains = ["curl", "bash"]       # All listed commands must appear in pipeline
has_flag = "-rf"                           # Flag must be present
arg_pattern = '"---"'                      # Glob matched against arguments
```

### AST Match (Advanced)

For complex structural patterns:

```toml
[[rule]]
id = "no-nested-subst"
name = "Warn about nested command substitutions"
action = "warn"
message = "Nested command substitutions are hard to audit. Break into separate steps."
[rule.match]
ast = { has_node = "CmdSubst", min_depth = 2 }

[[rule]]
id = "long-pipeline"
name = "Warn about long pipelines"
action = "warn"
message = "Pipeline has many stages. Break into separate commands."
[rule.match]
ast = { has_node = "pipeline", min_count = 4 }

[[rule]]
id = "no-eval"
name = "Deny eval usage"
action = "deny"
priority = 1
message = "`eval` makes commands impossible to statically analyze."
[rule.match]
command = "eval"
```

### Example Complete Config

```toml
[settings]
stats = true
log_level = "warn"

# ── Rewrite rules (silent replacement) ─────────────────────

[[rule]]
id = "use-just-test"
name = "Redirect pytest to just test"
action = "rewrite"
priority = 10
rewrite_to = "just test"
message = "Use `just test` to run the test suite."
[rule.match]
command = "pytest"

[[rule]]
id = "use-just-lint"
name = "Redirect ruff/uvx to just lint"
action = "rewrite"
priority = 10
rewrite_to = "just lint"
message = "Use `just lint` instead of running ruff directly."
[rule.match]
command_glob = "{ruff,uvx}"

# ── Warn rules (block + helpful redirect) ──────────────────

[[rule]]
id = "use-just-run"
name = "Redirect python3 to just run"
action = "warn"
priority = 10
message = "Don't run Python scripts directly. Use `just run <script>` instead, which runs in the project's virtual environment."
[rule.match]
command = "python3"

[[rule]]
id = "echo-separator-in-pipeline"
name = "Warn about echo separators"
action = "warn"
priority = 50
message = "Avoid using `echo '---'` or similar as separators in command chains — they trigger permission flag warnings. Use separate commands instead."
[rule.match]
command = "echo"
arg_pattern = '"---"'

[[rule]]
id = "use-trash-not-rm"
name = "Suggest trash instead of rm -rf"
action = "warn"
priority = 50
message = "Use `trash` instead of `rm -rf` for safer file deletion."
[rule.match]
command = "rm"
has_flag = "-rf"

[[rule]]
id = "no-chmod-exec"
name = "Warn about unnecessary chmod +x"
action = "warn"
priority = 100
message = "Check if `chmod +x` is really needed. If running via `just`, the justfile handles execution."
[rule.match]
command = "chmod"
has_flag = "+x"

# ── Deny rules (firm block) ───────────────────────────────

[[rule]]
id = "no-curl-pipe-bash"
name = "Block curl piped to bash"
action = "deny"
priority = 1
message = "Piping curl to bash is not permitted. Download the script first, review it, then execute."
[rule.match]
pipeline_contains = ["curl", "bash"]

[[rule]]
id = "no-curl-pipe-sh"
name = "Block curl piped to sh"
action = "deny"
priority = 1
message = "Piping curl to sh is not permitted. Download the script first, review it, then execute."
[rule.match]
pipeline_contains = ["curl", "sh"]

[[rule]]
id = "no-eval"
name = "Deny eval usage"
action = "deny"
priority = 1
message = "`eval` makes commands impossible to statically analyze. Restructure to use explicit commands."
[rule.match]
command = "eval"
```

### Config Merging Rules

When both project and global configs exist:
1. `[settings]` from project config overrides global (per-field)
2. Rules are merged by ID — a project rule with the same ID as a global rule replaces it entirely
3. Rules from both sources are sorted by priority (lower first) for evaluation
4. A project rule can disable a global rule by setting `enabled = false` with the same ID

---

## CommandInfo (AST Extraction Output)

This is the core data structure that rules match against. After parsing a shell command through tree-sitter-bash, the AST is walked to produce this:

```
CommandInfo:
  raw: string                    # Original command string
  commands: []SingleCommand      # All commands in execution order
  pipeline_stages: []SingleCommand  # Commands in a pipeline (subset of commands)
  pipeline_length: int           # Number of pipeline stages
  has_subshell: bool
  has_command_subst: bool
  has_process_subst: bool
  has_redirection: bool
  has_background_job: bool
  has_eval: bool
  logical_operators: []string    # "&&", "||"
  max_nesting_depth: int

SingleCommand:
  name: string                   # Base command name (e.g., "grep")
  args: []string                 # All arguments
  flags: []string                # Flags only (e.g., ["-r", "--color"])
  positional: []string           # Non-flag arguments
```

**Examples:**

| Command | commands[].name | pipeline_length | has_command_subst |
|---------|----------------|-----------------|-------------------|
| `pytest tests/` | ["pytest"] | 0 | false |
| `cat f \| grep x \| wc -l` | ["cat", "grep", "wc"] | 3 | false |
| `echo $(rm -rf /)` | ["echo", "rm"] | 0 | true |
| `make && echo done` | ["make", "echo"] | 0 | false |
| `curl https://x \| bash` | ["curl", "bash"] | 2 | false |

---

## SQLite Schema

```sql
CREATE TABLE IF NOT EXISTS checks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    session_id TEXT,
    tool_name TEXT NOT NULL,
    command TEXT,
    base_command TEXT,
    rule_id TEXT,
    action TEXT NOT NULL,       -- "approve", "rewrite", "warn", "deny"
    message TEXT,
    rewritten_to TEXT,
    duration_us INTEGER
);

CREATE INDEX idx_checks_timestamp ON checks(timestamp);
CREATE INDEX idx_checks_rule_id ON checks(rule_id);
CREATE INDEX idx_checks_base_command ON checks(base_command);
CREATE INDEX idx_checks_action ON checks(action);

CREATE VIEW IF NOT EXISTS rule_stats AS
SELECT
    rule_id,
    action,
    COUNT(*) as hit_count,
    MAX(timestamp) as last_hit,
    MIN(timestamp) as first_hit
FROM checks
WHERE rule_id IS NOT NULL
GROUP BY rule_id, action;

CREATE VIEW IF NOT EXISTS unmatched_commands AS
SELECT
    base_command,
    COUNT(*) as count,
    MAX(timestamp) as last_seen,
    MIN(timestamp) as first_seen
FROM checks
WHERE rule_id IS NULL AND base_command IS NOT NULL
GROUP BY base_command
ORDER BY count DESC;
```

### Database Pragmas

Applied on connection open:
```sql
PRAGMA journal_mode=WAL;        -- Concurrent reads during writes
PRAGMA synchronous=NORMAL;      -- Safe enough for stats data
PRAGMA temp_store=MEMORY;       -- Temp tables in memory
PRAGMA cache_size=-2000;        -- 2MB cache
```

---

## Claude Code Integration

### settings.json Reader

Claude Code stores permission rules in `~/.claude/settings.json` (global) and `.claude/settings.json` (project). The relevant fields:

```json
{
  "allowedTools": ["Bash(grep:*)", "Bash(cat:*)", "Bash(just *)", "Read"],
  "deniedTools": ["Bash(python3:*)", "Bash(rm:*)"]
}
```

veer reads these to classify commands:
- **allowed**: command matches an `allowedTools` glob → no permission prompt needed
- **denied**: command matches a `deniedTools` glob → always blocked by Claude Code
- **prompt**: command matches neither → user will be prompted

This classification is used by `veer scan --permissions` and `veer stats --suggest` to identify commands that are frequently denied and could benefit from veer redirect rules.

### JSONL Transcript Format

Session transcripts at `~/.claude/projects/<encoded-path>/<session-uuid>.jsonl` contain one JSON object per line. For veer's purposes, we extract:

- **Bash commands**: `type == "assistant"` records where `message.content[]` contains `{"type": "tool_use", "name": "Bash", "input": {"command": "..."}}` blocks
- **Timestamps**: ISO 8601 in the `timestamp` field
- **Session ID**: in the `sessionId` field

Key parsing considerations:
- Lines can be malformed — skip gracefully
- Files can be very large (multi-MB) — stream line-by-line, never load full file
- Compaction boundaries (`type: "system", subtype: "compact_boundary"`) reset context — handle for accurate session scoping
- Non-Bash tool_use blocks (Read, Write, Edit) should be skipped for command analysis

---

## Rule Matching Semantics

### Match Types

| Field | Matches Against | Description |
|-------|----------------|-------------|
| `command` | `SingleCommand.name` | Exact base command name |
| `command_glob` | `SingleCommand.name` | Glob with brace expansion and wildcards |
| `command_regex` | `SingleCommand.name` | Regex (escape hatch) |
| `pipeline_contains` | All `pipeline_stages[].name` | All listed commands appear in pipeline |
| `has_flag` | `SingleCommand.flags` | Specific flag is present |
| `arg_pattern` | `SingleCommand.args` | Glob matched against arguments |
| `ast` | `CommandInfo` structural properties | Match node types, depth, count |
| `tool` | `tool_name` from hook input | Match non-Bash tools |

### Evaluation Rules

1. All match fields within a rule use **AND logic** — every specified field must match
2. Rules are evaluated in **priority order** (lower priority number = evaluated first)
3. **First match wins** — evaluation stops at the first matching rule
4. If **no rule matches**, the tool call is approved (exit 0, empty output)
5. A rule with `tool = "Bash"` (default) matches any `SingleCommand` in the parsed AST — it checks every command in a pipeline, subshell, or command chain

### Matching Against Pipelines and Compound Commands

For a command like `curl https://example.com | tee log.txt | bash`:
- `command = "curl"` matches (curl is one of the commands)
- `command = "bash"` matches (bash is one of the commands)
- `pipeline_contains = ["curl", "bash"]` matches (both appear in pipeline stages)
- `pipeline_contains = ["curl", "python"]` does NOT match (python not present)

For `make && echo "done" || echo "failed"`:
- `command = "make"` matches
- `command = "echo"` matches
- The logical operators `&&` and `||` are recorded in `logical_operators`

For `echo $(rm -rf /)`:
- `command = "rm"` matches (found inside command substitution)
- `has_flag = "-rf"` with `command = "rm"` matches
- `has_command_subst` is true

---

## Performance Targets

| Operation | Target |
|-----------|--------|
| `veer check` (10 rules, simple command) | < 5ms |
| `veer check` (50 rules, complex pipeline) | < 15ms |
| JSONL parse rate | > 10,000 lines/sec |
| Config load | < 2ms |
| SQLite stats write | non-blocking (must not add to check latency) |
| Binary size | < 5MB |

Benchmark in CI. Fail the build if `veer check` exceeds 20ms for the standard benchmark suite.

---

## Open Questions / Future Work

- **Rule sharing/import:** `veer import <url>` for community rule packs?
- **Justfile-aware rules:** Auto-discover `just` recipes and generate redirect rules for their underlying commands?
- **Watch mode:** `veer watch` that tails JSONL in real-time and shows a live dashboard?
- **Agent-agnostic hooks:** v2 could support Cline, Aider, etc. via a generic stdin/stdout protocol
- **Rule conditions:** More complex logic (e.g., "deny python3 UNLESS it's in a just recipe")
- **`veer init`:** Interactive onboarding that runs `veer scan`, suggests rules, writes config, and runs `veer install` in one flow
