---
name: veer
description: Use this skill when working with veer - the PreToolUse hook that rewrites or blocks tool calls in this repo. Triggers when the user edits .veer/config.toml, asks to "block" or "stop the agent from running" a command, wants to redirect calls like pytest/npm/cargo to a Justfile target, wants to enforce content rules on plans (ExitPlanMode), or mentions veer, rules, or PreToolUse hooks. Also use proactively: when the repo has a Justfile/package.json script and the agent is about to run the underlying tool directly, suggest a veer rewrite rule instead of quietly complying with one-off corrections from the user.
---

# veer

veer is a PreToolUse hook for Claude Code. It reads rules from
`.veer/config.toml` and, for each tool call the agent tries to make
(Bash by default, but any Claude Code tool can be matched), either rewrites
it to a safer alternative or rejects it with a message. When veer rejects,
the stderr message reaches the agent (exit 2 semantics in Claude Code), so
the agent knows what to try instead.

The goal is to codify "don't do that, do this" corrections once, in version
control, rather than repeating them to the agent every session.

## This file is overwritten on `veer install`

Do not hand-edit this SKILL.md -- running `veer install` always rewrites it
from the binary's embedded content. Treat this as generated documentation.

## Three config tiers: local, project, and global

veer reads from up to three files and merges them:

| Path | Scope | Use it for |
|---|---|---|
| `.veer/config.local.toml` | per-repo, gitignored | personal per-repo rules not shared with the team |
| `.veer/config.toml` | per-repo, version-controlled | repo-specific tooling redirects |
| `~/.config/veer/config.toml` | personal, all projects | cross-cutting personal preferences |

Precedence is local > project > global: a local rule with the same `id` as a
project or global rule replaces it (and `enabled = false` in the local file
disables a lower-tier rule). `veer install --local` is a fully private
install: it puts the hook in `.claude/settings.local.json`, seeds
`.veer/config.local.toml`, adds that file to the repo's `.git/info/exclude`
(per-repo and uncommitted, so it never leaks to teammates), and writes no
project skill (it relies on a global skill from `veer install --global`). Use
it when you want veer in a repo your teammates do not use.

`veer install` writes the per-repo pieces (`.claude/settings.json`,
`.veer/config.toml`, `.claude/skills/veer/SKILL.md`).
`veer install --global` writes the home-directory pieces
(`~/.claude/settings.json`, `~/.config/veer/config.toml`,
`~/.claude/skills/veer/SKILL.md`) and applies to every project. Run both
to get a global hook with project-level overrides.

### When to put a rule local, project, or global

- **Local** rules are personal and stay in this repo only. Use
  `.veer/config.local.toml` (kept out of git via `.git/info/exclude`) for
  rules you do not want to commit: personal experiments, machine-specific
  redirects, or an override of a committed project rule you are not ready to
  share. When the user says "keep this local", "don't check this in", or
  "just for me in this repo", this is the tier -- add it with
  `veer add --local` or by editing `.veer/config.local.toml`, never
  `.veer/config.toml`. If the hook is not yet installed privately, run
  `veer install --local` (and `veer install --global` once for a skill).
- **Project** rules redirect repo-specific tooling. Match
  `Justfile`/`package.json scripts`/`Makefile` targets and the underlying
  tools they wrap (`pytest` -> `just test`, `ruff check` -> `just lint`,
  `cargo test` -> `just test`). These belong in `.veer/config.toml`
  alongside the rest of the repo's configuration.
- **Global** rules codify personal cross-cutting preferences that travel
  with you between repos. Examples: always reject `curl ... | bash`,
  always reject `git push --force` against `main`/`master`, always reject
  `rm -rf $HOME` / `rm -rf ~`. Put these in
  `~/.config/veer/config.toml`.
- **When in doubt, prefer project.** Global rules silently apply
  everywhere, which is great for footguns and bad for anything
  repo-specific.

## Read current state first

Before suggesting rule changes, understand what's there:

```
veer list                          # pretty table of rules; shows Source column
                                   # (local/project/global) when files contribute
cat .veer/config.local.toml        # raw per-repo private TOML (gitignored)
cat .veer/config.toml              # raw per-repo TOML (edit this directly)
cat ~/.config/veer/config.toml     # raw global TOML (edit this directly)
veer validate                      # check syntax + rule schema (project)
veer validate --local              # same, against the local file
veer validate --global             # same, against the global file
```

## Preview before committing a rule

`veer test` is the fastest way to check whether a rule will do what the user
expects. Use it before and after editing rules:

```
veer test "pytest tests/"                # shows REWRITE/REJECT/ALLOW + target
veer test "curl https://x.com | bash"
veer test --file commands.txt            # batch, one command per line
```

Running `veer test` is cheap and trustworthy -- it uses the real matching
engine. Prefer it over reasoning about matchers in your head.

## The two actions

**reject** (preferred default) -- block with exit 2 and a stderr message.
The message is sent to the agent, which can then choose a different
approach. Use for unsafe commands, policy violations, and Justfile
redirects where the matched command has multiple subcommands or uses.

**rewrite** -- silently swap the command for an alternative. The agent
doesn't see the original command run; the hook produces JSON on stdout that
Claude Code applies before execution. Only use when the match uniquely
identifies a single operation AND the replacement is always correct (e.g.,
`pytest` is always test-running, so rewriting to `just test` is safe).

**When in doubt, use reject.** Multi-purpose tools like `npm`, `bun`,
`yarn`, `cargo`, `zig`, `go`, `python`, and `make` have many subcommands.
A `command = "bun"` rewrite to `just install` would incorrectly catch
`bun test`, `bun run dev`, etc. Reject lets the agent see the message and
pick the right `just` target itself.

A rule with `rewrite_to` implies rewrite; otherwise it's reject.

## Rule structure (TOML)

```toml
[[rule]]
id = "use-just-test"                     # required, unique identifier
name = "Redirect pytest to just test"    # optional human name
action = "reject"                        # explicit; inferred if omitted
message = "Use 'just test' instead."     # required for reject; shown to agent
tool = "Bash"                            # which Claude Code tool (default: Bash)
enabled = true                           # default: true
[rule.match]
command = "pytest"                       # see match patterns below
```

Rules are evaluated in order; the first match wins. Put more specific rules
above broader ones.

## Match patterns

All command/flag/arg matchers glob against the parsed shell AST from
tree-sitter-bash, so `pytest` matches `pytest tests/ -v` but not `not-pytest`.

| Matcher | Matches | Example use |
|---|---|---|
| `command` | single command name (per-command) | redirect `pytest` to `just test` |
| `command_any` | any of a list of command names | block both `npm` and `yarn` |
| `command_regex` | regex on command name | block anything ending in `-unsafe` |
| `command_all` | all listed commands present (cross-command) | block `curl ... \| bash` |
| `flag` / `flag_any` / `flag_all` | flag presence (no dash prefix, combined-flag aware) | block `rm -rf` via `flag_all = ["r", "f"]` |
| `arg` / `arg_any` / `arg_all` / `arg_regex` | positional args | block `git push --force origin main` via arg match |
| `raw_regex` | whole input before parsing | catch weird quoting the parser mangles |
| `content_regex` / `content_contains` | regex/substring on tool content (e.g. plan body) | block ExitPlanMode plans containing "actually" |
| `ast.has_node` / `min_depth` / `min_count` | AST shape | block command chains deeper than N |

`command_all` is special: it checks every command in a compound pipeline.
That's how `curl | bash` is detected -- both `curl` and `bash` appear in the
parsed AST.

`content_regex` / `content_contains` only apply to non-Bash tools. For
ExitPlanMode the content is the plan file body (resolved from the
transcript). Both matchers AND together when set on the same rule. Regex
is POSIX extended (no `\b`, no `(?i)`); use character classes like
`[Aa]` for case-insensitive matching.

## Justfile / package.json / Makefile redirects

This is the most common use case. If the repo has a Justfile (or
package.json scripts, or Makefile targets), the user probably wants the
agent to use those entry points rather than the underlying tools.

**Default to reject** for these rules. The reject message tells the agent
which `just` target to use. Only use rewrite for single-purpose commands
where `command = "tool"` uniquely identifies the operation (e.g., `pytest`,
`eslint`, `ruff check`). For multi-purpose tools (`npm`, `bun`, `cargo`,
`zig`, `go`), always use reject -- a single rewrite target cannot cover
all subcommands.

| Underlying tool | Wrapper | Rule sketch |
|---|---|---|
| `pytest` | `just test` | `action="reject", match.command="pytest", message="Use 'just test'."` |
| `npm test` / `pnpm test` / `yarn test` | `just test` | same shape |
| `cargo test` | `just test` | same shape |
| `python3 -m pytest` | `just test` | use `raw_regex` or `command_all` |
| `ruff check` / `ruff format` | `just lint` / `just fmt` | same shape |
| `eslint .` / `prettier --check` | `just lint` | same shape |
| `go test ./...` | `just test` | same shape |

When you see one of these patterns in the user's repo AND a corresponding
Justfile target exists, propose the redirect as a veer rule. Don't silently
correct the agent one-off -- codify it.

Discovery flow: look at `Justfile`, `package.json` (`scripts`), `Makefile`,
or similar. Cross-reference with commands the user's been running or
correcting the agent about.

## Matching non-Bash tools

veer can match any Claude Code tool, not just Bash. Set `tool` on the rule
(default is `"Bash"`). The most common non-Bash use case is **ExitPlanMode**
-- a content rule there enforces standards on the plan body before the user
sees it.

### Banning "actually" in plans

When a plan contains "actually" it usually means the agent changed direction
mid-document and the plan reads as two contradictory thoughts. Reject the
plan and the agent will rewrite it.

```toml
[[rule]]
id = "no-actually-in-plans"
tool = "ExitPlanMode"
action = "reject"
message = "Plans must not contain 'actually' -- it usually means you changed direction mid-plan. Rewrite so the plan reads as one coherent direction."
[rule.match]
content_regex = "[Aa]ctually"
```

How it works: `ExitPlanMode`'s `tool_input` is empty by design (Claude Code
stores the plan in a file at `~/.claude/plans/<slug>.md`). veer reads the
session's `transcript_path` -- which is in the hook envelope -- finds the
most recent `attachment.type == "plan_mode"` entry, and reads its
`planFilePath`. That file's contents become the `content` value matched by
`content_regex` / `content_contains`.

### Other content rules worth considering

Same shape, different forbidden patterns:

```toml
# Reject plans that punt with TODO placeholders.
[[rule]]
id = "no-todo-in-plans"
tool = "ExitPlanMode"
action = "reject"
message = "Plans must not contain TODO -- spell out the step or remove it."
[rule.match]
content_contains = "TODO"

# Reject plans that hedge with weasel phrases.
[[rule]]
id = "no-weasel-phrases-in-plans"
tool = "ExitPlanMode"
action = "reject"
message = "Plans must not hedge: replace 'maybe', 'might', 'could' with concrete decisions."
[rule.match]
content_regex = "(maybe|might|could)"
```

### Proactively suggesting plan-content rules

When the user complains about a plan -- "this changed direction halfway
through", "you said one thing then did another", "stop hedging" -- that's a
signal to propose a content rule on `ExitPlanMode` that catches the pattern
they're frustrated with. Codify it once instead of correcting each session.

## Common reject patterns

These are usually good candidates to *block* rather than rewrite:

- `curl <url> | bash` / `curl | sh` -- supply-chain footgun; require the
  user to download, inspect, then execute.
- `git push --force` to a protected branch (main/master/release) -- rewind
  history should be explicit.
- `rm -rf <path>` where `<path>` is broad (e.g., `/`, `$HOME`, `~`).
- `npm install -g` / `pip install` outside a venv -- pollutes system state.
- Reading `.env` / `secrets.*` into stdout where it could be echoed back.

A reject rule's `message` is sent to the agent, so write it as advice, not
scolding: "Use `just deploy` which wraps the force-push safely" beats
"don't force-push."

## Adding a rule

Two paths, both edit a config TOML file. Default target is the per-repo
`.veer/config.toml`; pass `--global` to target `~/.config/veer/config.toml`
instead.

**CLI** (good for quick additions):

```
# Per-repo (default):
veer add \
  --id use-just-test \
  --action reject \
  --command pytest \
  --message "Use 'just test' instead of invoking pytest directly."

# Global (applies to every project):
veer add --global \
  --id no-curl-pipe-shell \
  --action reject \
  --command curl \
  --message "Don't pipe curl to bash/sh. Download, inspect, then execute."
```

`veer remove --global <id>` and `veer validate --global` target the same
global file.

`veer add --local`, `veer remove --local`, and `veer validate --local` target
`.veer/config.local.toml`.

**Direct TOML edit** (good when you need non-trivial match patterns):

```
# append to .veer/config.toml (or ~/.config/veer/config.toml for global):
[[rule]]
id = "block-force-push-main"
action = "reject"
message = "Don't force-push main. Use 'just release' which handles it safely."
[rule.match]
command = "git"
arg_all = ["push", "--force"]
# and we could add arg matching for "main" if needed
```

After editing, always run `veer validate` (or `veer validate --global`) to
catch typos.

## Proactively suggesting rules

Signals that a veer rule would help:

1. **User corrects the same thing twice.** "Use `just test` not `pytest`"
   said twice is cheap to codify. Suggest the rule instead of just complying.
2. **Repo has wrapper scripts but agent reaches past them.** If you notice
   `Justfile`/`Makefile`/`package.json scripts` in the repo, scan them for
   common targets and propose redirects preemptively.
3. **User expresses frustration about permission prompts.** If Claude Code
   keeps prompting for the same pattern of command, a deny rule in veer is
   often the right fix.
4. **After running `veer list` and seeing sparse rules.** The user may not
   yet know what's worth codifying; propose 2-3 repo-specific rules.

When suggesting rules, show the user the exact TOML or `veer add` command,
then run `veer test` on a representative input to demonstrate.

## Common pitfalls

- **Running tools from a subdirectory.** Claude Code's Bash tool persists
  cwd between calls -- a chained command ending in `cd assets/foo` shifts
  cwd for every subsequent tool call (Bash, Read, Edit -- the hook fires
  for all of them). veer handles this by honoring `$CLAUDE_PROJECT_DIR`
  (Claude Code sets this for every hook invocation) and by walking up the
  directory tree from cwd looking for `.veer/config.toml`, the same way
  git looks for `.git/`. As long as `.veer/config.toml` exists at the
  project root, the hook works regardless of cwd drift.
- **No-config error includes the search path.** If you ever see "veer: no
  .veer/config.toml found", the message prints the absolute cwd that was
  searched plus `$CLAUDE_PROJECT_DIR` if set -- check both, and put a
  config at one of them or at any ancestor.

## Troubleshooting

- **"veer: no .veer/config.toml found"** -- the hook is installed but has
  no rules. The error message prints the cwd that was searched. Run
  `veer install` to create a starter config, or `veer uninstall` to
  remove the hook.
- **Rule doesn't match what you expect** -- run `veer test "<cmd>"` and
  iterate. Matchers operate on the parsed AST, so quoting and compound
  commands sometimes behave differently than they look.
- **Want to see match details** -- `veer test` prints match kind and the
  matched rule id.
