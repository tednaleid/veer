# veer Path Matching Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let veer rules match on the target path of file-writing tools, and add a third `allow` action that expresses a rule as a narrowing gate.

**Architecture:** `engine.check()` currently branches on `tool_name == "Bash"` and the non-Bash arm consults only content matchers, so any other matcher silently degrades to "match on tool name alone". That branch is replaced by a uniform loop driven by a field partition: each matcher family reads exactly one field of a new `ToolCall` context struct, and a rule whose matcher reads a null field is skipped entirely. Path patterns are gitignore-shaped globs matched segment-wise against a lexically normalized, repo-root-relative path.

**Tech Stack:** Zig 0.15.2, `sam701/zig-toml`, `zig-clap`, tree-sitter-bash (vendored), SQLite (vendored).

**Spec:** `docs/superpowers/specs/2026-08-12-veer-path-matching-design.md`

## Global Constraints

- **Zig 0.15.2 only.** Install via `brew install zig@0.15`. Does not build on 0.16. Stdlib reference: `/opt/homebrew/Cellar/zig@0.15/0.15.2/lib/zig/std/`.
- **Zig 0.15 API shapes.** `std.ArrayListUnmanaged(T)` initialized with `.empty`, allocator passed to `append(allocator, item)` and `deinit(allocator)`. `std.fs.File.stderr()`, not `std.io.getStdErr()`. Prefer `std.debug.print` for simple stderr output.
- **Use the Justfile.** `just check` (tests + lint, what CI and the pre-commit hook run), `just test`, `just test-summary`, `just lint`, `just build`. Never invoke `zig build` directly when a recipe exists.
- **Never use `--no-verify` when committing.** The pre-commit hook runs `just check`; every commit in this plan must pass it.
- **Red/green TDD for any behavior change.** Write the failing test, run it, watch it fail for the right reason, then implement. A pure refactor is gated on the existing suite passing unchanged; a text-only change is gated on `just lint`. Tasks 1 and 6 are the only two tasks this exempts, and each says so.
- **Tests live in `test` blocks at the bottom of the file they test.** Every new test module must be registered in `src/test_all.zig`; cross-directory imports do not work from individual test files in Zig 0.15.
- **`std.testing.allocator` in every test.** It detects leaks and a leak fails the test.
- **Table-driven tests via `inline for`** over anonymous struct tuples, matching the existing style in `matcher.zig`.
- **All new files start with two `// ABOUTME: ` comment lines** describing what the file does.
- **`src/engine/` must not import from `src/store/`.** It receives a `Store` interface at init time.
- **`src/config/` must not import from `src/engine/`.** `engine/matcher.zig` imports `config/rule.zig`; the reverse would be a cycle. Schema knowledge that both need lives in `config/rule.zig`.
- **No emoji, em dashes, or hyperbole in documentation.** Comments state what is true now, never history or plans.
- **Commit message trailer:** every commit ends with
  `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

## File Structure

**New:**
- `src/engine/path.zig` — path resolution, pattern classification, segment-wise glob matching. Isolated from `matcher.zig` so neither file grows unwieldy; `matcher.zig` is already 763 lines.

**Modified:**
- `src/config/rule.zig` — `path*` match fields, `allow` action, `tool_any`, `FieldSet`/`fieldsUsed`/`toolFields`, three new validation errors
- `src/engine/engine.zig` — `ToolCall` struct, uniform evaluation loop
- `src/engine/matcher.zig` — `matchPathMatchers()`
- `src/claude/hook.zig` — `file_path` and `cwd` extraction
- `src/config/config.zig` — `projectRoot()`, parse-error detail
- `src/cli/check.zig` — `ToolCall` call site, root plumbing
- `src/cli/test_cmd.zig` — `--tool` / `--path` / `--content-file`
- `src/cli/validate_cmd.zig` — parse-error detail, new validation messages
- `src/cli/list.zig` — `tool_any` display
- `src/cli/add.zig` — `allow` action
- `src/main.zig` — arg parsing, help text, root plumbing
- `src/bench.zig` — path-matching benchmark case
- `src/test_all.zig` — register `engine/path.zig`
- `README.md`, `src/cli/skill_content.md`, `docs/spec/remaining-work.md`, `Justfile`

**Ordering note.** The spec's Sequencing section lists the applicability fix first because it is the most user-visible. This plan does the `ToolCall` refactor first instead, because the fix is written against `ToolCall`'s shape and doing it in spec order means converting roughly fifteen engine tests twice. The release boundary is unchanged: Tasks 1 through 6 are shippable without any path work.

---

### Task 1: ToolCall context struct

Pure mechanical refactor. No behavior changes; every existing test must still pass with only its call site rewritten.

**TDD exemption.** This task has no behavior to test, so it writes no failing test. Its gate is the existing suite passing unchanged: 251 tests before, 251 after, with only call sites edited.

**Files:**
- Modify: `src/engine/engine.zig:30-93` (signature and body), plus all `test` blocks in the same file
- Modify: `src/cli/check.zig:32`
- Modify: `src/cli/test_cmd.zig:76`

**Interfaces:**
- Produces: `engine.ToolCall` struct and `engine.check(allocator, rules, call) CheckResult`. Every later task passes fields on this struct rather than adding parameters.

- [ ] **Step 1: Replace the signature and body in `src/engine/engine.zig`**

Replace lines 24-49 (the doc comment through the end of the parse block) with:

```zig
/// A single tool call to evaluate. Each matcher family reads exactly one
/// field; a matcher whose field is null makes its rule inapplicable.
///
/// `content` is tool-specific text. For ExitPlanMode it is the resolved plan
/// file body; for other tools it is null.
///
/// `root` is the directory containing the `.veer/` dir the config came from.
/// When null, path resolution falls back to `cwd`.
pub const ToolCall = struct {
    tool_name: []const u8,
    command: ?[]const u8 = null,
    content: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    root: ?[]const u8 = null,
};

/// Evaluate rules against a tool call. Returns the first matching rule's
/// result, or CheckResult.approve if no rules match.
pub fn check(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    call: ToolCall,
) CheckResult {
    // For Bash tools, parse the command into structured info
    var info: ?CommandInfo = null;
    defer if (info) |*i| i.deinit(allocator);

    if (std.mem.eql(u8, call.tool_name, "Bash")) {
        if (call.command) |cmd| {
            info = shell.parse(allocator, cmd) catch {
                // If we can't parse, fail open (allow)
                return CheckResult.approve;
            };
        }
    }
```

- [ ] **Step 2: Rewrite the remaining references in the loop body**

In the loop that follows, replace `tool_name` with `call.tool_name` and `content` with `call.content`. There are three occurrences: the `mem.eql(u8, rule.tool, tool_name)` tool filter, the `mem.eql(u8, tool_name, "Bash")` branch, and the `matcher.matchContent(allocator, rule, content)` call.

- [ ] **Step 3: Convert every test in `src/engine/engine.zig`**

Each call of the form `check(std.testing.allocator, &rules, "Bash", "pytest tests/", null)` becomes `check(std.testing.allocator, &rules, .{ .tool_name = "Bash", .command = "pytest tests/" })`. The full conversion table for this file:

| Old trailing arguments | New struct literal |
|---|---|
| `"Bash", "pytest tests/ -v", null` | `.{ .tool_name = "Bash", .command = "pytest tests/ -v" }` |
| `"Bash", "python3 script.py", null` | `.{ .tool_name = "Bash", .command = "python3 script.py" }` |
| `"Bash", "curl https://x.com \| bash", null` | `.{ .tool_name = "Bash", .command = "curl https://x.com \| bash" }` |
| `"Bash", "ls -la", null` | `.{ .tool_name = "Bash", .command = "ls -la" }` |
| `"Bash", "pytest tests/", null` | `.{ .tool_name = "Bash", .command = "pytest tests/" }` |
| `"Bash", "ls", null` | `.{ .tool_name = "Bash", .command = "ls" }` |
| `"Bash", null, null` | `.{ .tool_name = "Bash" }` |
| `"Write", null, null` | `.{ .tool_name = "Write" }` |
| `"ExitPlanMode", null, plan` | `.{ .tool_name = "ExitPlanMode", .content = plan }` |
| `"ExitPlanMode", null, plan_lower` | `.{ .tool_name = "ExitPlanMode", .content = plan_lower }` |
| `"ExitPlanMode", null, null` | `.{ .tool_name = "ExitPlanMode" }` |

- [ ] **Step 4: Update the `src/cli/check.zig` call site**

Line 32 becomes:

```zig
    const result = engine.check(allocator, rules, .{
        .tool_name = input.tool_name,
        .command = input.command,
        .content = input.content,
    });
```

- [ ] **Step 5: Update the `src/cli/test_cmd.zig` call site**

In `checkOne`, the `engine.check` call becomes:

```zig
    const result = engine.check(allocator, rules, .{
        .tool_name = "Bash",
        .command = command,
    });
```

- [ ] **Step 6: Run the full suite**

Run: `just check`
Expected: PASS. 251 tests. If any test fails, a call site was missed; the compiler names the file and line.

- [ ] **Step 7: Commit**

```bash
git add src/engine/engine.zig src/cli/check.zig src/cli/test_cmd.zig
git commit -m "$(cat <<'EOF'
refactor: pass a ToolCall context struct to engine.check

Positional parameters meant every new field a rule could match on
required touching both call sites. No behavior change.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Matcher field partition and applicability

The always-fire fix. A rule whose matcher reads a field the call does not carry is skipped entirely, rather than degrading to a tool-name match.

**Files:**
- Modify: `src/config/rule.zig` (add `FieldSet` and `fieldsUsed` after `MatchConfig`)
- Modify: `src/engine/engine.zig` (replace the loop body)
- Test: same two files, `test` blocks at the bottom

**Interfaces:**
- Consumes: `engine.ToolCall` from Task 1.
- Produces: `rule_mod.FieldSet` (`{ command: bool, content: bool, path: bool }`) and `rule_mod.fieldsUsed(m: MatchConfig) FieldSet`. Task 3 uses these for validation; Task 10 sets the `path` field.

- [ ] **Step 1: Write the failing test in `src/engine/engine.zig`**

This is the exact rule from the bug report. Today it rejects every `Write`.

```zig
test "raw_regex rule does not fire on a tool that carries no command" {
    const rules = [_]Rule{.{
        .id = "probe",
        .tool = "Write",
        .action = .reject,
        .message = "M",
        .match = .{ .raw_regex = "ZZZNOTPRESENT" },
    }};

    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/tmp/scratch.txt",
    });
    try std.testing.expect(result.action == null);
}

test "content rule does not fire on a Bash call" {
    const rules = [_]Rule{.{
        .id = "no-actually",
        .tool = "Bash",
        .message = "M",
        .match = .{ .content_contains = "actually" },
    }};

    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "Bash",
        .command = "ls -la",
    });
    try std.testing.expect(result.action == null);
}

test "tool-name-only rule still fires" {
    const rules = [_]Rule{.{
        .id = "no-notebooks",
        .tool = "NotebookEdit",
        .message = "Notebooks are off-limits.",
        .match = .{ .command = "NotebookEdit" },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "NotebookEdit" });
    try std.testing.expect(result.action == null);
}
```

The third test is deliberately the *current* shape of a tool-name-only rule, which abuses `command` as a placeholder to satisfy `hasAnyMatch`. After this task it correctly does not fire, because `command` is null on a NotebookEdit call. Task 12 gives such rules a real expression via `tool_any` with an empty match, and Task 3's validation makes the abuse a load-time error.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test`
Expected: the first two FAIL. `raw_regex rule does not fire...` fails because the rule currently rejects; `content rule does not fire on a Bash call` fails because the Bash arm ignores content matchers and the rule has no per-command fields, so `matchRule` returns `CROSS_COMMAND_MATCH`. The third passes already but guards the behavior through the change.

- [ ] **Step 3: Add `FieldSet` and `fieldsUsed` to `src/config/rule.zig`**

Insert directly after the `MatchConfig` struct definition:

```zig
/// Which ToolCall fields a rule's matchers read. A matcher whose field is
/// null on the call makes the whole rule inapplicable.
pub const FieldSet = struct {
    command: bool = false,
    content: bool = false,
    path: bool = false,
};

/// Partition a match config by the ToolCall field each matcher family reads.
pub fn fieldsUsed(m: MatchConfig) FieldSet {
    return .{
        .command = m.command != null or m.command_any != null or
            m.command_all != null or m.command_regex != null or
            m.flag != null or m.flag_any != null or m.flag_all != null or
            m.arg != null or m.arg_any != null or m.arg_all != null or
            m.arg_regex != null or m.raw_regex != null or m.ast != null,
        .content = m.content_regex != null or m.content_contains != null,
        .path = false,
    };
}
```

The `path` field is wired up in Task 10, when the `path*` matchers exist.

- [ ] **Step 4: Replace the evaluation loop in `src/engine/engine.zig`**

Replace the entire `for (rules) |rule| { ... }` body (currently lines 51-93) with:

```zig
    for (rules) |rule| {
        if (!rule.enabled) continue;

        // Skip rules for different tools
        if (!std.mem.eql(u8, rule.tool, call.tool_name)) continue;

        // A matcher that reads a field this call does not carry cannot be
        // evaluated. Skip the whole rule rather than failing the individual
        // matcher: an unsatisfiable matcher would make a future gate reject
        // on missing data, and veer fails open.
        const fields = rule_mod.fieldsUsed(rule.match);
        if (fields.command and call.command == null) continue;
        if (fields.content and call.content == null) continue;

        var match_start: ?u32 = null;
        var match_end: ?u32 = null;

        if (fields.command) {
            const parsed = info orelse continue;
            const match_idx = matcher.matchRule(rule, parsed) orelse continue;
            if (match_idx != matcher.CROSS_COMMAND_MATCH and
                match_idx < parsed.commands.items.len)
            {
                const matched_cmd = parsed.commands.items[match_idx];
                match_start = matched_cmd.start_byte;
                match_end = matched_cmd.end_byte;
            }
        }

        if (!matcher.matchContent(allocator, rule, call.content)) continue;

        return .{
            .action = rule.effectiveAction(),
            .rule_id = rule.id,
            .message = rule.message,
            .rewrite_to = rule.rewrite_to,
            .match_start = match_start,
            .match_end = match_end,
        };
    }
```

Add the import at the top of the file, next to the existing `Rule` import:

```zig
const rule_mod = @import("../config/rule.zig");
```

- [ ] **Step 5: Update the `matchContent` doc comment in `src/engine/matcher.zig:214-219`**

The comment says "Used by non-Bash tool rules" and describes returning false when content is null. The null case can no longer be reached, because the engine skips the rule first. Replace lines 214-222 with:

```zig
/// Match a rule's content matchers (content_regex, content_contains) against
/// a string. Returns true when all configured content matchers match, and
/// true when the rule has no content matchers at all.
///
/// The engine skips any rule whose content matchers have no content to read,
/// so `content` is non-null whenever this has matchers to apply. The null
/// branch is kept as a fail-open guard for direct callers.
///
/// Takes an allocator because content (e.g., a plan file) can be larger than
/// the fixed stack buffer used by the command-line `regexMatch`.
```

- [ ] **Step 6: Run the tests**

Run: `just check`
Expected: PASS, including the two new tests.

- [ ] **Step 7: Commit**

```bash
git add src/config/rule.zig src/engine/engine.zig src/engine/matcher.zig
git commit -m "$(cat <<'EOF'
fix: skip rules whose matchers read a field the call lacks

A non-Bash rule consulted only content matchers, so a rule carrying any
other matcher fired on tool name alone. A raw_regex rule on Write blocked
every Write in the session.

Each matcher family now declares which ToolCall field it reads, and a rule
whose matcher reads a null field is skipped. This holds for tools veer has
never heard of, including MCP tools.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Validate matcher/tool compatibility

Turns a silently-never-firing rule into a load-time error naming the field and the tool.

**Files:**
- Modify: `src/config/rule.zig` (add `toolFields`, a `ValidationError` variant, a check in `validate`)
- Modify: `src/cli/validate_cmd.zig` (add the per-rule issue string)
- Test: `src/config/rule.zig` test block

**Interfaces:**
- Consumes: `rule_mod.FieldSet`, `rule_mod.fieldsUsed` from Task 2.
- Produces: `rule_mod.toolFields(tool: []const u8) ?FieldSet`. Task 10 adds `path` entries; Task 11 uses it to reject Bash matchers on an allow rule.

- [ ] **Step 1: Write the failing tests in `src/config/rule.zig`**

```zig
test "raw_regex on a Write rule fails validation" {
    const rules = [_]Rule{.{
        .id = "probe",
        .tool = "Write",
        .message = "M",
        .match = .{ .raw_regex = "x" },
    }};
    try std.testing.expectError(ValidationError.MatcherToolMismatch, validate(&rules));
}

test "content matcher on a Bash rule fails validation" {
    const rules = [_]Rule{.{
        .id = "probe",
        .tool = "Bash",
        .message = "M",
        .match = .{ .content_contains = "actually" },
    }};
    try std.testing.expectError(ValidationError.MatcherToolMismatch, validate(&rules));
}

test "unknown tool names are exempt from compatibility validation" {
    const rules = [_]Rule{.{
        .id = "mcp-rule",
        .tool = "mcp__filesystem__write_file",
        .message = "M",
        .match = .{ .raw_regex = "x" },
    }};
    try validate(&rules);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test`
Expected: FAIL. `ValidationError.MatcherToolMismatch` does not exist, so this is a compile error naming the missing enum field. That is the correct failure.

- [ ] **Step 3: Add `toolFields` to `src/config/rule.zig`**

Insert after `fieldsUsed`:

```zig
/// Fields a known tool's input carries. Returns null for tools veer does not
/// recognize, including MCP tools, which exempts them from compatibility
/// validation rather than rejecting them. veer does not bake Claude Code's
/// tool roster into its schema.
pub fn toolFields(tool: []const u8) ?FieldSet {
    if (std.mem.eql(u8, tool, "Bash")) return .{ .command = true };
    if (std.mem.eql(u8, tool, "ExitPlanMode")) return .{ .content = true };

    const path_tools = [_][]const u8{
        "Write", "Edit", "NotebookEdit", "Read", "Grep", "Glob",
    };
    for (path_tools) |t| {
        if (std.mem.eql(u8, tool, t)) return .{ .path = true };
    }
    return null;
}
```

`Write` carries `file_path` only, not `content`. Matching a written file's body is a documented non-goal, so `content_contains` on a `Write` rule is an error naming a feature that does not exist rather than a rule that never fires.

- [ ] **Step 4: Add the error variant and the check**

Add to `ValidationError`:

```zig
    MatcherToolMismatch,
```

Add to `validate`, immediately before the `hasAnyMatch` check:

```zig
        if (toolFields(rule.tool)) |carried| {
            const used = fieldsUsed(rule.match);
            if ((used.command and !carried.command) or
                (used.content and !carried.content) or
                (used.path and !carried.path))
            {
                return ValidationError.MatcherToolMismatch;
            }
        }
```

- [ ] **Step 5: Add the per-rule issue message in `src/cli/validate_cmd.zig`**

`veer validate` reports every issue, not just the first. Add this block after the existing `action == .reject` check, before the `hasAnyMatchPub` check:

```zig
        if (rule_mod.toolFields(rule.tool)) |carried| {
            const used = rule_mod.fieldsUsed(rule.match);
            const bad: ?[]const u8 =
                if (used.command and !carried.command) "command matchers"
                else if (used.content and !carried.content) "content matchers"
                else if (used.path and !carried.path) "path matchers"
                else null;
            if (bad) |what| {
                if (issues_len < issues_buf.len) {
                    issues_buf[issues_len] = what;
                    issues_len += 1;
                }
            }
        }
```

The issue strings are deliberately the matcher family rather than a formatted string, because `issues_buf` holds `[]const u8` with no allocator in scope. The rule id is already printed alongside, so `probe: command matchers` names both halves.

- [ ] **Step 6: Fix the fallout in existing tests**

`src/engine/engine.zig` has a test named `non-Bash tool matching` and one named `non-Bash tool rule doesn't match Bash`, both using `.tool = "Write"` with `.match = .{ .command = "Write" }`. Those rules are now invalid. They do not call `validate`, so they still compile and run, but they encode the abuse this task outlaws. Change both to `.match = .{}` and add `.tool_any` handling later; for now change them to use a valid shape:

```zig
test "non-Bash tool matching" {
    const rules = [_]Rule{.{
        .id = "no-plan-todos",
        .message = "Plans must not contain TODO.",
        .tool = "ExitPlanMode",
        .match = .{ .content_contains = "TODO" },
    }};

    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "ExitPlanMode",
        .content = "# Plan\n\nTODO: figure this out",
    });
    try std.testing.expectEqual(Action.reject, result.action.?);
}

test "non-Bash tool rule doesn't match Bash" {
    const rules = [_]Rule{.{
        .id = "no-plan-todos",
        .message = "blocked",
        .tool = "ExitPlanMode",
        .match = .{ .content_contains = "TODO" },
    }};

    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "Bash",
        .command = "ls",
    });
    try std.testing.expect(result.action == null);
}
```

Also delete the `tool-name-only rule still fires` test added in Task 2 Step 1. It asserted the pre-existing shape, and that shape is now a validation error. Task 12 adds a replacement using `tool_any` with an empty match.

- [ ] **Step 7: Run the tests**

Run: `just check`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add src/config/rule.zig src/cli/validate_cmd.zig src/engine/engine.zig
git commit -m "$(cat <<'EOF'
feat: reject rules whose matchers a tool cannot carry

A raw_regex matcher on a Write rule now fails at load time instead of
never firing. Unknown tool names, including mcp__* tools, are exempt so
the schema does not encode Claude Code's tool roster.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: `veer test` reaches non-Bash rules

`test_cmd.zig` hardcodes `"Bash"`, so the documented "test before committing a rule" workflow cannot touch a Write, Edit, or ExitPlanMode rule at all.

**Files:**
- Modify: `src/cli/test_cmd.zig` (`TestOptions`, `run`, `checkOne`)
- Modify: `src/main.zig:651-664` (`runTest` clap params)
- Test: `src/cli/test_cmd.zig` test block

**Interfaces:**
- Consumes: `engine.ToolCall` from Task 1.
- Produces: `test_cmd.TestOptions` gains `tool: []const u8 = "Bash"`, `path: ?[]const u8`, `content_file: ?[]const u8`. Task 10 relies on `--path` to red/green the path matchers.

- [ ] **Step 1: Write the failing test in `src/cli/test_cmd.zig`**

```zig
test "run with --tool and --path evaluates a non-Bash rule" {
    const rules = [_]Rule{.{
        .id = "no-plan-todos",
        .tool = "ExitPlanMode",
        .message = "Plans must not contain TODO.",
        .match = .{ .content_contains = "TODO" },
    }};

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    // A Write call must not trip an ExitPlanMode rule.
    _ = try run(std.testing.allocator, &rules, null, .{
        .tool = "Write",
        .path = "src/App.vue",
    }, stream.writer());

    const out = stream.getWritten();
    try std.testing.expect(std.mem.startsWith(u8, out, "ALLOW\t"));
    try std.testing.expect(std.mem.indexOf(u8, out, "src/App.vue") != null);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `just test`
Expected: FAIL to compile. `TestOptions` has no `tool` or `path` field.

- [ ] **Step 3: Extend `TestOptions` and `run` in `src/cli/test_cmd.zig`**

Replace the `TestOptions` struct with:

```zig
pub const TestOptions = struct {
    command: ?[]const u8 = null,
    /// File of commands to test, one per line. Bash only.
    file_path: ?[]const u8 = null,
    /// Tool name to evaluate against. Defaults to Bash so every existing
    /// invocation is unchanged.
    tool: []const u8 = "Bash",
    /// Target path, for rules on tools that carry one.
    path: ?[]const u8 = null,
    /// File whose body stands in for the tool's content, e.g. a plan body.
    content_file: ?[]const u8 = null,
};
```

Replace the body of `run` with:

```zig
    if (sources) |s| std.debug.assert(s.len == rules.len);

    if (opts.file_path) |path| {
        return runFile(allocator, rules, sources, path, writer);
    }

    const is_bash = std.mem.eql(u8, opts.tool, "Bash");

    if (is_bash and opts.path == null and opts.content_file == null) {
        const command = opts.command orelse {
            try writer.print("veer test: command argument or --file required\n", .{});
            try writer.print("Usage: veer test \"<command>\" [--config <path>]\n", .{});
            try writer.print("       veer test --file <path> [--config <path>]\n", .{});
            try writer.print("       veer test --tool <Tool> --path <path>\n", .{});
            return 1;
        };
        return checkOne(allocator, rules, sources, command, writer);
    }

    const content: ?[]u8 = if (opts.content_file) |cf|
        std.fs.cwd().readFileAlloc(allocator, cf, 4 * 1024 * 1024) catch {
            try writer.print("veer test: cannot read {s}\n", .{cf});
            return 1;
        }
    else
        null;
    defer if (content) |c| allocator.free(c);

    const cwd_abs = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
    defer if (cwd_abs) |c| allocator.free(c);

    return checkCall(allocator, rules, sources, .{
        .tool_name = opts.tool,
        .command = opts.command,
        .content = content,
        .file_path = opts.path,
        .cwd = cwd_abs,
        .root = cwd_abs,
    }, opts.path orelse opts.content_file orelse opts.command orelse "", writer);
```

- [ ] **Step 4: Split `checkOne` so both paths share the reporting**

Rename the existing `checkOne` body into a new `checkCall` that takes a prepared `ToolCall` and the label to print in the `input` column, and make `checkOne` a thin wrapper:

```zig
fn checkOne(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    sources: ?[]const config_mod.RuleSource,
    command: []const u8,
    writer: anytype,
) !u8 {
    return checkCall(allocator, rules, sources, .{
        .tool_name = "Bash",
        .command = command,
    }, command, writer);
}

fn checkCall(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    sources: ?[]const config_mod.RuleSource,
    call: engine.ToolCall,
    label: []const u8,
    writer: anytype,
) !u8 {
    const result = engine.check(allocator, rules, call);
    ...
}
```

Inside `checkCall`, every existing use of `command` in the print statements becomes `label`, and `spliceRewrite`'s first argument becomes `call.command orelse label`. The TSV column order and the `src_suffix` logic are unchanged.

- [ ] **Step 5: Add the clap params in `src/main.zig:651-664`**

Replace the params block in `runTest` with:

```zig
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\    --config <str>        Path to config file.
        \\    --file <str>          File containing commands to test (one per line).
        \\    --tool <str>          Tool name to evaluate against (default: Bash).
        \\    --path <str>          Target path, for tools that carry one.
        \\    --content-file <str>  File whose body stands in for tool content.
        \\<str>
        \\
    );
```

and the options construction with:

```zig
    const opts = test_cmd.TestOptions{
        .command = res.positionals[0],
        .file_path = res.args.file,
        .tool = res.args.tool orelse "Bash",
        .path = res.args.path,
        .content_file = res.args.@"content-file",
    };
```

- [ ] **Step 6: Run the tests**

Run: `just check`
Expected: PASS.

- [ ] **Step 7: Verify by hand against the repo's own config**

Run: `just build && ./zig-out/bin/veer test --tool Write --path src/App.vue --config test/configs/basic.toml`
Expected: a single `ALLOW` line with `src/App.vue` in the input column.

- [ ] **Step 8: Commit**

```bash
git add src/cli/test_cmd.zig src/main.zig
git commit -m "$(cat <<'EOF'
feat: veer test reaches non-Bash rules

test_cmd hardcoded "Bash", so the documented test-before-commit workflow
could not touch a Write, Edit, or ExitPlanMode rule. --tool defaults to
Bash, so every existing invocation and the TSV format are unchanged.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: TOML errors name the field

`config.zig:loadString` discards `parser.error_info`, which the library already populates. `main.zig:139-155` exits 2 on a load failure, so one typo blocks every tool call in the session behind `TOML parse error`.

**Files:**
- Modify: `src/config/config.zig` (`loadString`, `loadFile`, new `ParseDetail`)
- Modify: `src/cli/validate_cmd.zig:17-28` (error reporting)
- Modify: `src/main.zig:139-155` (`loadConfigForCheck` message)
- Test: `src/config/config.zig` test block

**Interfaces:**
- Produces: `config_mod.ParseDetail` union and `config_mod.loadStringDetailed(allocator, input, detail_out) !toml.Parsed(Config)` / `config_mod.loadFileDetailed(allocator, path, detail_out)`. `loadString` and `loadFile` stay as wrappers so no other caller changes.
- Produces: `config_mod.parseFileOnly(allocator, path, detail_out) !toml.Parsed(Config)`, which parses without calling `validate()`. This is what makes `validate_cmd`'s per-rule reporting reachable.

**Pre-existing bug this task also fixes.** `validate_cmd.run()`'s entire per-rule detail branch is unreachable and has been since it was written. `loadFile` calls `rule_mod.validate()` internally and returns the `ValidationError`, which `validate_cmd.zig:14` catches in its generic `else` arm and prints as a bare Zig error name. The per-rule loop below only runs when loading succeeds, at which point `validateAll` finds nothing, because it counts exactly the five conditions `validate()` already gated on. So `veer validate` against a config with an invalid rule prints:

```
/tmp/badrule.toml: error.MatcherToolMismatch
```

with no rule id, no field, no line, and only the first error, instead of the multi-issue report the command exists to produce. Verified against the built binary at 0.1.11 behavior. Fixing it here rather than in its own task because this task already rewrites both `config.zig`'s load path and `validate_cmd`'s error handling.

- [ ] **Step 1: Write the failing test in `src/config/config.zig`**

```zig
test "invalid enum value reports the field path" {
    const input =
        \\[[rule]]
        \\id = "x"
        \\action = "nonsense"
        \\message = "m"
        \\[rule.match]
        \\command = "foo"
    ;
    var detail: ?ParseDetail = null;
    defer if (detail) |*d| d.deinit(std.testing.allocator);

    const result = loadStringDetailed(std.testing.allocator, input, &detail);
    try std.testing.expectError(error.ParseFailed, result);

    const d = detail orelse return error.TestExpectedDetail;
    try std.testing.expect(d == .field_path);
    // The failing field is `action` under the `rule` array.
    var joined_seen = false;
    for (d.field_path) |seg| {
        if (std.mem.eql(u8, seg, "action")) joined_seen = true;
    }
    try std.testing.expect(joined_seen);
}

test "syntax error reports a line number" {
    const input =
        \\[[rule]
        \\id = "x"
    ;
    var detail: ?ParseDetail = null;
    defer if (detail) |*d| d.deinit(std.testing.allocator);

    const result = loadStringDetailed(std.testing.allocator, input, &detail);
    try std.testing.expectError(error.ParseFailed, result);

    const d = detail orelse return error.TestExpectedDetail;
    try std.testing.expect(d == .position);
    try std.testing.expect(d.position.line >= 1);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `just test`
Expected: FAIL to compile. `ParseDetail` and `loadStringDetailed` do not exist.

- [ ] **Step 3: Add `ParseDetail` and the detailed loaders to `src/config/config.zig`**

Insert above `loadString`:

```zig
/// Why a config file failed to parse. `position` is a TOML syntax error;
/// `field_path` is a schema error, such as an invalid enum value, and names
/// the struct path that failed to map.
pub const ParseDetail = union(enum) {
    position: struct { line: usize, column: usize },
    field_path: []const []const u8,

    pub fn deinit(self: *ParseDetail, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .field_path => |fp| allocator.free(fp),
            .position => {},
        }
    }
};
```

Replace `loadString` with:

```zig
pub fn loadString(allocator: std.mem.Allocator, input: []const u8) !toml.Parsed(Config) {
    var detail: ?ParseDetail = null;
    defer if (detail) |*d| d.deinit(allocator);
    return loadStringDetailed(allocator, input, &detail);
}

/// Like loadString, but writes the reason for a parse failure to `detail_out`
/// when one is available. The caller owns `detail_out` and must call its
/// deinit. The parser frees its own copy on deinit, so the field path is
/// duped here; its segments are comptime struct field names and outlive us.
pub fn loadStringDetailed(
    allocator: std.mem.Allocator,
    input: []const u8,
    detail_out: *?ParseDetail,
) !toml.Parsed(Config) {
    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = parser.parseString(input) catch {
        if (parser.error_info) |info| {
            detail_out.* = switch (info) {
                .parse => |pos| .{ .position = .{ .line = pos.line, .column = pos.pos } },
                .struct_mapping => |fp| .{ .field_path = allocator.dupe([]const u8, fp) catch null_path: {
                    break :null_path &.{};
                } },
            };
        }
        return error.ParseFailed;
    };

    validate(result.value.rule) catch |err| {
        result.deinit();
        return err;
    };

    return result;
}
```

Add `loadFileDetailed` alongside `loadFile`, identical except it calls `loadStringDetailed`:

```zig
pub fn loadFileDetailed(
    allocator: std.mem.Allocator,
    path: []const u8,
    detail_out: *?ParseDetail,
) !toml.Parsed(Config) {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return error.FileNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return error.ReadFailed;
    };
    defer allocator.free(content);

    return loadStringDetailed(allocator, content, detail_out);
}
```

- [ ] **Step 4: Report the detail in `src/cli/validate_cmd.zig`**

Replace the `loadFile` call and its `error.ParseFailed` arm (lines 14-28) with:

```zig
    var detail: ?config_mod.ParseDetail = null;
    defer if (detail) |*d| d.deinit(allocator);

    var result = config_mod.loadFileDetailed(allocator, opts.config_path, &detail) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try writer.print("{s}: file not found\n", .{opts.config_path});
                return 1;
            },
            error.ParseFailed => {
                if (detail) |d| switch (d) {
                    .position => |pos| try writer.print(
                        "{s}:{d}:{d}: TOML syntax error\n",
                        .{ opts.config_path, pos.line, pos.column },
                    ),
                    .field_path => |fp| {
                        try writer.print("{s}: invalid value for ", .{opts.config_path});
                        for (fp, 0..) |seg, i| {
                            if (i > 0) try writer.print(".", .{});
                            try writer.print("{s}", .{seg});
                        }
                        try writer.print("\n", .{});
                    },
                } else {
                    try writer.print("{s}: TOML parse error\n", .{opts.config_path});
                }
                return 1;
            },
            else => {
                try writer.print("{s}: {}\n", .{ opts.config_path, err });
                return 1;
            },
        }
    };
```

- [ ] **Step 5: Point the hot path at the detail in `src/main.zig`**

In `loadConfigForCheck`, replace the explicit-path branch's `else |_|` arm with one that uses the detailed loader. The exit code stays 2; only the message improves:

```zig
    if (config_path) |path| {
        var detail: ?config_mod.ParseDetail = null;
        defer if (detail) |*d| d.deinit(allocator);

        if (config_mod.loadFileDetailed(allocator, path, &detail)) |result| {
            return .{
                .rules = result.value.rule,
                .settings = result.value.settings,
                .parsed_file = result,
                .merged = null,
                .sources = null,
            };
        } else |_| {
            std.debug.print("veer: failed to load config at {s}\n", .{path});
            if (detail) |d| switch (d) {
                .position => |pos| std.debug.print("  TOML syntax error at line {d}, column {d}\n", .{ pos.line, pos.column }),
                .field_path => |fp| {
                    std.debug.print("  invalid value for ", .{});
                    for (fp, 0..) |seg, i| {
                        if (i > 0) std.debug.print(".", .{});
                        std.debug.print("{s}", .{seg});
                    }
                    std.debug.print("\n", .{});
                },
            };
            std.debug.print("Fix the file or run 'veer uninstall' to remove the hook.\n", .{});
            std.process.exit(2);
        }
    }
```

- [ ] **Step 5b: Make the per-rule reporting reachable**

Add a parse-only entry point to `src/config/config.zig`, alongside `loadStringDetailed`:

```zig
/// Parse a config file without running rule validation. `validate_cmd` uses
/// this so it can report every rule's issues, rather than stopping at the
/// first error `validate` returns.
pub fn parseFileOnly(
    allocator: std.mem.Allocator,
    path: []const u8,
    detail_out: *?ParseDetail,
) !toml.Parsed(Config) {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return error.FileNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return error.ReadFailed;
    };
    defer allocator.free(content);

    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    return parser.parseString(content) catch {
        if (parser.error_info) |info| {
            detail_out.* = switch (info) {
                .parse => |pos| .{ .position = .{ .line = pos.line, .column = pos.pos } },
                .struct_mapping => |fp| .{ .field_path = allocator.dupe([]const u8, fp) catch null },
            };
        }
        return error.ParseFailed;
    };
}
```

Note `catch null` on the dupe: on allocation failure the detail is simply absent, and the caller falls back to its generic message. `ParseDetail.deinit` must tolerate a null `field_path`, so make the union's `field_path` payload optional or guard the free.

In `src/cli/validate_cmd.zig`, change the loader call from `loadFileDetailed` to `parseFileOnly`. The `FileNotFound` and `ParseFailed` arms are unchanged. Deleting the now-unneeded `else` arm is not required, but the `ValidationError` variants can no longer reach it, because `parseFileOnly` never calls `validate`.

- [ ] **Step 5c: Write the test proving every issue is reported**

In `src/cli/validate_cmd.zig`'s test block:

```zig
test "validate reports every invalid rule, not just the first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/c.toml", .{dir});
    defer std.testing.allocator.free(path);
    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(
            \\[[rule]]
            \\id = "first-bad"
            \\tool = "Write"
            \\message = "m"
            \\[rule.match]
            \\raw_regex = "x"
            \\
            \\[[rule]]
            \\id = "second-bad"
            \\tool = "Bash"
            \\[rule.match]
            \\command = "foo"
        );
    }

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const code = try run(std.testing.allocator, .{ .config_path = path }, stream.writer());

    const out = stream.getWritten();
    try std.testing.expectEqual(@as(u8, 1), code);
    // Both rules must appear, not just the first.
    try std.testing.expect(std.mem.indexOf(u8, out, "first-bad") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second-bad") != null);
}
```

The second rule is invalid for a different reason (a reject with no message), so the test proves the loop reports distinct issues across rules rather than repeating one.

- [ ] **Step 6: Run the tests**

Run: `just check`
Expected: PASS.

- [ ] **Step 7: Verify by hand**

```bash
just build
printf '[[rule]]\nid = "x"\naction = "nonsense"\nmessage = "m"\n[rule.match]\ncommand = "foo"\n' > /tmp/bad.toml
./zig-out/bin/veer validate --config /tmp/bad.toml

printf '[[rule]]\nid = "probe"\ntool = "Write"\nmessage = "M"\n[rule.match]\nraw_regex = "x"\n' > /tmp/badrule.toml
./zig-out/bin/veer validate --config /tmp/badrule.toml
```
Expected: the first names `action`, not `TOML parse error`. The second names the rule id `probe` and its matcher family, not `error.MatcherToolMismatch`.

- [ ] **Step 8: Commit**

```bash
git add src/config/config.zig src/cli/validate_cmd.zig src/main.zig
git commit -m "$(cat <<'EOF'
feat: name the field in TOML schema errors

loadString discarded parser.error_info, so an invalid enum value reported
as "TOML parse error" and had to be bisected line by line. The check hot
path exits 2 on a load failure, so one typo blocked every tool call in the
session behind that message.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Correct the `--action` help text

`main.zig:454` advertises `allow, deny, rewrite, warn`. None of `allow`, `deny`, or `warn` parse. Task 11 adds `allow` and updates this line again; this task makes it true today.

**TDD exemption.** Text-only change with no behavior to test. Its gate is `just check` passing, which includes `zig fmt --check` and the `check-help` smoke recipe.

**Files:**
- Modify: `src/main.zig:454`
- Modify: `src/cli/add.zig:24,34`

- [ ] **Step 1: Fix the clap help line in `src/main.zig:454`**

```zig
        \\    --action <str>      Rule action (reject, rewrite).
```

- [ ] **Step 2: Confirm the `add.zig` messages already match**

`add.zig:24` prints `--action is required (rewrite, reject)` and `add.zig:34` prints `must be rewrite or reject`. Both are already accurate. No change.

- [ ] **Step 3: Run the suite**

Run: `just check`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/main.zig
git commit -m "$(cat <<'EOF'
docs: veer add --help listed actions that do not parse

Advertised allow, deny, rewrite, and warn; only reject and rewrite parse.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

**Release boundary.** Tasks 1 through 6 are independently useful to every veer user and carry no path concepts. If cutting a release here, bump the version with `just bump` before starting Task 7.

---

### Task 7: Extract `file_path` and `cwd` from the hook envelope

**Files:**
- Modify: `src/claude/hook.zig` (`HookInput`, `parseInput`, `freeInput`)
- Modify: `src/cli/check.zig:32`
- Test: `src/claude/hook.zig` test block

**Interfaces:**
- Produces: `HookInput.file_path` and `HookInput.cwd`, both `?[]const u8` and owned by the input. Task 10 matches against `file_path`; Task 8 resolves it against `cwd`.

- [ ] **Step 1: Write the failing tests in `src/claude/hook.zig`**

Replace the existing `parseInput non-Bash tool` test (lines 222-232), which asserts only `tool_name`, with:

```zig
test "parseInput extracts file_path for a Write" {
    const json =
        \\{"tool_name":"Write","tool_input":{"file_path":"/etc/passwd","content":"..."},"cwd":"/home/me/proj"}
    ;
    var input = try parseInput(std.testing.allocator, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("Write", input.tool_name);
    try std.testing.expect(input.command == null);
    try std.testing.expect(input.content == null);
    try std.testing.expectEqualStrings("/etc/passwd", input.file_path.?);
    try std.testing.expectEqualStrings("/home/me/proj", input.cwd.?);
}

test "parseInput falls back to notebook_path then path" {
    const notebook =
        \\{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/a/nb.ipynb"}}
    ;
    var nb = try parseInput(std.testing.allocator, notebook);
    defer freeInput(std.testing.allocator, &nb);
    try std.testing.expectEqualStrings("/a/nb.ipynb", nb.file_path.?);

    const grep =
        \\{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"/a/src"}}
    ;
    var g = try parseInput(std.testing.allocator, grep);
    defer freeInput(std.testing.allocator, &g);
    try std.testing.expectEqualStrings("/a/src", g.file_path.?);
}

test "parseInput leaves file_path null when no path key is present" {
    const json =
        \\{"tool_name":"Bash","tool_input":{"command":"ls"}}
    ;
    var input = try parseInput(std.testing.allocator, json);
    defer freeInput(std.testing.allocator, &input);
    try std.testing.expect(input.file_path == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `just test`
Expected: FAIL to compile. `HookInput` has no `file_path` or `cwd`.

- [ ] **Step 3: Add the fields to `HookInput`**

```zig
pub const HookInput = struct {
    tool_name: []const u8,
    command: ?[]const u8, // Extracted from tool_input.command for Bash tools
    session_id: ?[]const u8,
    transcript_path: ?[]const u8,
    /// Tool-specific text content for content_regex / content_contains
    /// matching. For ExitPlanMode, this is the resolved plan file body. Null
    /// for tools where no content extractor is wired up (or where extraction
    /// failed -- callers must treat null as "no match" rather than "match").
    content: ?[]const u8,
    /// Target path, from tool_input.file_path, notebook_path, or path,
    /// whichever appears first. Tool-name agnostic, so an MCP tool carrying
    /// file_path works without a veer release.
    file_path: ?[]const u8,
    /// Session working directory, from the envelope root. Used to resolve a
    /// relative file_path.
    cwd: ?[]const u8,
};
```

- [ ] **Step 4: Extract them in `parseInput`**

Insert after the `transcript_path` block, before the content extraction:

```zig
    const file_path: ?[]const u8 = blk: {
        const tool_input = root.object.get("tool_input") orelse break :blk null;
        if (tool_input != .object) break :blk null;
        const keys = [_][]const u8{ "file_path", "notebook_path", "path" };
        for (keys) |key| {
            const val = tool_input.object.get(key) orelse continue;
            if (val != .string) continue;
            break :blk try allocator.dupe(u8, val.string);
        }
        break :blk null;
    };
    errdefer if (file_path) |fp| allocator.free(fp);

    const cwd: ?[]const u8 = blk: {
        const val = root.object.get("cwd") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk try allocator.dupe(u8, val.string);
    };
    errdefer if (cwd) |c| allocator.free(c);
```

Add both to the returned struct literal.

- [ ] **Step 5: Free them in `freeInput`**

```zig
    if (input.file_path) |fp| allocator.free(fp);
    if (input.cwd) |c| allocator.free(c);
```

- [ ] **Step 6: Pass them through in `src/cli/check.zig`**

```zig
    const result = engine.check(allocator, rules, .{
        .tool_name = input.tool_name,
        .command = input.command,
        .content = input.content,
        .file_path = input.file_path,
        .cwd = input.cwd,
    });
```

`root` is wired in Task 8.

- [ ] **Step 7: Run the tests**

Run: `just check`
Expected: PASS. `std.testing.allocator` will fail the test if either new field leaks.

- [ ] **Step 8: Commit**

```bash
git add src/claude/hook.zig src/cli/check.zig
git commit -m "$(cat <<'EOF'
feat: carry file_path and cwd from the hook envelope

tool_input.file_path was read and discarded. The extractor tries
file_path, notebook_path, then path, with no tool-name table, so a tool
veer has never heard of works if it carries one of those keys.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: Path resolution

**Files:**
- Create: `src/engine/path.zig`
- Modify: `src/test_all.zig`
- Modify: `src/config/config.zig` (add `MergedConfig.projectRoot`)
- Modify: `src/main.zig`, `src/cli/check.zig` (plumb `root`)

**Interfaces:**
- Produces: `path.Resolved { absolute: []const u8, relative: ?[]const u8 }` and `path.resolve(raw, cwd, root, buf) ?Resolved`. `relative` is a slice into `absolute`, which is a slice into `buf`. Task 10 matches patterns against these two forms.
- Produces: `config_mod.MergedConfig.projectRoot() ?[]const u8`, a slice into `project_config_path` with no allocation.

- [ ] **Step 1: Create `src/engine/path.zig` with the failing tests only**

```zig
// ABOUTME: Path resolution and glob matching for veer's path* matchers.
// ABOUTME: Lexical normalization only; no realpath, no stat, no symlinks.

const std = @import("std");

// -- Tests --

test "resolve makes a relative path absolute against cwd" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("src/App.vue", "/home/me/proj", "/home/me/proj", &buf).?;
    try std.testing.expectEqualStrings("/home/me/proj/src/App.vue", r.absolute);
    try std.testing.expectEqualStrings("src/App.vue", r.relative.?);
}

test "resolve collapses dot and dot-dot segments" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/apps/../apps/./x.ts", null, "/home/me/proj", &buf).?;
    try std.testing.expectEqualStrings("/home/me/proj/apps/x.ts", r.absolute);
    try std.testing.expectEqualStrings("apps/x.ts", r.relative.?);
}

test "resolve leaves a path outside root with no relative form" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/tmp/scratch.txt", null, "/home/me/proj", &buf).?;
    try std.testing.expectEqualStrings("/tmp/scratch.txt", r.absolute);
    try std.testing.expect(r.relative == null);
}

test "resolve does not treat a sibling directory as inside root" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj-other/x.ts", null, "/home/me/proj", &buf).?;
    try std.testing.expect(r.relative == null);
}

test "resolve falls back to cwd when root is null" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/a.ts", "/home/me/proj", null, &buf).?;
    try std.testing.expectEqualStrings("a.ts", r.relative.?);
}
```

The fourth test guards the prefix-comparison bug: `/home/me/proj-other` starts with `/home/me/proj` as a string but is not inside it.

- [ ] **Step 2: Register the module and run to verify failure**

Add to `src/test_all.zig`, next to the other engine imports:

```zig
    _ = @import("engine/path.zig");
```

Run: `just test`
Expected: FAIL to compile. `resolve` is not defined.

- [ ] **Step 3: Implement `resolve` in `src/engine/path.zig`**

Insert above the test block:

```zig
/// A tool call's target path in both the forms a pattern can match against.
/// `relative` is a slice into `absolute` and is null when the path is not
/// inside `root`, which is what makes a relative pattern unable to reach
/// outside the project.
pub const Resolved = struct {
    absolute: []const u8,
    relative: ?[]const u8,
};

/// Normalize `raw` into `buf` and locate it relative to `root`.
///
/// Lexical only: `.` and `..` are resolved textually and symlinks are left
/// alone. Write creates files that do not exist yet, so realpath would fail
/// on exactly the calls most worth catching, and syscalls do not belong in
/// the hot path.
///
/// Returns null when the result does not fit in `buf`, or when `raw` is
/// relative and both `cwd` and `root` are null.
pub fn resolve(
    raw: []const u8,
    cwd: ?[]const u8,
    root: ?[]const u8,
    buf: []u8,
) ?Resolved {
    const base = root orelse cwd;

    var joined_buf: [std.fs.max_path_bytes]u8 = undefined;
    const joined: []const u8 = if (raw.len > 0 and raw[0] == '/')
        raw
    else blk: {
        const anchor = cwd orelse base orelse return null;
        const need = anchor.len + 1 + raw.len;
        if (need > joined_buf.len) return null;
        @memcpy(joined_buf[0..anchor.len], anchor);
        joined_buf[anchor.len] = '/';
        @memcpy(joined_buf[anchor.len + 1 ..][0..raw.len], raw);
        break :blk joined_buf[0..need];
    };

    const absolute = normalize(joined, buf) orelse return null;

    const r = base orelse return .{ .absolute = absolute, .relative = null };
    if (!isUnder(absolute, r)) return .{ .absolute = absolute, .relative = null };

    // +1 skips the separator. Equal-length means the path IS the root, which
    // has no relative form.
    if (absolute.len <= r.len + 1) return .{ .absolute = absolute, .relative = null };
    return .{ .absolute = absolute, .relative = absolute[r.len + 1 ..] };
}

/// True when `path` is `root` itself or lives inside it. Compares whole
/// segments, so /a/proj-other is not inside /a/proj.
fn isUnder(path: []const u8, root: []const u8) bool {
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == '/';
}

/// Collapse repeated separators and resolve `.` and `..` textually. Writes
/// into `buf` and returns the slice, or null if it does not fit.
fn normalize(path: []const u8, buf: []u8) ?[]const u8 {
    var stack: [128][]const u8 = undefined;
    var depth: usize = 0;

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth >= stack.len) return null;
        stack[depth] = seg;
        depth += 1;
    }

    var len: usize = 0;
    for (stack[0..depth]) |seg| {
        if (len + 1 + seg.len > buf.len) return null;
        buf[len] = '/';
        len += 1;
        @memcpy(buf[len..][0..seg.len], seg);
        len += seg.len;
    }
    if (len == 0) {
        if (buf.len < 1) return null;
        buf[0] = '/';
        len = 1;
    }
    return buf[0..len];
}
```

- [ ] **Step 4: Run the tests**

Run: `just test`
Expected: PASS, five new tests.

- [ ] **Step 5: Add `projectRoot` to `src/config/config.zig`**

Insert into the `MergedConfig` struct, next to `deinit`:

```zig
    /// The directory containing the `.veer/` dir the project config came
    /// from. A slice into `project_config_path`; no allocation. Null when no
    /// project config was found.
    pub fn projectRoot(self: MergedConfig) ?[]const u8 {
        const pp = self.project_config_path orelse return null;
        const veer_dir = std.fs.path.dirname(pp) orelse return null;
        return std.fs.path.dirname(veer_dir);
    }
```

- [ ] **Step 6: Write the test for `projectRoot`**

In the `src/config/config.zig` test block:

```zig
test "projectRoot strips the .veer/config.toml suffix" {
    var merged = MergedConfig{};
    merged.project_config_path = "/home/me/proj/.veer/config.toml";
    try std.testing.expectEqualStrings("/home/me/proj", merged.projectRoot().?);

    var empty = MergedConfig{};
    try std.testing.expect(empty.projectRoot() == null);
}
```

The literal is not heap-allocated and `deinit` is never called on these, so there is nothing to free.

- [ ] **Step 7: Plumb `root` through `src/cli/check.zig` and `src/main.zig`**

Add a parameter to `check_cmd.run`, after `rules`:

```zig
pub fn run(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    root: ?[]const u8,
    stdin_data: []const u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
    verbose: bool,
) !u8 {
```

and pass it into the call:

```zig
    const result = engine.check(allocator, rules, .{
        .tool_name = input.tool_name,
        .command = input.command,
        .content = input.content,
        .file_path = input.file_path,
        .cwd = input.cwd,
        .root = root,
    });
```

In `main.zig`'s `runCheck`, compute it from the loaded config and pass it:

```zig
    const root: ?[]const u8 = if (loaded.merged) |m| m.projectRoot() else null;
```

Every existing `check_cmd.run(...)` call in `src/cli/check.zig`'s own test block gains `null` in the new position.

- [ ] **Step 8: Run the suite**

Run: `just check`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/engine/path.zig src/test_all.zig src/config/config.zig src/cli/check.zig src/main.zig
git commit -m "$(cat <<'EOF'
feat: resolve a tool call's target path against the config root

Lexical normalization only. A path outside the root gets no relative form,
which is what stops a relative pattern from reaching outside the project.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: Segment-wise glob matching

**Files:**
- Modify: `src/engine/path.zig`
- Test: same file

**Interfaces:**
- Consumes: `matcher.globMatch(pattern, text)`, which is already `pub` at `matcher.zig:255`. Reused per segment, which gives `?` and `{a,b}` brace expansion for free. `globMatch`'s `*` crosses `/`, but a segment contains no `/`, so it is safe.
- Produces: `path.PathPattern`, `path.classifyPattern(pattern) PathPattern`, and `path.matches(pattern, resolved, home) bool`. Task 10 calls `matches`.

- [ ] **Step 1: Write the failing tests in `src/engine/path.zig`**

```zig
test "pathMatch segment semantics" {
    const cases = .{
        // pattern, path, expected
        .{ "src/*", "src/App.vue", true },
        .{ "src/*", "src/ui/Button.vue", false },
        .{ "src/**", "src/App.vue", true },
        .{ "src/**", "src/ui/Button.vue", true },
        .{ "a/**/b", "a/b", true },
        .{ "a/**/b", "a/x/b", true },
        .{ "a/**/b", "a/x/y/b", true },
        .{ "a/**/b", "a/x/y/c", false },
        .{ "**/dist/**", "apps/web/dist/index.js", true },
        .{ "**/dist/**", "dist/index.js", true },
        .{ "**/*.env", "apps/web/.env", true },
        .{ "src/**/*.{ts,vue}", "src/ui/Button.vue", true },
        .{ "src/**/*.{ts,vue}", "src/ui/Button.css", false },
        .{ "a/**/**/**/b", "a/x/y/z/b", true },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[2], pathMatch(c[0], c[1]));
    }
}

test "classifyPattern" {
    const abs = classifyPattern("/etc/**");
    try std.testing.expect(abs.absolute);
    try std.testing.expectEqualStrings("etc/**", abs.body);

    const home = classifyPattern("~/.ssh/**");
    try std.testing.expect(home.absolute);
    try std.testing.expect(home.home_relative);

    const anchored = classifyPattern("./.env");
    try std.testing.expect(!anchored.absolute);
    try std.testing.expect(!anchored.any_depth);
    try std.testing.expectEqualStrings(".env", anchored.body);

    const slashed = classifyPattern("src/**");
    try std.testing.expect(!slashed.any_depth);

    const bare = classifyPattern(".env");
    try std.testing.expect(bare.any_depth);

    const dir = classifyPattern("node_modules/");
    try std.testing.expect(dir.dir_contents);
    try std.testing.expectEqualStrings("node_modules", dir.body);
}

test "matches applies classification to a resolved path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/apps/web/.env", null, "/home/me/proj", &buf).?;

    try std.testing.expect(matches(".env", r, null));
    try std.testing.expect(!matches("./.env", r, null));
    try std.testing.expect(matches("apps/**", r, null));
    try std.testing.expect(!matches("/etc/**", r, null));

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside = resolve("/tmp/scratch.txt", null, "/home/me/proj", &out_buf).?;
    // A relative pattern never reaches outside the root, not even via basename.
    try std.testing.expect(!matches("*", outside, null));
    try std.testing.expect(matches("/tmp/**", outside, null));
}

test "node_modules needs a slash form" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/p/node_modules/left-pad/index.js", null, "/p", &buf).?;
    // Documented limitation: a no-slash pattern matches file names only.
    try std.testing.expect(!matches("node_modules", r, null));
    try std.testing.expect(matches("node_modules/", r, null));
    try std.testing.expect(matches("node_modules/**", r, null));
}
```

- [ ] **Step 2: Run to verify failure**

Run: `just test`
Expected: FAIL to compile. `pathMatch`, `classifyPattern`, and `matches` do not exist.

- [ ] **Step 3: Implement the matcher in `src/engine/path.zig`**

```zig
const matcher = @import("matcher.zig");

/// Maximum segments in a pattern or a path. Deeper inputs do not match.
const max_segments = 128;

/// How a pattern's leading and trailing syntax changes what it is matched
/// against. `body` is a slice of the original pattern with `./` stripped and
/// a trailing `/` trimmed.
pub const PathPattern = struct {
    body: []const u8,
    /// Matched against the absolute path rather than the root-relative one.
    absolute: bool = false,
    /// `body` is relative to $HOME.
    home_relative: bool = false,
    /// Prepend an implicit `**` segment: the pattern matches at any depth.
    any_depth: bool = false,
    /// Append an implicit `**` segment: the pattern matches a directory's
    /// contents.
    dir_contents: bool = false,
};

/// Classify a pattern by its leading and trailing syntax. A trailing `/` is
/// handled first, then the leading form decides anchoring.
pub fn classifyPattern(pattern: []const u8) PathPattern {
    var result = PathPattern{ .body = pattern };
    var body = pattern;

    if (body.len > 1 and body[body.len - 1] == '/') {
        body = body[0 .. body.len - 1];
        result.dir_contents = true;
    }

    if (std.mem.startsWith(u8, body, "~/")) {
        result.absolute = true;
        result.home_relative = true;
        body = body[2..];
    } else if (body.len > 0 and body[0] == '/') {
        result.absolute = true;
        body = body[1..];
    } else if (std.mem.startsWith(u8, body, "./")) {
        body = body[2..];
    } else if (std.mem.indexOfScalar(u8, body, '/') == null) {
        result.any_depth = true;
    }

    result.body = body;
    return result;
}

/// Match a classified pattern against a resolved path. `home` is $HOME, used
/// only for `~/` patterns; pass null to make them never match.
pub fn matches(pattern: []const u8, resolved: Resolved, home: ?[]const u8) bool {
    const pp = classifyPattern(pattern);

    const target: []const u8 = if (pp.absolute) blk: {
        if (!pp.home_relative) break :blk stripLeadingSlash(resolved.absolute);
        const h = home orelse return false;
        if (!isUnder(resolved.absolute, h)) return false;
        if (resolved.absolute.len <= h.len + 1) return false;
        break :blk resolved.absolute[h.len + 1 ..];
    } else resolved.relative orelse return false;

    return matchWithImplicit(pp, target);
}

fn stripLeadingSlash(s: []const u8) []const u8 {
    return if (s.len > 0 and s[0] == '/') s[1..] else s;
}

fn matchWithImplicit(pp: PathPattern, target: []const u8) bool {
    var pat_buf: [max_segments][]const u8 = undefined;
    var n: usize = 0;

    if (pp.any_depth) {
        pat_buf[n] = "**";
        n += 1;
    }
    n = appendSegments(pp.body, &pat_buf, n) orelse return false;
    if (pp.dir_contents) {
        if (n >= pat_buf.len) return false;
        pat_buf[n] = "**";
        n += 1;
    }

    var path_buf: [max_segments][]const u8 = undefined;
    const path_n = appendSegments(target, &path_buf, 0) orelse return false;

    return matchSegments(pat_buf[0..n], path_buf[0..path_n]);
}

/// Split `s` on `/` into `out` starting at `n`, returning the new count.
/// Empty segments are dropped, and a `**` immediately following another `**`
/// is dropped so `a/**/**/b` cannot make the matcher backtrack exponentially.
fn appendSegments(s: []const u8, out: *[max_segments][]const u8, start: usize) ?usize {
    var n = start;
    var iter = std.mem.splitScalar(u8, s, '/');
    while (iter.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "**") and n > 0 and std.mem.eql(u8, out[n - 1], "**")) continue;
        if (n >= out.len) return null;
        out[n] = seg;
        n += 1;
    }
    return n;
}

fn matchSegments(pat: []const []const u8, path: []const []const u8) bool {
    if (pat.len == 0) return path.len == 0;
    if (std.mem.eql(u8, pat[0], "**")) {
        var i: usize = 0;
        while (i <= path.len) : (i += 1) {
            if (matchSegments(pat[1..], path[i..])) return true;
        }
        return false;
    }
    if (path.len == 0) return false;
    if (!matcher.globMatch(pat[0], path[0])) return false;
    return matchSegments(pat[1..], path[1..]);
}

/// Match a raw pattern against a raw path, both split on `/`. Exposed for
/// testing the segment semantics without going through classification.
pub fn pathMatch(pattern: []const u8, path: []const u8) bool {
    var pat_buf: [max_segments][]const u8 = undefined;
    var path_buf: [max_segments][]const u8 = undefined;
    const pat_n = appendSegments(pattern, &pat_buf, 0) orelse return false;
    const path_n = appendSegments(path, &path_buf, 0) orelse return false;
    return matchSegments(pat_buf[0..pat_n], path_buf[0..path_n]);
}
```

- [ ] **Step 4: Run the tests**

Run: `just check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add src/engine/path.zig
git commit -m "$(cat <<'EOF'
feat: gitignore-shaped segment matching for path patterns

** spans zero or more segments; * and ? stay inside one. Per-segment
matching reuses globMatch, so ? and {a,b} brace expansion come along and
no existing Bash rule changes behavior.

Consecutive ** segments collapse at split time, which makes catastrophic
backtracking on a/**/**/**/b unrepresentable.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: Wire `path*` matchers into the schema and engine

**Files:**
- Modify: `src/config/rule.zig` (`MatchConfig`, `fieldsUsed`, `hasAnyMatch`)
- Modify: `src/engine/matcher.zig` (`matchPathMatchers`)
- Modify: `src/engine/engine.zig` (resolve once, evaluate path matchers)
- Test: all three files

**Interfaces:**
- Consumes: `path.resolve`, `path.matches` from Tasks 8 and 9; `rule_mod.FieldSet` from Task 2.
- Produces: `matcher.matchPathMatchers(rule, resolved, home) bool`, returning true when every configured path matcher matches and when the rule has none.

- [ ] **Step 1: Write the failing test in `src/engine/engine.zig`**

```zig
test "path_any rejects a Write outside the allowed tree" {
    const rules = [_]Rule{.{
        .id = "no-src-writes",
        .tool = "Write",
        .message = "Generated. Edit the template.",
        .match = .{ .path_any = &.{ "**/*_pb2.py", "**/*.gen.ts" } },
    }};

    const hit = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/api/schema_pb2.py",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, hit.action.?);

    const miss = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/api/main.py",
        .root = "/p",
    });
    try std.testing.expect(miss.action == null);
}

test "a path rule is skipped when the call carries no path" {
    const rules = [_]Rule{.{
        .id = "no-src-writes",
        .tool = "Write",
        .message = "M",
        .match = .{ .path_any = &.{"**"} },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Write" });
    try std.testing.expect(result.action == null);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `just test`
Expected: FAIL to compile. `MatchConfig` has no `path_any`.

- [ ] **Step 3: Add the fields to `MatchConfig` in `src/config/rule.zig`**

Insert after the `content_*` block:

```zig
    // Path matching (for tools that carry a target path). Patterns are
    // gitignore-shaped globs; see README for the anchoring rules.
    path: ?[]const u8 = null,
    path_any: ?[]const []const u8 = null,
    path_regex: ?[]const u8 = null,
```

- [ ] **Step 4: Set the `path` field in `fieldsUsed` and `hasAnyMatch`**

In `fieldsUsed`, replace `.path = false,` with:

```zig
        .path = m.path != null or m.path_any != null or m.path_regex != null,
```

In `hasAnyMatch`, add before the closing `m.ast != null`:

```zig
        m.path != null or
        m.path_any != null or
        m.path_regex != null or
```

- [ ] **Step 5: Extend the `hasAnyMatch with each field type` test**

Add three cases to the `inline for` tuple:

```zig
        MatchConfig{ .path = "x" },
        MatchConfig{ .path_any = &.{"x"} },
        MatchConfig{ .path_regex = "x" },
```

- [ ] **Step 6: Add `matchPathMatchers` to `src/engine/matcher.zig`**

```zig
const path_mod = @import("path.zig");

/// Match a rule's path matchers against a resolved path. Returns true when
/// all configured path matchers match, and true when the rule has none.
///
/// path_regex runs against the root-relative form when the path is inside the
/// root, and the absolute form otherwise, so a regex sees the same string a
/// glob would.
pub fn matchPathMatchers(
    rule: Rule,
    resolved: path_mod.Resolved,
    home: ?[]const u8,
) bool {
    const m = rule.match;

    if (m.path) |pattern| {
        if (!path_mod.matches(pattern, resolved, home)) return false;
    }

    if (m.path_any) |patterns| {
        var found = false;
        for (patterns) |pattern| {
            if (path_mod.matches(pattern, resolved, home)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    if (m.path_regex) |pattern| {
        const text = resolved.relative orelse resolved.absolute;
        if (!regexMatch(pattern, text)) return false;
    }

    return true;
}
```

- [ ] **Step 7: Resolve once and evaluate in `src/engine/engine.zig`**

Add the import at the top:

```zig
const path_mod = @import("path.zig");
```

Immediately after the Bash parse block and before the rules loop, resolve the path once for the whole call rather than once per rule:

```zig
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved: ?path_mod.Resolved = if (call.file_path) |fp|
        path_mod.resolve(fp, call.cwd, call.root, &path_buf)
    else
        null;
    const home = std.posix.getenv("HOME");
```

Add the applicability guard next to the other two:

```zig
        if (fields.path and resolved == null) continue;
```

And the evaluation, immediately before the `matchContent` call:

```zig
        if (fields.path) {
            if (!matcher.matchPathMatchers(rule, resolved.?, home)) continue;
        }
```

Note that `fields.path and resolved == null` also covers the case where `file_path` was present but failed to resolve (too long, or relative with no `cwd` and no `root`), which fails open as everything else does.

- [ ] **Step 8: Add the path row to `toolFields` validation coverage**

`toolFields` already returns `.{ .path = true }` for the six path tools, so this needs no change. Add a test in `src/config/rule.zig` confirming the pairing now that `path*` exists:

```zig
test "path matcher on a Bash rule fails validation" {
    const rules = [_]Rule{.{
        .id = "probe",
        .tool = "Bash",
        .message = "M",
        .match = .{ .path_any = &.{"src/**"} },
    }};
    try std.testing.expectError(ValidationError.MatcherToolMismatch, validate(&rules));
}

test "path matcher on a Write rule passes validation" {
    const rules = [_]Rule{.{
        .id = "no-gen-edits",
        .tool = "Write",
        .message = "M",
        .match = .{ .path_any = &.{"**/*.gen.ts"} },
    }};
    try validate(&rules);
}
```

- [ ] **Step 9: Run the suite**

Run: `just check`
Expected: PASS.

- [ ] **Step 10: Verify end to end**

```bash
just build
cat > /tmp/pathrule.toml <<'TOML'
[[rule]]
id = "no-gen-edits"
tool = "Write"
message = "That file is generated. Edit the source template."
[rule.match]
path_any = ["**/*.gen.ts"]
TOML
./zig-out/bin/veer test --tool Write --path src/api.gen.ts --config /tmp/pathrule.toml
./zig-out/bin/veer test --tool Write --path src/api.ts --config /tmp/pathrule.toml
```
Expected: first prints `REJECT`, second prints `ALLOW`.

- [ ] **Step 11: Commit**

```bash
git add src/config/rule.zig src/engine/matcher.zig src/engine/engine.zig
git commit -m "$(cat <<'EOF'
feat: path, path_any, and path_regex matchers

Resolved once per call rather than once per rule. A rule whose path
matcher has no path to read is skipped, same as every other family.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: The `allow` action

A gate: its match block is the allowlist of what may pass. It never approves-and-stops, so gates are monotonically narrowing and a private config tier can never weaken a team rule.

**Files:**
- Modify: `src/config/rule.zig` (`Action`, validation)
- Modify: `src/engine/engine.zig` (dispatch on action)
- Modify: `src/cli/add.zig:24,34,39-48`
- Modify: `src/main.zig:454`
- Test: `src/config/rule.zig`, `src/engine/engine.zig`

**Interfaces:**
- Consumes: everything from Tasks 2, 9, and 10.
- Produces: `Action.allow`. `effectiveAction()` is unchanged: `allow` must be explicit, since inferring it from the absence of `rewrite_to` would silently reclassify every existing reject rule.

- [ ] **Step 1: Write the failing tests in `src/engine/engine.zig`**

```zig
test "allow gate falls through when the path is in the allowlist" {
    const rules = [_]Rule{
        .{
            .id = "worktree-only-writes",
            .action = .allow,
            .tool = "Write",
            .message = "Work in a worktree.",
            .match = .{ .path_any = &.{".claude/worktrees/**"} },
        },
        .{
            .id = "no-gen-edits",
            .tool = "Write",
            .message = "Generated.",
            .match = .{ .path_any = &.{"**/*.gen.ts"} },
        },
    };

    // In the allowlist, and not generated: falls through both, allowed.
    const ok = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/.claude/worktrees/a/src/App.vue",
        .root = "/p",
    });
    try std.testing.expect(ok.action == null);

    // In the allowlist, but generated: gate passes, next rule rejects.
    const gen = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/.claude/worktrees/a/src/api.gen.ts",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, gen.action.?);
    try std.testing.expectEqualStrings("no-gen-edits", gen.rule_id.?);
}

test "allow gate rejects what is not in the allowlist" {
    const rules = [_]Rule{.{
        .id = "worktree-only-writes",
        .action = .allow,
        .tool = "Write",
        .message = "Work in a worktree.",
        .match = .{ .path_any = &.{".claude/worktrees/**"} },
    }};

    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/api/main.py",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, result.action.?);
    try std.testing.expectEqualStrings("Work in a worktree.", result.message.?);
    try std.testing.expectEqualStrings("worktree-only-writes", result.rule_id.?);
}

test "a gate whose field is null does not apply" {
    const rules = [_]Rule{.{
        .id = "worktree-only-writes",
        .action = .allow,
        .tool = "Write",
        .message = "Work in a worktree.",
        .match = .{ .path_any = &.{".claude/worktrees/**"} },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Write" });
    try std.testing.expect(result.action == null);
}

test "two gates on the same tool intersect" {
    const rules = [_]Rule{
        .{
            .id = "src-only",
            .action = .allow,
            .tool = "Write",
            .message = "Writes belong under src.",
            .match = .{ .path_any = &.{"src/**"} },
        },
        .{
            .id = "vue-only",
            .action = .allow,
            .tool = "Write",
            .message = "Writes must be .vue files.",
            .match = .{ .path_any = &.{"**/*.vue"} },
        },
    };

    // Satisfies both.
    const both = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/src/App.vue",
        .root = "/p",
    });
    try std.testing.expect(both.action == null);

    // Satisfies the first only: the second gate rejects.
    const one = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/src/main.ts",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, one.action.?);
    try std.testing.expectEqualStrings("vue-only", one.rule_id.?);
}

test "stay-in-repo gate rejects a write outside the root" {
    const rules = [_]Rule{.{
        .id = "stay-in-repo",
        .action = .allow,
        .tool = "Write",
        .message = "Stay inside the project.",
        .match = .{ .path_any = &.{"*"} },
    }};

    const outside = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/tmp/scratch.txt",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, outside.action.?);

    const inside = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/apps/web/main.ts",
        .root = "/p",
    });
    try std.testing.expect(inside.action == null);
}
```

- [ ] **Step 2: Write the failing validation tests in `src/config/rule.zig`**

```zig
test "allow requires a message" {
    const rules = [_]Rule{.{
        .id = "gate",
        .action = .allow,
        .tool = "Write",
        .match = .{ .path_any = &.{"src/**"} },
    }};
    try std.testing.expectError(ValidationError.RejectRequiresMessage, validate(&rules));
}

test "allow rejects a command matcher" {
    const rules = [_]Rule{.{
        .id = "gate",
        .action = .allow,
        .tool = "Bash",
        .message = "Use a just recipe.",
        .match = .{ .command_any = &.{ "just", "git" } },
    }};
    try std.testing.expectError(ValidationError.AllowRequiresPathOrContent, validate(&rules));
}

test "allow accepts a content matcher" {
    const rules = [_]Rule{.{
        .id = "plans-need-testing",
        .action = .allow,
        .tool = "ExitPlanMode",
        .message = "Add a Testing section.",
        .match = .{ .content_regex = "## Testing" },
    }};
    try validate(&rules);
}
```

- [ ] **Step 3: Run to verify failure**

Run: `just test`
Expected: FAIL to compile. `Action` has no `allow` and `ValidationError` has no `AllowRequiresPathOrContent`.

- [ ] **Step 4: Add `allow` to `Action` in `src/config/rule.zig`**

```zig
pub const Action = enum {
    rewrite,
    reject,
    /// A gate: the match block is the allowlist of what may pass. A call the
    /// gate does not match is rejected; one it matches falls through to the
    /// next rule. A gate never approves-and-stops, which is what makes gates
    /// monotonically narrowing: adding one can only reduce what passes.
    allow,
};
```

`effectiveAction()` is unchanged. `allow` must be written explicitly; inferring it would reclassify existing rules.

- [ ] **Step 5: Add the validation**

Add the error variant:

```zig
    AllowRequiresPathOrContent,
```

Change the message check to cover `allow`, since a gate's message is what the agent sees when it fails:

```zig
        if ((action == .reject or action == .allow) and rule.message == null) {
            return ValidationError.RejectRequiresMessage;
        }
```

Add the matcher restriction, after the `MatcherToolMismatch` check:

```zig
        if (action == .allow) {
            const used = fieldsUsed(rule.match);
            if (used.command) return ValidationError.AllowRequiresPathOrContent;
        }
```

- [ ] **Step 6: Add the same two checks to `src/cli/validate_cmd.zig`**

Change the reject-message check to include allow:

```zig
        if ((action == .reject or action == .allow) and rule.message == null) {
```

and add after it:

```zig
        if (action == .allow and rule_mod.fieldsUsed(rule.match).command) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "allow does not accept command matchers";
                issues_len += 1;
            }
        }
```

- [ ] **Step 7: Dispatch on action in `src/engine/engine.zig`**

The current loop returns as soon as all matchers pass. Replace the matcher evaluation and the return with a form that tracks whether the rule matched, then dispatches:

```zig
        var matched = true;
        var match_start: ?u32 = null;
        var match_end: ?u32 = null;

        if (fields.command) {
            const parsed = info orelse continue;
            if (matcher.matchRule(rule, parsed)) |match_idx| {
                if (match_idx != matcher.CROSS_COMMAND_MATCH and
                    match_idx < parsed.commands.items.len)
                {
                    const matched_cmd = parsed.commands.items[match_idx];
                    match_start = matched_cmd.start_byte;
                    match_end = matched_cmd.end_byte;
                }
            } else {
                matched = false;
            }
        }

        if (matched and fields.path) {
            matched = matcher.matchPathMatchers(rule, resolved.?, home);
        }

        if (matched) {
            matched = matcher.matchContent(allocator, rule, call.content);
        }

        const action = rule.effectiveAction();
        if (action == .allow) {
            // A gate: pass means fall through, fail means reject.
            if (matched) continue;
            return .{
                .action = .reject,
                .rule_id = rule.id,
                .message = rule.message,
            };
        }

        if (!matched) continue;

        return .{
            .action = action,
            .rule_id = rule.id,
            .message = rule.message,
            .rewrite_to = rule.rewrite_to,
            .match_start = match_start,
            .match_end = match_end,
        };
```

A gate returns `.reject` rather than `.allow`, so `check.zig` needs no new branch: the CheckResult action is what the hook does, and what a failed gate does is reject.

- [ ] **Step 8: Accept `allow` in `src/cli/add.zig`**

Line 24 becomes:

```zig
        try writer.print("veer add: --action is required (allow, reject, rewrite)\n", .{});
```

Line 34 becomes:

```zig
        try writer.print("veer add: invalid action '{s}' (must be allow, reject, or rewrite)\n", .{action_str});
```

The `action == .reject and opts.message == null` check at line 44 becomes:

```zig
    if ((action == .reject or action == .allow) and opts.message == null) {
```

In `autoId` and `autoName`, add an `.allow` arm to each switch, mirroring the existing shape (`allow-<command>` and `Allow <command>`).

- [ ] **Step 9: Update the help text in `src/main.zig:454`**

```zig
        \\    --action <str>      Rule action (allow, reject, rewrite).
```

- [ ] **Step 10: Run the suite**

Run: `just check`
Expected: PASS. `list.zig:41` uses `@tagName(rule.effectiveAction())`, so `allow` appears in `veer list` with no change.

- [ ] **Step 11: Verify end to end**

```bash
just build
cat > /tmp/gate.toml <<'TOML'
[[rule]]
id = "worktree-only-writes"
action = "allow"
tool = "Write"
message = "Writes to the primary checkout are off-limits. Work in a worktree."
[rule.match]
path_any = [".claude/worktrees/**", ".llm/**"]
TOML
./zig-out/bin/veer test --tool Write --path .claude/worktrees/a/src/App.vue --config /tmp/gate.toml
./zig-out/bin/veer test --tool Write --path src/App.vue --config /tmp/gate.toml
```
Expected: first prints `ALLOW`, second prints `REJECT` with the gate's message.

- [ ] **Step 12: Commit**

```bash
git add src/config/rule.zig src/engine/engine.zig src/cli/add.zig src/cli/validate_cmd.zig src/main.zig
git commit -m "$(cat <<'EOF'
feat: allow action expresses a rule as a narrowing gate

A gate's match block is the allowlist of what may pass. A call it does not
match is rejected; one it matches falls through. A gate never
approves-and-stops, so adding one can only reduce what passes, which is
what lets a private config tier layer on a team config without being able
to weaken it.

Valid only with path and content matchers.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 12: `tool_any`

**Files:**
- Modify: `src/config/rule.zig` (`Rule`, validation, `toolFields` usage)
- Modify: `src/engine/engine.zig` (tool filter)
- Modify: `src/cli/list.zig:44,46` (Tool column)
- Test: `src/config/rule.zig`, `src/engine/engine.zig`

**Interfaces:**
- Produces: `Rule.tool_any: ?[]const []const u8` and `Rule.matchesTool(tool_name) bool`. Exact string match, no globbing.

- [ ] **Step 1: Write the failing tests**

In `src/engine/engine.zig`:

```zig
test "tool_any matches any listed tool" {
    const rules = [_]Rule{.{
        .id = "no-gen-edits",
        .tool_any = &.{ "Write", "Edit", "NotebookEdit" },
        .message = "Generated.",
        .match = .{ .path_any = &.{"**/*.gen.ts"} },
    }};

    inline for (.{ "Write", "Edit", "NotebookEdit" }) |tool| {
        const r = check(std.testing.allocator, &rules, .{
            .tool_name = tool,
            .file_path = "/p/src/api.gen.ts",
            .root = "/p",
        });
        try std.testing.expectEqual(Action.reject, r.action.?);
    }

    const bash = check(std.testing.allocator, &rules, .{
        .tool_name = "Bash",
        .command = "ls",
    });
    try std.testing.expect(bash.action == null);
}

test "a rule with only a tool filter fires on that tool" {
    const rules = [_]Rule{.{
        .id = "no-notebooks",
        .tool_any = &.{"NotebookEdit"},
        .message = "Notebooks are off-limits here.",
    }};

    const hit = check(std.testing.allocator, &rules, .{ .tool_name = "NotebookEdit" });
    try std.testing.expectEqual(Action.reject, hit.action.?);

    const miss = check(std.testing.allocator, &rules, .{ .tool_name = "Write" });
    try std.testing.expect(miss.action == null);
}
```

The second test is the replacement for the `tool-name-only rule still fires` test deleted in Task 3. It needs `hasAnyMatch` to accept a rule with no matchers when `tool_any` is set.

In `src/config/rule.zig`:

```zig
test "tool and tool_any together fail validation" {
    const rules = [_]Rule{.{
        .id = "both",
        .tool = "Write",
        .tool_any = &.{"Edit"},
        .message = "M",
        .match = .{ .path_any = &.{"src/**"} },
    }};
    try std.testing.expectError(ValidationError.ToolAndToolAny, validate(&rules));
}

test "tool_any with no matchers is a valid tool-name-only rule" {
    const rules = [_]Rule{.{
        .id = "no-notebooks",
        .tool_any = &.{"NotebookEdit"},
        .message = "M",
    }};
    try validate(&rules);
}
```

- [ ] **Step 2: Run to verify failure**

Run: `just test`
Expected: FAIL to compile. `Rule` has no `tool_any`.

- [ ] **Step 3: Add the field and helper to `src/config/rule.zig`**

Add to `Rule`, after `tool`:

```zig
    /// Tools this rule applies to. Exact names, no globbing. Mutually
    /// exclusive with `tool`.
    tool_any: ?[]const []const u8 = null,
```

Add a method:

```zig
    /// True when this rule applies to `tool_name`. Uses `tool_any` when set,
    /// otherwise the single `tool` field.
    pub fn matchesTool(self: Rule, tool_name: []const u8) bool {
        if (self.tool_any) |tools| {
            for (tools) |t| {
                if (std.mem.eql(u8, t, tool_name)) return true;
            }
            return false;
        }
        return std.mem.eql(u8, self.tool, tool_name);
    }
```

- [ ] **Step 4: Add validation**

Add the error variant:

```zig
    ToolAndToolAny,
```

Add at the top of the per-rule loop in `validate`, before the action checks:

```zig
        if (rule.tool_any != null and !std.mem.eql(u8, rule.tool, "Bash")) {
            return ValidationError.ToolAndToolAny;
        }
```

The check compares against the default rather than testing for presence, because `tool` is a non-optional field with a default of `"Bash"` and TOML gives no way to tell "absent" from "explicitly Bash".

Relax the empty-match check so a tool-name-only rule is valid:

```zig
        if (!hasAnyMatch(rule.match) and rule.tool_any == null) {
            return ValidationError.EmptyMatch;
        }
```

Extend the `MatcherToolMismatch` check to walk every tool in `tool_any`:

```zig
        const used = fieldsUsed(rule.match);
        if (rule.tool_any) |tools| {
            for (tools) |t| {
                if (toolFields(t)) |carried| {
                    if ((used.command and !carried.command) or
                        (used.content and !carried.content) or
                        (used.path and !carried.path))
                    {
                        return ValidationError.MatcherToolMismatch;
                    }
                }
            }
        } else if (toolFields(rule.tool)) |carried| {
            if ((used.command and !carried.command) or
                (used.content and !carried.content) or
                (used.path and !carried.path))
            {
                return ValidationError.MatcherToolMismatch;
            }
        }
```

- [ ] **Step 5: Use `matchesTool` in `src/engine/engine.zig`**

Replace the tool filter line:

```zig
        if (!rule.matchesTool(call.tool_name)) continue;
```

- [ ] **Step 6: Show `tool_any` in `src/cli/list.zig`**

The Tool column prints `rule.tool` directly. Before the `addRow` calls, build the display string:

```zig
        const tool_str = if (rule.tool_any) |tools| blk: {
            var parts: std.ArrayListUnmanaged(u8) = .empty;
            errdefer parts.deinit(allocator);
            for (tools, 0..) |t, i| {
                if (i > 0) try parts.appendSlice(allocator, ",");
                try parts.appendSlice(allocator, t);
            }
            break :blk try parts.toOwnedSlice(allocator);
        } else rule.tool;
        defer if (rule.tool_any != null) allocator.free(tool_str);
```

and pass `tool_str` where `rule.tool` was passed.

- [ ] **Step 7: Mirror the `tool_any` checks in `src/cli/validate_cmd.zig`**

Add to the per-rule issue block:

```zig
        if (rule.tool_any != null and !std.mem.eql(u8, rule.tool, "Bash")) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "tool and tool_any are mutually exclusive";
                issues_len += 1;
            }
        }
```

and change the empty-match issue to `if (!rule_mod.hasAnyMatchPub(rule.match) and rule.tool_any == null)`.

- [ ] **Step 8: Run the suite**

Run: `just check`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add src/config/rule.zig src/engine/engine.zig src/cli/list.zig src/cli/validate_cmd.zig
git commit -m "$(cat <<'EOF'
feat: tool_any lets one rule cover several tools

Covering Write, Edit, and NotebookEdit previously meant three rules with
three copies of the same message. Exact names, no globbing.

A rule with tool_any and no matchers is now a valid tool-name-only rule,
which previously had to abuse a command matcher to pass validation.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 13: Smoke test and benchmark

**Files:**
- Modify: `Justfile` (new recipe, add to `check`)
- Modify: `src/bench.zig`

- [ ] **Step 1: Add a gate smoke recipe to the Justfile**

Add after `check-deny`:

```make
# Smoke test: an allow gate rejects a Write outside its allowlist and falls
# through for one inside it.
check-gate:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build
    bin="$(pwd)/zig-out/bin/veer"
    root="$(pwd)"
    cfg=$(mktemp)
    trap 'rm -f "$cfg"' EXIT
    cat > "$cfg" <<'TOML'
    [[rule]]
    id = "worktree-only-writes"
    action = "allow"
    tool_any = ["Write", "Edit"]
    message = "Work in a worktree."
    [rule.match]
    path_any = [".claude/worktrees/**"]
    TOML

    # Inside the allowlist: exit 0, no stderr.
    set +e
    out=$(echo "{\"tool_name\":\"Write\",\"cwd\":\"$root\",\"tool_input\":{\"file_path\":\"$root/.claude/worktrees/a/x.ts\"}}" \
      | "$bin" check --config "$cfg" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then echo "check-gate inside: FAIL (exit $rc: $out)"; exit 1; fi
    echo "check-gate inside: PASS"

    # Outside the allowlist: exit 2, message on stderr.
    set +e
    out=$(echo "{\"tool_name\":\"Write\",\"cwd\":\"$root\",\"tool_input\":{\"file_path\":\"$root/src/x.ts\"}}" \
      | "$bin" check --config "$cfg" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 2 ]; then echo "check-gate outside: FAIL (expected exit 2, got $rc)"; exit 1; fi
    case "$out" in
      *"Work in a worktree."*) echo "check-gate outside: PASS" ;;
      *) echo "check-gate outside: FAIL (message missing: $out)"; exit 1 ;;
    esac
```

The config passes `--config`, which skips discovery, so `root` is null and paths resolve against `cwd` from the envelope. That is the fallback the spec specifies and this recipe exercises it.

- [ ] **Step 2: Add the recipe to the `check` target**

Line 4 becomes:

```make
check: test lint check-help check-no-config check-verbose check-from-subdir check-local-override check-local-install-exclude check-gate
```

- [ ] **Step 3: Add a path-matching benchmark case to `src/bench.zig`**

Follow the existing case structure in that file. Benchmark `path.matches` against a representative pattern and a nested path:

```zig
// Path matching: a gate's allowlist against a deep path.
{
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = path_mod.resolve(
        "/p/apps/web/src/components/Button.vue",
        null,
        "/p",
        &buf,
    ).?;
    var timer = try std.time.Timer.start();
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        std.mem.doNotOptimizeAway(path_mod.matches("apps/**/*.vue", resolved, null));
    }
    try report(writer, "path.matches apps/**/*.vue", timer.read(), iterations);
}
```

Match the surrounding file's exact naming for `iterations`, `report`, and the writer; read it first and follow what is there rather than the sketch above.

- [ ] **Step 4: Run everything**

Run: `just check && just bench`
Expected: `just check` PASSes including `check-gate: PASS` twice. The benchmark prints a per-call figure; path matching should stay well under the single-digit millisecond target for `veer check` as a whole.

- [ ] **Step 5: Commit**

```bash
git add Justfile src/bench.zig
git commit -m "$(cat <<'EOF'
test: smoke test the allow gate through the hook protocol

Exercises the real envelope parse path with a Write, both inside and
outside the gate's allowlist. Adds a path-matching benchmark case, since
this puts new work in the check hot path.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 14: Documentation

**Files:**
- Modify: `README.md`
- Modify: `src/cli/skill_content.md`
- Modify: `docs/spec/remaining-work.md`

- [ ] **Step 1: Add `allow` to the README Actions section**

After the "Reject (block with redirect message)" subsection, add:

````markdown
### Allow (a gate the call must pass)

An `allow` rule is a gate. Its `[rule.match]` block is the allowlist of what
may pass. A call the gate does not match is rejected with the rule's message;
a call it matches falls through to the next rule.

```
Rule:         action = "allow", tool_any = ["Write"], path_any = [".claude/worktrees/**"]
Agent tries:  Write to .claude/worktrees/feat-a/src/App.vue
Result:       falls through, later rules still apply

Agent tries:  Write to src/App.vue
veer returns: "Writes to the primary checkout are off-limits. Work in a worktree."
Exit code:    2
```

A gate never approves and stops. It can only reject or fall through, so adding
a gate can only reduce what passes, never expand it. That is what makes it safe
to layer a private `.veer/config.local.toml` gate on top of a shared
`.veer/config.toml`: a personal gate can add a constraint but cannot weaken a
team rule.

Two gates on the same tool intersect. A path must satisfy both.
````

- [ ] **Step 2: Add `tool_any` and the `path*` family to the README Rule Schema block**

In the `[[rule]]` schema block, after the `tool` line:

```
tool_any = ["Write", "Edit"]   # Tools to match. Exclusive with `tool`.
```

In the `[rule.match]` block, after the content matching group:

```
# Path matching (tools that carry a target path)
path = "src/**"                       # gitignore-shaped glob
path_any = ["**/*.env", "dist/**"]    # OR: any pattern matches
path_regex = "\\.gen\\.[jt]s$"        # POSIX regex (escape hatch)
```

- [ ] **Step 3: Add three rows to the README Match Types table**

```markdown
| `path` | Target path | gitignore-shaped glob. See Path Patterns below. |
| `path_any` | Target path | OR: any pattern in the list matches. |
| `path_regex` | Target path | POSIX extended regex against the normalized path. |
```

- [ ] **Step 4: Add a Path Patterns subsection to the README**

````markdown
### Path Patterns

`path*` matchers take gitignore-shaped globs, matched against the target path
of tools that carry one (`Write`, `Edit`, `NotebookEdit`, `Read`, `Grep`,
`Glob`). Patterns are anchored at the directory containing `.veer/`, so a
checked-in config stays portable across machines and teammates.

| Pattern | Matches |
|---|---|
| `.env` | any file named `.env`, at any depth |
| `src/**` | everything under the project's `src/` |
| `src/*` | files directly in `src/`, not in subdirectories |
| `**/dist/**` | everything under any `dist/` at any depth |
| `./.env` | the project root's `.env` only |
| `node_modules/` | shorthand for `node_modules/**` |
| `/etc/**` | the real `/etc` |
| `~/.ssh/**` | `$HOME/.ssh` |
| `src/**/*.{ts,vue}` | `.ts` and `.vue` files under `src/` |

`*` and `?` stay inside one path segment; `**` spans zero or more segments.
Matching is case-sensitive.

Two differences from gitignore worth knowing:

**A leading `/` means the filesystem root, not the project root.** `/etc/**` is
the real `/etc`. Use `./` to anchor a single-segment pattern at the project
root, and note that `src/**` is already project-anchored because it contains a
slash.

**A pattern with no slash matches a file's name, not a directory.**
`path_any = ["node_modules"]` matches nothing, because no file is named
`node_modules`. Write `node_modules/` or `node_modules/**`.

Paths outside the project root never match a relative pattern. That is what
makes this work:

```toml
[[rule]]
id = "stay-in-repo"
action = "allow"
tool_any = ["Write", "Edit"]
message = "Stay inside the project."
[rule.match]
path_any = ["*"]
```

**Bash routes around path rules.** A rule on `Write` and `Edit` does not stop
`cat > apps/x.ts`, `sed -i`, `tee`, `cp`, or `mv`. veer is a guardrail for an
agent that is trying to comply and forgot, not a sandbox against one that is
trying to escape. Use Claude Code's `permissions.deny` when you need a wall.
````

- [ ] **Step 5: Update `src/cli/skill_content.md`**

This is the file `install.zig:7` embeds and rewrites on every `veer install`. Editing the generated `.claude/skills/veer/SKILL.md` would be undone.

Four sections change:

- **"The two actions"** becomes "The three actions". Add the `allow` gate with the worktree example, and state that a gate never approves-and-stops and that gates intersect.
- **"Match patterns"** gains the `path*` family and a compact version of the pattern table from Step 4.
- **"Matching non-Bash tools"** currently covers only `content_*`. Add a path example and note that `tool_any` covers Write, Edit, and NotebookEdit in one rule.
- **"Common pitfalls"** gains two entries, in this order:
  1. A no-slash path pattern matches a file's name, not a directory. `node_modules` matches nothing; write `node_modules/` or `node_modules/**`.
  2. A leading `/` in a path pattern is the filesystem root, unlike gitignore. `/build/**` is the real `/build`; the project's is `build/**` or `./build/**`.

- [ ] **Step 6: Resolve item 4 in `docs/spec/remaining-work.md`**

Replace the "## 4. Non-Bash Tool Matching" section with a one-line pointer:

```markdown
## 4. Non-Bash Tool Matching

Done. See `docs/superpowers/specs/2026-08-12-veer-path-matching-design.md`.
Path matching, the `allow` gate action, and `tool_any` all shipped. Matching a
written file's body (`Write`'s `tool_input.content`) is deliberately not
covered and remains open.
```

- [ ] **Step 7: Verify the skill file is what gets installed**

```bash
just build
cd "$(mktemp -d)" && git init -q .
"$OLDPWD/zig-out/bin/veer" install
grep -c "path_any" .claude/skills/veer/SKILL.md
```
Expected: a non-zero count, confirming the embedded content carries the new material.

- [ ] **Step 8: Run the suite**

Run: `just check`
Expected: PASS.

- [ ] **Step 9: Commit**

```bash
git add README.md src/cli/skill_content.md docs/spec/remaining-work.md
git commit -m "$(cat <<'EOF'
docs: path patterns, the allow gate, and tool_any

Covers the two deliberate divergences from gitignore: a leading slash is
the filesystem root, and a no-slash pattern matches a file name rather
than a directory. Both go in the skill's pitfalls section, since the skill
is what writes most rules.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Plan Self-Review

**Spec coverage.** Walked each spec section against the tasks:

| Spec section | Task |
|---|---|
| Evaluation context / `ToolCall` | 1 |
| Matcher families read one field; skip-rule rule | 2 |
| Evaluation loop | 2, 11 |
| `allow` action, gate semantics, intersection | 11 |
| `tool_any` | 12 |
| `path` / `path_any` / `path_regex` | 10 |
| Normalization | 8 |
| Pattern classification, both divergences | 9 |
| Glob dialect, `**` collapse | 9 |
| No-slash limitation | 9 (test), 14 (docs) |
| `veer test --tool` | 4 |
| Validation, three new checks | 3, 11, 12 |
| TOML `error_info` | 5 |
| Help text | 6, 11 |
| Testing, including the regression test | 2 and throughout |
| Bench, fuzz target, smoke recipe | 13 |
| Docs, skill, remaining-work | 14 |
| Non-goals | 14 (README Bash-bypass note) |

One spec item is deliberately deferred rather than dropped: `pathMatch` joining the fuzz targets. `remaining-work.md` item 1 covers fuzzing as its own unstarted work (`zig build --fuzz` / `just fuzz` do not exist yet), so adding one target to a harness that has not been built would be a placeholder. Task 13 covers the concrete risk that motivated it with the `**` collapse and its test case.

**Type consistency.** Checked across tasks: `ToolCall` fields (Task 1) are used verbatim in Tasks 4, 7, 8, 10, 11. `FieldSet` and `fieldsUsed` (Task 2) are consumed with the same shape in Tasks 3, 10, 11, 12. `Resolved` (Task 8) is consumed as `resolved.absolute` / `resolved.relative` in Task 9's `matches` and Task 10's `matchPathMatchers`. `path.matches(pattern, resolved, home)` has the same three-argument shape at its definition in Task 9 and its call site in Task 10. `toolFields` (Task 3) returns `?FieldSet` and is called that way in Tasks 3, 10, and 12.

**Two forward references made explicit rather than left dangling:** Task 2 adds a test that Task 3 deletes, because Task 3's validation outlaws the shape it asserts, and Task 12 adds the replacement. Task 6 sets the help text to `(reject, rewrite)` and Task 11 changes it to `(allow, reject, rewrite)`. Both are called out in the tasks themselves.
