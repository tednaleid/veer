# Path matching for file tools

Design for matching veer rules against the target path of file-writing tools,
and for a third `allow` action that expresses a rule as a gate.

Written against veer 0.1.11.

## Motivation

veer today can only match Bash commands and the text content of `ExitPlanMode`
plans. A rule cannot say anything about *where* a `Write` or `Edit` lands. The
gap is already recorded as item 4 in `docs/spec/remaining-work.md`.

The concrete rule that surfaced it: allow writes inside `.claude/worktrees/**`
and a short list of scratch paths, reject writes anywhere else in the checkout,
never touch reads. The generic shape is broader: reject writes to `.env`, to
generated files, to vendored directories, or outside the project entirely.

Three things block it today.

**The path never reaches the engine.** `HookInput` (`src/claude/hook.zig:7-17`)
carries `tool_name`, `command`, `session_id`, `transcript_path`, and `content`.
The parser reads `tool_input.command` and nothing else out of `tool_input`
(`hook.zig:43-46`); `tool_input.file_path` is discarded. `cwd` is present in the
envelope Claude Code sends and is never parsed. `engine.check()` takes
`(allocator, rules, tool_name, command, content)` (`src/engine/engine.zig:30-36`)
and has no parameter a path could arrive in.

**Non-Bash rules consult exactly one matcher.** `engine.zig:81-92` branches on
`tool_name == "Bash"`, and the non-Bash arm calls only `matcher.matchContent`,
which returns `true` when the rule has no `content_*` matchers
(`src/engine/matcher.zig:220-234`). A rule carrying only `raw_regex` therefore
fires on tool name alone. This rule blocks every `Write` in the session:

```toml
[[rule]]
id = "probe"
tool = "Write"
action = "reject"
message = "M"
[rule.match]
raw_regex = "ZZZNOTPRESENT"
```

It validates clean, because `hasAnyMatch` (`src/config/rule.zig:116-132`)
accepts `raw_regex` regardless of `tool`.

**One rule cannot cover several tools.** `tool: []const u8 = "Bash"`
(`rule.zig:54`) is a single string compared with `mem.eql` (`engine.zig:55`).

## Design invariants

Two properties the implementation must preserve. Every decision below follows
from one of them.

**veer fails open.** An unparseable command approves (`engine.zig:44-47`); a
plan body that could not be resolved does not match. A guard that blocks on
missing data is worse than one that lets a call through, because it strands the
agent with no path forward. Every new "cannot evaluate" case resolves to
"do not fire".

**Allow gates are monotonically narrowing.** Adding a gate can only reduce what
passes, never expand it. This is what makes tier merging safe: `config.zig`
orders rules local, then project, then global, so every rule in a private
`.veer/config.local.toml` sits above every team rule. Under narrowing-only
semantics a private gate can add a constraint on top of the team's rules but
can never subtract one. A future change that lets `allow` approve-and-stop
would break this and must not be made without revisiting the tier order.

## Engine restructure

The `tool_name == "Bash"` branch in `engine.check` is the bug. It goes away.

### Evaluation context

`check()`'s positional parameters become a struct:

```zig
pub const ToolCall = struct {
    tool_name: []const u8,
    command: ?[]const u8 = null,   // tool_input.command
    content: ?[]const u8 = null,   // resolved plan body (ExitPlanMode)
    file_path: ?[]const u8 = null, // tool_input.file_path ?? notebook_path ?? path
    cwd: ?[]const u8 = null,       // envelope cwd, for resolving a relative file_path
    root: ?[]const u8 = null,      // dir containing .veer/, else cwd
};

pub fn check(allocator: std.mem.Allocator, rules: []const Rule, call: ToolCall) CheckResult
```

Call sites: `src/cli/check.zig:32` and `src/cli/test_cmd.zig:52`.

`file_path` extraction is an ordered fallback over three key names in
`tool_input`, first non-null string wins, with no tool-name table involved. A
future Claude Code tool or an MCP tool named `mcp__server__write_file` that
carries `file_path` works without a veer release.

`root` is the directory containing `.veer/`. `config.zig` already computes
`project_config_path` as `<root>/.veer/config.toml`, so the root is a
`dirname` away. When only the global tier loaded, `root` is `cwd`.

### Matcher families read exactly one field

| Matcher family | Reads |
|---|---|
| `command*`, `flag*`, `arg*`, `ast`, `raw_regex` | `command` |
| `content_regex`, `content_contains` | `content` |
| `path`, `path_any`, `path_regex` | `file_path` |

**If any matcher on a rule reads a null field, the rule is skipped entirely.**
Not "that matcher fails" -- the whole rule is inapplicable and evaluation moves
to the next one.

That single rule fixes the always-fire trap generically: `raw_regex` on a
`Write` reads `command`, which is null, so the rule is skipped instead of
firing on tool name alone. It works for tools veer has never heard of.

Skipping the whole rule is deliberate rather than failing the individual
matcher. With per-matcher failure, an allow gate carrying both `path_any` and
`content_contains` would reject whenever content happened to be null, because
an unsatisfiable gate rejects. That is fail-closed, and it contradicts the
first invariant.

A tool-name-only rule (`tool = "NotebookEdit"` with no matchers) still fires.
It has no matcher reading a null field. This stays legal and meaningful: the
bug was never that tool-name-only rules match, it was that a rule with an
inapplicable matcher silently degraded into one.

### The evaluation loop

```
for each enabled rule:
    tool filter fails            -> continue
    any matcher reads null field -> continue        // inapplicable
    matched = all matchers AND together
    action:
        reject  -> matched  ? fire reject  : continue
        rewrite -> matched  ? fire rewrite : continue
        allow   -> matched  ? continue     : fire reject with rule.message
```

Bash keeps its existing `matchRule` traversal underneath for the
`command`-reading families. Only the dispatch above it changes.

## Config surface

Three additions. No removals, and no behavior change to any existing rule.

```toml
[[rule]]
id = "worktree-only-writes"
action = "allow"                                  # new third action
tool_any = ["Write", "Edit", "NotebookEdit"]      # new, exclusive with `tool`
message = "Writes to the primary checkout are off-limits. Work in a worktree."
[rule.match]
path_any = [".claude/worktrees/**", ".llm/**", ".claude/**", "CLAUDE.local.md"]
```

### `allow`

A third value in `Action`, alongside `rewrite` and `reject`. An allow rule is a
gate: its `[rule.match]` block is the allowlist of what may pass.

- If the rule applies and matches, evaluation **falls through** to the next rule.
- If the rule applies and does not match, the call is **rejected** with the
  rule's `message`.
- If the rule does not apply, evaluation falls through.

An allow rule never approves-and-stops. That is what delivers the narrowing
invariant. It also means ordering matters far less for gates than it would for
a short-circuiting allow: a gate anywhere in the list applies.

`allow` requires `message`, same as `reject`, since the message is what the
agent sees when the gate fails.

Valid only with `path*` and `content_*` matchers. A `command`-reading matcher
on an allow rule is a load-time error (see non-goals for why).

Multiple gates on the same tool intersect. Two allow rules on `Write` mean a
path must satisfy both. This is the narrowing invariant showing through, not a
side effect: if gates unioned, a `config.local.toml` gate could widen past a
team gate. The authoring mistake it invites (two gates named like additive
permissions, `can-edit-src` and `can-edit-docs`, which together permit nothing)
fails loud and closed on the first call, and `check.zig` already prefixes
rejects with the rule id, so the author sees which gate bit them.

### `tool_any`

Mirrors `command_any`. Exact string match, no globbing. Setting both `tool` and
`tool_any` is a validation error.

### `path`, `path_any`, `path_regex`

Mirrors the `arg` family's naming. `path_regex` is the escape hatch, POSIX
extended, matched against the normalized path.

## Path semantics

### Normalization

Given `file_path` from the envelope:

1. If relative, join with `cwd`.
2. Collapse `//`, resolve `.` and `..` textually.
3. If the result is under `root`, keep the root-relative form (`api/main.py`).
   Otherwise keep it absolute.

Lexical only. No `realpath`, no symlink resolution, no `stat`. `Write` creates
files that do not exist yet, so `realpath` fails on exactly the calls most worth
catching, and syscalls do not belong in the hot path of a tool whose first
design principle is speed.

Matching is case-sensitive, like gitignore and like `content_contains`.

A path outside `root` has no root-relative form, so it never matches a relative
pattern. That is what makes a stay-in-repo gate work without a special case:

```toml
[[rule]]
id = "stay-in-repo"
action = "allow"
tool_any = ["Write", "Edit"]
message = "Stay inside the project."
[rule.match]
path_any = ["*"]
```

### Pattern classification

A trailing `/` is rewritten to `/**` first. The result is then classified in
this order:

| Pattern shape | Kind | Meaning | Example |
|---|---|---|---|
| starts `/` | absolute | filesystem path | `/etc/**` |
| starts `~/` | absolute | `$HOME` expanded, then absolute | `~/.ssh/**` |
| starts `./` | relative | `./` stripped, anchored at root | `./.env` is `<root>/.env` only |
| contains `/` | relative | anchored at root | `src/**` is `<root>/src/**` |
| no `/` | relative | matches the file's name, at any depth | `.env` matches `apps/web/.env` |

Two consequences that are easy to misread and are load-bearing:

**A relative pattern only matches a path that has a root-relative form.** A
normalized path outside `root` stays absolute and is never offered to a relative
pattern, so `path_any = ["*"]` does not match `/tmp/scratch.txt` via its
basename. This is what makes the stay-in-repo gate above reject rather than
approve.

**`./` anchors regardless of what follows.** After stripping `./`, the remainder
is matched anchored at root even when it contains no slash, which is the entire
point of the form: `./.env` is the root `.env` and nothing else, while `.env`
is any `.env` at any depth.

The pattern language is gitignore's, because it is familiar and proven, with
one deliberate divergence and two omissions.

**Leading `/` means the filesystem root, not the repo root.** gitignore reads
`/build` as the repo-root `build`. Everywhere else a path pattern appears -- a
shell, a Dockerfile, a linter config, a CI file -- a leading slash is the
filesystem. A `.veer/config.toml` is not a gitignore, and the agent writing
rules into it is not in gitignore mode. If it emits `/etc/**` intending the real
`/etc` and veer reads that as `<root>/etc/**`, the rule silently never fires.

Almost nothing is lost, because gitignore's anchoring is already carried by the
slash rule: `src/**` is root-anchored without needing a leading slash. The one
hole is anchoring a single-segment pattern, which `./` fills. `./` is
unclaimed -- gitignore has no such convention, and `./foo` in a `.gitignore`
silently matches nothing -- so giving it a meaning contradicts nothing anyone
knows.

The cost is real and asymmetric: an author fluent in gitignore who writes
`/build/**` meaning the repo-root `build` gets an absolute path that matches
nothing. This is documented in the README match table and in the skill's
pitfalls section, and `veer test --tool Write --path <p>` turns "did my rule
fire" into one command.

**Omitted: `[a-z]` character classes.** veer's `globMatch` has never had them,
and it has `{a,b}` brace expansion, which gitignore lacks. Keeping veer's braces
is the smaller surprise.

**Omitted: trailing `/` as directory-only.** veer cannot `stat` a file `Write`
is about to create. Reused as sugar for `/**` instead, which reaches the same
observable outcome by a different mechanism.

### Glob dialect

A new `pathMatch(pattern, path)` in `matcher.zig`. `globMatch` is untouched, so
no existing Bash rule changes behavior and `arg = "*.py"` keeps matching
`src/foo.py`.

`pathMatch` splits on `/` and matches segment-wise:

- `**` spans zero or more segments. `a/**/b` matches `a/b`, `a/x/b`, `a/x/y/b`.
- `*` and `?` stay inside one segment.
- `{a,b}` brace expansion applies within a segment: `src/**/*.{ts,vue}`.

Consecutive `**` segments collapse at parse time. This makes catastrophic
backtracking on patterns like `a/**/**/**/**/b` unrepresentable, which is
cheaper and more complete than a depth bound.

### Known limitation: no-slash patterns match file names

`path_any = ["node_modules"]` matches nothing, because no file is *named*
`node_modules`. In gitignore that pattern ignores the whole directory. veer
matches a single file path and has no directory concept, so it cannot replicate
that.

The trailing-slash sugar rescues the common case: `node_modules/` and
`node_modules/**` both work. This is the first entry in the skill's pitfalls
section.

A `veer validate` warning on wildcard-free no-slash patterns was considered and
rejected: `Makefile` is a real file name and would false-positive.

## CLI, validation, and error messages

### `veer test` reaches non-Bash rules

`test_cmd.zig:52` hardcodes `"Bash"`, so the documented "test before committing
a rule" workflow cannot touch a `Write`, `Edit`, or `ExitPlanMode` rule at all.

```bash
veer test "pytest tests/"                              # unchanged
veer test --tool Write --path apps/web/.env            # new
veer test --tool ExitPlanMode --content-file plan.md   # new
```

`--tool` defaults to `Bash`, so every existing invocation and the TSV output
format are unchanged. `--file` keeps its current meaning: a file of commands,
one per line.

`veer test --json` is not added. `echo '{...}' | veer check --config <path>`
already exercises the real parse path.

### Validation

Three new checks, each naming the field and the offending value:

- **A matcher whose field the declared tool cannot carry.** Uses a small table
  of tools veer knows:

  | Tool | Carries |
  |---|---|
  | `Bash` | `command` |
  | `Write`, `Edit`, `NotebookEdit`, `Read`, `Grep`, `Glob` | `file_path` |
  | `ExitPlanMode` | `content` |

  `Write` carries `file_path` only, not `content`: matching a file body is a
  non-goal below, so `content_contains` on a `Write` rule is a validation error
  naming the feature that does not exist rather than a rule that never fires.

  An unrecognized tool name, including anything `mcp__*`, is exempt rather than
  rejected, so veer does not bake Claude Code's tool roster into its schema.
  Without this check an inapplicable matcher goes from silently always-firing to
  silently never-firing, which is better but still silent.
- **A `command`-reading matcher on an `allow` rule.**
- **Both `tool` and `tool_any` set.**

### TOML errors name the field

`config.zig:loadString` catches the parser error and discards
`parser.error_info`, which `sam701/zig-toml` already populates as
`ErrorInfo{ .parse = position }` or `{ .struct_mapping = field_path }`
(`root.zig:57,131,143`). Plumbing it through turns
`.veer/config.toml: TOML parse error` into a message naming the line or the
field path.

This matters more than it looks. `main.zig:139-155` exits 2 on a load failure,
which is the right call for a guard, but it means one typo blocks every tool
call in the session, including `Read`, behind a message that does not say what
is wrong.

### Help text

`main.zig:454` advertises `--action <str> Rule action (allow, deny, rewrite,
warn)`. None of `allow`, `deny`, or `warn` parse today. It becomes
`(allow, reject, rewrite)`, all three of which will.

## Testing

Red/green per `CLAUDE.md`. Tests in `test` blocks alongside source, registered
in `src/test_all.zig`, `std.testing.allocator` throughout, table-driven with
`inline for`.

The first failing test is the always-fire regression, written before anything
else:

```zig
test "raw_regex rule does not fire on a tool that carries no command" {
    const rules = [_]Rule{.{
        .id = "probe", .tool = "Write", .message = "M",
        .match = .{ .raw_regex = "ZZZNOTPRESENT" },
    }};
    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "Write", .file_path = "/tmp/scratch.txt",
    });
    try std.testing.expect(result.action == null);
}
```

**`pathMatch`** carries the bulk of the risk and gets a large table: each
pattern shape from the classification table crossed with matching and
non-matching paths, `**` spanning zero segments, brace expansion within a
segment, and the `node_modules` versus `node_modules/` pair.

**Normalization** gets its own table: relative plus `cwd`, `..` traversal, paths
outside `root`, and `apps/../apps/x.ts` normalizing to the same result as
`apps/x.ts`.

**Gate semantics** need four tests: a passing gate falls through to later rules,
a failing gate rejects with its own message, a gate whose field is null does not
apply, and two gates on the same tool intersect rather than union.

**`hook.zig`** gets tests for the `file_path` / `notebook_path` / `path`
fallback order and for `cwd` extraction. The existing test at `hook.zig:223-228`
feeds a `Write` with `file_path: "/etc/passwd"` and asserts only `tool_name`; it
becomes an assertion that the path is carried.

Roughly fifteen existing `engine.zig` tests convert from positional arguments to
`ToolCall` literals. Mechanical, but the largest single chunk of churn.

`pathMatch` joins the fuzz targets already listed in `remaining-work.md` item 1.

`src/bench.zig` gains a path-matching case, since the PRD asks for a benchmark
on every PR and this adds work to the hot path.

The Justfile smoke recipes (`check-allow`, `check-rewrite`, `check-deny`) gain a
gate recipe piping a real `Write` envelope through the hook protocol end to end.

**Pre-existing limit, now newly reachable:** `regexMatch` returns false when the
text is 1024 bytes or longer (`matcher.zig:321-336`), so `path_regex` silently
fails on very long paths. Documented rather than left to be discovered.

## Documentation

`README.md`: `allow` in the Actions section, `tool_any` in the Rule Schema
block, three `path*` rows in the Match Types table, a new subsection for the
path pattern syntax, and the Bash-bypass caveat.

`src/cli/skill_content.md`, which `install.zig:7` embeds and rewrites on every
`veer install` (editing the generated `.claude/skills/veer/SKILL.md` would be
undone):

- "The two actions" becomes three, explaining gates as narrowing-only.
- "Match patterns" gains the `path*` family.
- "Matching non-Bash tools" currently covers only `content_*` and gains paths.
- "Common pitfalls" gains the no-slash-matches-file-names trap and the
  leading-`/`-is-absolute divergence from gitignore.

`docs/spec/remaining-work.md` item 4 is resolved by this work.

## Non-goals

**Bash routes around every path rule.** `cat > apps/x.ts`, `sed -i`, `tee`,
`cp`, `mv`. veer parses Bash to an AST and could match redirection targets
someday, but `sed -i`, `tee`, `cp`, and `mv` each need their own handling. This
is a guardrail for an agent that is trying to comply and forgot, not a sandbox
against one trying to escape. Stated in the README rather than left for someone
to find.

**Symlinks are not resolved.** See normalization.

**`content_*` still means the ExitPlanMode plan body only.** A `Write`'s
`tool_input.content` is not matched. Matching file bodies ("do not write a file
containing an AWS key") is a good feature and a separate one: it changes what
`content_*` means and needs size and binary handling.

**No `!` negation inside patterns, and no `path_not_any`.** One shape stays
unexpressible: "reject under `api/**` except `api/generated/**`". A gate cannot
say it, because a gate applies to every call its tool filter matches. No case
worth believing in turned up, so it waits for one.

**`allow` does not accept Bash matchers.** Two reasons. Most of the Bash
vocabulary has no coherent gate reading -- `flag_any` as a gate means "every
command must carry `-f`", `command_all` exists to detect a dangerous
combination, `ast` gates on pipeline shape -- so accepting them would ship a new
batch of matchers that validate clean and behave incoherently, which is the bug
class this spec exists to fix. And `engine.zig:44-47` approves on an unparseable
command, so a command allowlist would have an agent-controllable hole; a leaky
whitelist is worse than none, because people stop reading the commands. Claude
Code's `permissions.deny` is the wall, enforced at a layer veer cannot be more
reliable than.

The coherent subset (`command`, `command_any`, `command_regex`, `raw_regex`
with all-commands-must-pass traversal) is a small change if it is ever wanted.
The traversal inversion in `matchRule` (`matcher.zig:36-42`) is about three
lines.

**`rewrite` still short-circuits,** so a rewrite rule can jump a gate placed
below it: a `pytest` to `just test` rewrite returns before any gate is
consulted. Whether rewrite should fall through instead is a real question, and a
harder one, because it raises what the next rule matches against -- the original
command or the rewritten one. Backlogged with this interaction attached.

**No globbing in `tool_any`.** Exact names only.

## Sequencing

The first four items are independently useful to every veer user and do not
depend on path matching. They land first so the rest is verifiable.

1. Matcher-field applicability at runtime, plus the validation check. Kills the
   always-fire trap and stops the new `path*` family from landing in the same
   hole.
2. `veer test --tool` / `--path` / `--content-file`. Without it there is no
   red/green loop for a non-Bash rule from the CLI.
3. TOML `error_info` plumbed through.
4. `--action` help text.
5. `ToolCall` struct, `file_path` and `cwd` extraction, `root` resolution.
6. `pathMatch` and the `path*` matcher family.
7. `allow` action and `tool_any`.
8. README, skill content, `remaining-work.md`.
