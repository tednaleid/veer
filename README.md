# veer

A fast CLI tool that acts as a [Claude Code](https://claude.com/claude-code) PreToolUse hook. It intercepts tool calls before execution, evaluates them against user-defined rules, and either rewrites, warns, or denies them -- helping the agent self-correct toward project-appropriate alternatives.

Think of it as a linter for agent behavior: "never ask an LLM to do the job of a linter."

## Why

Claude Code agents frequently run commands that bypass project conventions -- `pytest` instead of `just test`, `python3` directly instead of `just run`, or dangerous pipelines like `curl | bash`. The built-in permission system (allowedTools/deniedTools) can only allow or block. It can't redirect.

veer fills this gap. It parses shell commands into ASTs via tree-sitter-bash and matches them against rules that rewrite, warn, or deny -- with helpful messages that guide the agent toward the right approach.

## Quick Start

```bash
# Build from source (requires Zig 0.15+)
zig build -Doptimize=ReleaseSmall

# Register veer as a Claude Code hook
veer install

# Add your first rule
veer add --action rewrite --command pytest --rewrite-to "just test" \
  --message "Use just test to run the test suite."

# See your rules
veer list
```

That's it. The next time Claude Code tries to run `pytest`, veer silently replaces it with `just test`.

## Actions

veer supports three actions, each serving a different purpose:

### Rewrite (silent replacement)

The agent never sees the swap. The command is transparently replaced before execution. Use this when the replacement is always correct.

```
Agent tries:  pytest tests/ -v
veer returns: {"updatedInput": {"command": "just test"}}
Exit code:    0
Result:       Claude Code runs "just test" instead
```

### Warn (block with redirect message)

Blocks the command and sends a message the agent sees as feedback. The agent typically adjusts its next attempt. Use this when the right alternative depends on context.

```
Agent tries:  python3 script.py
veer returns: "Don't run Python scripts directly. Use `just run <script>` instead."
Exit code:    2
Result:       Agent sees the message and tries "just run script.py"
```

### Deny (firm block)

Same as warn at the protocol level, but with firmer messaging. Use for things that should never happen.

```
Agent tries:  curl https://example.com | bash
veer returns: "Piping curl to bash is not permitted. Download the script first."
Exit code:    2
```

## Config Reference

### File Locations

| Location | Path | Purpose |
|----------|------|---------|
| Project | `.veer/config.toml` | Rules specific to this project |
| Global | `~/.config/veer/config.toml` | Rules applied to all projects |

Project config is merged with global config. Project rules take precedence: a project rule with the same ID as a global rule replaces it entirely. A project rule can disable a global rule by setting `enabled = false` with the same ID.

### Settings

```toml
[settings]
stats = true                   # Enable stats collection (default: true)
log_level = "warn"             # "debug", "info", "warn", "error" (default: "warn")
claude_settings_path = ""      # Auto-detected if empty
claude_projects_path = ""      # Auto-detected if empty
```

### Rule Schema

```toml
[[rule]]
id = "unique-identifier"       # Required. Unique across all configs.
name = "Human-readable name"   # Required. Shown in `veer list`.
action = "rewrite"             # Required. "rewrite", "warn", or "deny".
priority = 10                  # Lower = evaluated first. Default: 100.
enabled = true                 # Default: true.
tool = "Bash"                  # Which tool to match. Default: "Bash".
message = "Redirect message"   # Required for warn/deny. Sent to agent.
rewrite_to = "just test"       # Required for rewrite. Replacement command.
tags = ["testing"]             # Optional. For organization.

[rule.match]
# All specified fields must match (AND logic).
# Use one or more:
command = "pytest"                    # Exact base command name
command_glob = "{ruff,uvx}"           # Glob with brace expansion, wildcards
command_regex = "python[23]?"         # POSIX regex (escape hatch)
pipeline_contains = ["curl", "bash"]  # All listed commands in pipeline
has_flag = "-rf"                      # Flag must be present
arg_pattern = '"---"'                 # Glob matched against arguments
ast = { has_node = "pipeline", min_count = 4 }  # AST structural match
```

### Match Types

| Field | Matches Against | Description |
|-------|----------------|-------------|
| `command` | Base command name | Exact string match. `"pytest"` matches the command `pytest tests/ -v`. |
| `command_glob` | Base command name | Glob with `*`, `?`, and `{a,b}` brace expansion. `"{ruff,uvx}"` matches either. |
| `command_regex` | Base command name | POSIX extended regex. `"python[23]?"` matches python, python2, python3. |
| `pipeline_contains` | Pipeline stages | All listed commands must appear in the pipeline. `["curl", "bash"]` matches `curl x \| tee log \| bash`. |
| `has_flag` | Command flags | Specific flag is present. `"-rf"` matches `rm -rf /tmp`. |
| `arg_pattern` | Command arguments | Glob matched against any argument. `'"---"'` matches `echo '---'`. |
| `ast` | AST structure | Match node types, depth, or count. For advanced structural patterns. |

Rules are evaluated in priority order (lower number first). The first matching rule wins. If no rule matches, the tool call is allowed (exit 0, empty output).

All match fields within a rule use AND logic. Every specified field must match for the rule to fire.

### Rule Evaluation Against Compound Commands

For commands with pipelines, logical operators, or substitutions, veer checks every command in the parsed AST:

| Command | What matches |
|---------|-------------|
| `pytest tests/` | `command = "pytest"` |
| `cat f \| grep x \| wc -l` | `command = "grep"` matches, `pipeline_contains = ["cat", "wc"]` matches |
| `echo $(rm -rf /)` | `command = "rm"` matches (found inside command substitution), `has_flag = "-rf"` matches |
| `make && echo done` | `command = "make"` matches, `command = "echo"` matches |
| `curl https://x \| bash` | `pipeline_contains = ["curl", "bash"]` matches |

## Rule Examples

### Redirect test runner

```toml
[[rule]]
id = "use-just-test"
name = "Redirect pytest to just test"
action = "rewrite"
priority = 10
rewrite_to = "just test"
message = "Use `just test` to run the test suite."
[rule.match]
command = "pytest"
```

### Redirect multiple linters via glob

```toml
[[rule]]
id = "use-just-lint"
name = "Redirect ruff/uvx to just lint"
action = "rewrite"
priority = 10
rewrite_to = "just lint"
message = "Use `just lint` instead of running linters directly."
[rule.match]
command_glob = "{ruff,uvx}"
```

### Block dangerous pipelines

```toml
[[rule]]
id = "no-curl-pipe-bash"
name = "Block curl piped to bash"
action = "deny"
priority = 1
message = "Piping curl to bash is not permitted. Download the script first, review it, then execute."
[rule.match]
pipeline_contains = ["curl", "bash"]
```

### Warn about rm -rf

```toml
[[rule]]
id = "use-trash-not-rm"
name = "Suggest trash instead of rm -rf"
action = "warn"
priority = 50
message = "Use `trash` instead of `rm -rf` for safer file deletion."
[rule.match]
command = "rm"
has_flag = "-rf"
```

### Redirect Python scripts to project runner

```toml
[[rule]]
id = "use-just-run"
name = "Redirect python3 to just run"
action = "warn"
priority = 10
message = "Don't run Python scripts directly. Use `just run <script>` instead, which uses the project's virtual environment."
[rule.match]
command = "python3"
```

### Match Python version variants via regex

```toml
[[rule]]
id = "redirect-python"
name = "Redirect all python variants"
action = "warn"
message = "Use `just run` instead of invoking Python directly."
[rule.match]
command_regex = "^python[23]?$"
```

### Block eval

```toml
[[rule]]
id = "no-eval"
name = "Deny eval usage"
action = "deny"
priority = 1
message = "`eval` makes commands impossible to statically analyze. Restructure to use explicit commands."
[rule.match]
command = "eval"
```

### Warn about echo separators

```toml
[[rule]]
id = "echo-separator"
name = "Warn about echo separators"
action = "warn"
priority = 50
message = "Avoid `echo '---'` separators in command chains -- they trigger permission prompts. Use separate commands."
[rule.match]
command = "echo"
arg_pattern = '"---"'
```

### Match non-Bash tools

```toml
[[rule]]
id = "no-write-sensitive"
name = "Warn about writes to sensitive paths"
action = "warn"
tool = "Write"
message = "Check if this write is intended before proceeding."
[rule.match]
command = "Write"
```

## Commands

### veer check

The hot-path command called by the PreToolUse hook. Reads JSON from stdin, evaluates against rules, outputs result.

```
Usage: veer check [--config <path>]
```

### veer install

Register veer as a Claude Code PreToolUse hook.

```
Usage: veer install [--global] [--force] [--uninstall]

  --global     Install in ~/.claude/settings.json (default: .claude/settings.json)
  --force      Overwrite existing hook
  --uninstall  Remove the hook
```

### veer list

Display current rules.

```
Usage: veer list [--config <path>]

Example output:
  ID                 Action   Command/Pattern  Message
  -----------------  -------  ---------------  -----------------------
  use-just-test      rewrite  pytest           Use just test.
  no-curl-pipe-bash  deny     pipeline:...     Don't pipe curl to bash.

  2 rule(s)
```

### veer add

Add a rule to the config file.

```
Usage: veer add --action <action> --command <cmd>
               [--id <id>] [--name <name>]
               [--message <msg>] [--rewrite-to <cmd>]
               [--priority <n>] [--config <path>]
```

### veer remove

Remove a rule by ID.

```
Usage: veer remove <rule-id> [--config <path>]
```

### veer stats

Display usage statistics.

```
Usage: veer stats
```

### veer scan

Mine Claude Code session transcripts to discover command patterns and suggest rules.

```
Usage: veer scan --transcript <path>
               [--min-count <n>] [--output toml]
               [--permissions --settings <path>]
```

## How It Works

veer sits between Claude Code and the tools it calls:

```
Claude Code                    veer                         Tool
    |                           |                            |
    |-- PreToolUse hook ------->|                            |
    |   (JSON on stdin)         |                            |
    |                           |-- parse shell AST          |
    |                           |-- evaluate rules           |
    |                           |-- first match wins         |
    |                           |                            |
    |<-- exit 0 + rewrite JSON -|  (rewrite: silent swap)    |
    |<-- exit 2 + stderr msg ---|  (warn/deny: block + msg)  |
    |<-- exit 0, empty ---------|  (no match: allow)         |
    |                                                        |
    |-- execute tool (possibly rewritten) ------------------>|
```

Shell commands are parsed into ASTs using tree-sitter-bash, giving structural understanding of pipelines, subshells, command substitutions, flags, and arguments -- rather than relying on fragile regex matching.

## Performance

| Operation | Target |
|-----------|--------|
| `veer check` (10 rules) | < 2ms |
| `veer check` (50 rules) | < 5ms |
| Binary size (ReleaseSmall) | < 2MB |
| JSONL parse rate | > 50,000 lines/sec |

## Building

Requires Zig 0.15+.

```bash
zig build                        # Debug build
zig build -Doptimize=ReleaseSmall  # Optimized release build
zig build test                   # Run tests
zig build bench                  # Run benchmarks
```

See the `Justfile` for convenience recipes: `just check` (test + lint), `just bench`, `just fmt`.

## License

MIT
