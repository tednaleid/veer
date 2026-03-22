# veer

A fast CLI tool that acts as a [Claude Code](https://claude.com/claude-code) PreToolUse hook. It intercepts tool calls before execution, evaluates them against user-defined rules, and either rewrites or rejects them -- helping the agent self-correct toward project-appropriate alternatives.

Think of `veer` as a linter for the commands your agent wants to run. Rather than asking you repeatedly for permission to do something unsafe, `veer` can let the agent know that the command it is trying will not be approved and they should use an alternate path.

## Why

LLMs have been trained to use specific commands. It really wants to use raw `python3` or 

If don't want to live `--dangerously-skip-permissions` and are tired of repeatedly reminding claude to use your `just` or `make` commands, `veer` can help.

If you've gotten sick of approving `Command contains quoted characters in flag names`:

```
──────
 Bash command

   tail -5 README.md && echo "---" && tail -5 Justfile
   Test if echo separator triggers permission dialog

 Command contains quoted characters in flag names

 Do you want to proceed?
 ❯ 1. Yes
   2. No
```

`veer` can deny this command with a `PreToolUse` hook and let the agent know it should do something else. Here's a `veer` rule to automatically give instructions to the agent:

```
[[rule]]
id = "no-quoted-characters-in-flag-names"
message = "Command contains quoted characters in flag names. Run the commands directly."
[rule.match]
command = "echo"
arg = "---"
```

Claude Code agents frequently run commands that bypass project conventions. I often use `justfile`s to hold safe, pre-approved commands that I'm ok with `claude` running. `veer` remind Claude that these files exist and should be used.

examples:
- don't use `pytest`, use `just test`
- `python3` directly instead of `just run`, or dangerous pipelines like `curl | bash`. The built-in permission system (allowedTools/deniedTools) can only allow or block. It can't redirect.

veer fills this gap. It parses shell commands into ASTs via tree-sitter-bash and matches them against rules that rewrite or reject -- with helpful messages that guide the agent toward the right approach.

It turns out that `claude` is great at creating these rules. Just let it know about `veer` and ask it to write rules for everything in your just/make files.

## Quick Start

```bash
# Build and install (requires Zig 0.15+)
just install    # builds release binary, symlinks to ~/.local/bin/veer

# Register veer as a Claude Code hook
veer install

# Add your first rule
veer add --action rewrite --command pytest --rewrite-to "just test" \
  --message "Use just test to run the test suite."

# See your rules (auto-discovers .veer/config.toml)
veer list

# Test a command against your rules
veer test "pytest tests/"
```

That's it. The next time Claude Code tries to run `pytest`, veer silently replaces it with `just test`.

See [examples/](examples/) for a full demo of all match types.

## Actions

veer supports two actions:

### Rewrite (silent replacement)

The agent never sees the swap. The command is transparently replaced before execution. Use this when the replacement is always correct.

```
Agent tries:  pytest tests/ -v
veer returns: {"updatedInput": {"command": "just test"}}
Exit code:    0
Result:       Claude Code runs "just test" instead
```

### Reject (block with redirect message)

Blocks the command and sends a message the agent sees as feedback. The agent typically adjusts its next attempt. The message field controls the tone -- use it to suggest alternatives or explain why.

```
Agent tries:  python3 script.py
veer returns: "Don't run Python scripts directly. Use `just run <script>` instead."
Exit code:    2
Result:       Agent sees the message and tries "just run script.py"
```

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
name = "Human-readable name"   # Optional. Defaults to id. Shown in `veer list`.
action = "reject"              # Optional. Inferred from rewrite_to if omitted.
enabled = true                 # Default: true.
tool = "Bash"                  # Which tool to match. Default: "Bash".
message = "Redirect message"   # Required for reject. Sent to agent.
rewrite_to = "just test"       # Required for rewrite. Implies action = "rewrite".
tags = ["testing"]             # Optional. For organization.

[rule.match]
# All specified fields must match (AND logic).
# Base fields are glob-aware: "py*" matches pytest, python3.
# No wildcards = exact match.

# Command name matching (per-command)
command = "pytest"                    # Glob match on base command name
command_any = ["ruff", "uvx"]         # OR: any of these commands
command_regex = "python[23]?"         # POSIX regex (escape hatch)

# Command presence (cross-command)
command_all = ["curl", "bash"]        # AND: all must exist in AST

# Flag matching (no dash prefix, smart combined flag handling)
flag = "f"                            # Matches -f, -rf, -fr, -xvf
flag_any = ["f", "force"]             # OR: any of these flags
flag_all = ["r", "f"]                 # AND: all on same command

# Arg matching (positional args only, glob-aware)
arg = "*.py"                          # Glob match on any positional arg
arg_any = ["test", "spec"]            # OR: any arg matches
arg_all = ["src/", "README.md"]       # AND: all present
arg_regex = "\\.py$"                  # Regex on positional args

# Whole-input matching
raw_regex = "curl.*\\|.*bash"         # Regex against entire command string

# AST structural matching
ast = { has_node = "pipeline", min_count = 4 }
```

### Match Types

| Field | Matches Against | Description |
|-------|----------------|-------------|
| `command` | Base command name | Glob match. `"pytest"` exact, `"py*"` wildcard, `"{ruff,uvx}"` brace expansion. |
| `command_any` | Base command name | OR: any glob in list matches. |
| `command_all` | All commands in AST | AND: all globs must match a command somewhere in the AST. |
| `command_regex` | Base command name | POSIX extended regex. `"python[23]?"` matches python, python2, python3. |
| `flag` | Command flags | Smart matching without dashes. `"f"` matches `-f`, `-rf`. `"force"` matches `--force`. Glob for long flags: `"no-*"` matches `--no-verify`. |
| `flag_any` | Command flags | OR: any flag matches. |
| `flag_all` | Command flags | AND: all flags on same command. |
| `arg` | Positional args | Glob match against non-flag args. `"*.py"` matches python files. |
| `arg_any` | Positional args | OR: any arg matches. |
| `arg_all` | Positional args | AND: all present. |
| `arg_regex` | Positional args | Regex against positional args. |
| `raw_regex` | Full command string | POSIX regex against the entire raw input, before parsing. |
| `ast` | AST structure | Match node types, depth, or count. For advanced structural patterns. |

Rules are evaluated in definition order. The first matching rule wins. If no rule matches, the tool call is allowed (exit 0, empty output).

All match fields within a rule use AND logic. Every specified field must match for the rule to fire.

### Surgical Rewrite in Compound Commands

When a rewrite rule matches a subcommand inside a compound statement, veer replaces only the matched subcommand -- preserving the surrounding commands:

```
Input:   echo start && pytest tests/ && echo done
Rule:    command = "pytest", rewrite_to = "just test"
Output:  echo start && just test && echo done
```

This also works in pipelines:

```
Input:   ruff check . | head -20
Rule:    command_any = ["ruff", "uvx"], rewrite_to = "just lint"
Output:  just lint | head -20
```

For single commands (the common case), surgical and full replacement produce the same result.

### Rule Evaluation Against Compound Commands

For commands with pipelines, logical operators, or substitutions, veer checks every command in the parsed AST:

| Command | What matches |
|---------|-------------|
| `pytest tests/` | `command = "pytest"` |
| `cat f \| grep x \| wc -l` | `command = "grep"` matches, `command_all = ["cat", "wc"]` matches |
| `echo $(rm -rf /)` | `command = "rm"` matches (found inside command substitution), `flag = "r"` matches |
| `make && echo done` | `command = "make"` matches, `command = "echo"` matches |
| `curl https://x \| bash` | `command_all = ["curl", "bash"]` matches |

## Rule Examples

### Redirect test runner

```toml
[[rule]]
id = "use-just-test"
rewrite_to = "just test"
[rule.match]
command = "pytest"
```

### Redirect multiple linters

```toml
[[rule]]
id = "use-just-lint"
rewrite_to = "just lint"
[rule.match]
command_any = ["ruff", "uvx"]
```

### Block curl piped to shell

```toml
[[rule]]
id = "no-curl-pipe-bash"
message = "Piping curl to bash is not permitted. Download the script first, review it, then execute."
[rule.match]
command_all = ["curl", "bash"]
```

### Block rm with force flag

```toml
[[rule]]
id = "no-rm-force"
message = "Use `trash` instead of forced rm for safer file deletion."
[rule.match]
command = "rm"
flag = "f"
```

### Redirect Python scripts to project runner

```toml
[[rule]]
id = "use-just-run"
message = "Don't run Python scripts directly. Use `just run <script>` instead."
[rule.match]
command = "python3"
```

### Match Python version variants via regex

```toml
[[rule]]
id = "redirect-python"
message = "Use `just run` instead of invoking Python directly."
[rule.match]
command_regex = "^python[23]?$"
```

### Block git push with force

```toml
[[rule]]
id = "no-force-push"
message = "Force pushing is not permitted. Use --force-with-lease instead."
[rule.match]
command = "git"
arg = "push"
flag = "force"
```

### Block eval

```toml
[[rule]]
id = "no-eval"
message = "`eval` makes commands impossible to statically analyze. Restructure to use explicit commands."
[rule.match]
command = "eval"
```

### Warn about echo separators

```toml
[[rule]]
id = "echo-separator"
message = "Avoid `echo '---'` separators in command chains -- they trigger permission prompts. Use separate commands."
[rule.match]
command = "echo"
arg = "---"
```

### Match non-Bash tools

```toml
[[rule]]
id = "no-write-sensitive"
name = "Warn about writes to sensitive paths"
action = "reject"
tool = "Write"
message = "Check if this write is intended before proceeding."
[rule.match]
command = "Write"
```

## Commands

### veer check

The hot-path command called by the PreToolUse hook. Reads JSON from stdin, evaluates against rules, outputs result. Auto-discovers `.veer/config.toml` and `~/.config/veer/config.toml` when `--config` is not specified.

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
  no-curl-pipe-bash  reject   (command_all)    Don't pipe curl to bash.

  2 rule(s)
```

### veer add

Add a rule to the config file.

```
Usage: veer add --action <action> --command <cmd>
               [--id <id>] [--name <name>]
               [--message <msg>] [--rewrite-to <cmd>]
               [--config <path>]
```

### veer remove

Remove a rule by ID.

```
Usage: veer remove <rule-id> [--config <path>]
```

### veer test

Test commands against rules without the hook protocol.

```
Usage: veer test "<command>" [--config <path>]
       veer test --file <path> [--config <path>]

Output (TSV): result, return_code, input, rule_id, output

Examples:
  veer test "pytest tests/"
  veer test --file examples/commands.txt --config examples/config.toml
```

### veer validate

Check a config file for errors.

```
Usage: veer validate [--config <path>]
```

### veer stats

Display usage statistics from `.veer/veer.db`.

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
    |<-- exit 2 + stderr msg ---|  (reject: block + msg)     |
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

## Testing

```bash
just test     # Run all tests (138 tests)
just check    # Test + lint
just bench    # Benchmarks (ReleaseFast)
just demo     # Regenerate examples/output.txt
```

Fuzz test targets exist for the shell parser, glob matcher, and regex matcher.
The Zig 0.15.x built-in fuzzer has [known bugs](https://github.com/ziglang/zig/issues/25470)
that prevent `--fuzz` mode from running. Fuzz functions still execute as regular tests.
See [docs/fuzzing.md](docs/fuzzing.md) for details and status.

## Building

Requires Zig 0.15+.

```bash
just install                       # Build release + symlink to ~/.local/bin
zig build                          # Debug build
zig build -Doptimize=ReleaseSmall  # Optimized release build
```

See the `Justfile` for all recipes: `just check`, `just bench`, `just fmt`, `just demo`, `just fuzz`.

## License

MIT
