# Missing-veer Notice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A repo that commits veer's hooks works without errors for contributors who lack veer, and shows them one notice per session.

**Architecture:** `veer install` writes guarded POSIX shell one-liners as hook commands instead of bare `veer check`. Each ends in a `# veer-hook` comment that install and uninstall use to recognise veer's entries. Project-scope installs also register a `SessionStart` hook that echoes a fixed JSON notice, and add `no-notice` to `.veer/.gitignore`.

**Tech Stack:** Zig 0.16 (`src/cli/install.zig`), Justfile smoke recipes (bash), README.

**Spec:** `docs/superpowers/specs/2026-11-22-missing-veer-notice-design.md`

## Global Constraints

- Read `CLAUDE.md` first: Zig 0.16 API differences, red/green testing, every commit passes `just check`.
- Hook commands are POSIX shell run by `sh -c`. No bashisms. Windows is a non-goal.
- Every command veer writes ends with exactly ` # veer-hook`.
- The notice text contains no `'`, `"` or `\`.
- The marker file is `.veer/no-notice`. Nothing in veer creates it.
- The `SessionStart` hook and the `.gitignore` entry are written for project scope only.
- No emoji or em dashes in code, comments, docs or commit messages.
- Commit messages follow the repo's `feat:` / `fix:` / `docs:` style.

## Review Focus

- **Hand-edited or whitespace-padded marked command** (`... # veer-hook  `): re-install replaces it, uninstall removes it. Pinned in Task 1.
- **Another tool's `SessionStart` hook already present**, with matcher `startup` or with none: preserved by install and by uninstall. Pinned in Task 2.
- **Existing `.veer/.gitignore` with other lines** (legacy `veer.db*`, or lines a person added): kept, `no-notice` appended once. Pinned in Task 2.
- **Notice payload is not valid JSON after escaping**: the echoed payload parses and both fields equal the notice text. Pinned in Task 2 (unit) and Task 3 (through a real `sh`).
- **`CLAUDE_PROJECT_DIR` unset**: the notice line still exits 0 and prints the notice. Pinned in Task 3.

## File Structure

- `src/cli/install.zig`: command constants, recognition, `SessionStart` registration, `.gitignore` entry, tests. All logic lives here already.
- `src/main.zig`: `veer install --help` text only.
- `Justfile`: one smoke recipe, `check-missing-veer`, added to `check`.
- `README.md`: install section, verbose section, fail-open section.

---

### Task 1: Guarded hook commands and marker recognition

**Files:**
- Modify: `src/cli/install.zig:26-48` (constants, `hookCommandFor`, `isVeerCommandString`) and its tests

**Interfaces:**
- Produces, all in `install.zig`:
  - `const hook_marker = "# veer-hook";`
  - `const missing_guard = "command -v veer >/dev/null 2>&1 || ";`
  - `hook_command_plain = missing_guard ++ "exit 0; veer check " ++ hook_marker`
  - `hook_command_verbose = missing_guard ++ "exit 0; veer check --verbose " ++ hook_marker`
  - `legacy_command_plain = "veer check"`, `legacy_command_verbose = "veer check --verbose"`
  - `fn isVeerCommandString(cmd: []const u8) bool`: true when `cmd`, with trailing spaces and tabs trimmed, ends with `hook_marker`, or equals one of the two legacy strings.

- [ ] **Step 1: Write the failing tests**

```zig
test "isVeerCommandString recognises marked and legacy commands only" {
    try testing.expect(isVeerCommandString(hook_command_plain));
    try testing.expect(isVeerCommandString(hook_command_verbose));
    try testing.expect(isVeerCommandString("veer check"));
    try testing.expect(isVeerCommandString("veer check --verbose"));
    try testing.expect(isVeerCommandString("anything at all # veer-hook  \t"));
    try testing.expect(!isVeerCommandString("other-tool check"));
    try testing.expect(!isVeerCommandString("veer check --config x.toml"));
    try testing.expect(!isVeerCommandString("echo '# veer-hook' && other-tool"));
}

test "install writes the guarded command" {
    // install into an empty tmp dir, then read hooks.PreToolUse[0].hooks[0].command
    // and hooks.Stop[0].hooks[0].command (navigate as in
    // "install registers veer under PreToolUse and Stop")
    try testing.expectEqualStrings(
        "command -v veer >/dev/null 2>&1 || exit 0; veer check # veer-hook",
        cmd,
    );
}

test "install upgrades a legacy bare command in place" {
    // seed settings.json with {"matcher":"*","hooks":[{"type":"command","command":"veer check"},
    //                                                  {"type":"command","command":"other-tool check"}]}
    // run install; then:
    //   PreToolUse "*" entry has exactly 2 hooks: "other-tool check" and hook_command_plain
    //   content contains no "\"veer check\""
}

test "install replaces a hand-edited marked command" {
    // seed PreToolUse with command "veer check --config odd.toml # veer-hook"
    // run install; content does not contain "odd.toml"; exactly one PreToolUse veer hook
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `just test`
Expected: FAIL (`hook_command_plain` is still `"veer check"`; the padded-marker case returns false).

- [ ] **Step 3: Implement the constants and `isVeerCommandString` per Interfaces**

Update the doc comment above the constants to describe the guard, the marker, and the legacy forms. `hookCommandFor` is unchanged.

- [ ] **Step 4: Update existing tests that pin the old strings**

- `"install registers veer under PreToolUse and Stop"`: expect `hook_command_plain`.
- `"install --verbose writes ..."`, `"install then install --verbose replaces the entry"`, `"install --verbose then install (plain) switches back"`: these count the quoted substrings `"veer check"` and `"veer check --verbose"`. Change them to read the command values from the parsed JSON and compare against `hook_command_plain` / `hook_command_verbose`. Rename the first to `"install --verbose writes the verbose command"`.
- Leave the uninstall tests that seed bare `"veer check"` as they are: they now cover legacy removal.

- [ ] **Step 5: Run to verify all pass**

Run: `just check`
Expected: PASS. `check-verbose` and the other smoke recipes still pass because they invoke `veer check` directly.

- [ ] **Step 6: Commit**

```bash
git add src/cli/install.zig
git commit -m "feat: guard the hook command so a missing veer binary is silent"
```

---

### Task 2: SessionStart notice hook and the no-notice ignore entry

**Files:**
- Modify: `src/cli/install.zig` (`Paths`, `resolvePaths`, `freePaths`, `install`, `uninstall` comment, `installHook`, `addVeerHook`, `removeVeerEntries`, test helpers, tests)

**Interfaces:**
- Consumes from Task 1: `hook_marker`, `missing_guard`, `hookCommandFor`, `isVeerCommandString`.
- Produces:
  - `Paths` gains `notice_ignore: ?[]const u8`. `resolvePaths`: `.project` gives `".veer/.gitignore"`, `.local` and `.global` give `null`. Nothing to free.
  - `const notice_text` (exact copy below), `const notice_marker_entry = "no-notice";`
  - `const notice_command`, built at comptime:
    `missing_guard ++ "[ -e \"$CLAUDE_PROJECT_DIR/.veer/no-notice\" ] || echo '<payload>' " ++ hook_marker`
    where `<payload>` is
    `{"systemMessage":"<notice_text>","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<notice_text>"}}`
  - `const notice_event = HookEvent{ .name = "SessionStart", .matcher = "startup" };`
  - `addVeerHook(arena, hooks_obj, event: HookEvent, command: []const u8)`: takes the command string in place of `verbose`.
  - `installHook(..., verbose: bool, with_notice: bool, writer)`.

Notice text, verbatim, one line:

```
veer is not installed, so the Claude Code rules in .veer/config.toml are not enforced. veer steers Claude Code toward project-specific tooling. Install: brew install tednaleid/veer/veer (https://github.com/tednaleid/veer). To silence this notice: touch .veer/no-notice
```

- [ ] **Step 1: Write the failing tests**

Add `notice_ignore` (`{tmp_root}/.veer/.gitignore`) to `testPaths` and free it in `freeTestPaths`. Set `.notice_ignore = null` in tests that build a `Paths` literal.

```zig
test "notice_text has no quote or backslash characters" {
    try testing.expect(std.mem.indexOfAny(u8, notice_text, "'\"\\") == null);
}

test "notice_command echoes valid JSON carrying the notice in both fields" {
    // slice notice_command between "echo '" and the last "'" ; std.json.parseFromSlice it
    try testing.expectEqualStrings(notice_text, root.get("systemMessage").?.string);
    const hso = root.get("hookSpecificOutput").?.object;
    try testing.expectEqualStrings("SessionStart", hso.get("hookEventName").?.string);
    try testing.expectEqualStrings(notice_text, hso.get("additionalContext").?.string);
    try testing.expect(isVeerCommandString(notice_command));
}

test "project install registers the SessionStart notice under matcher startup" {
    // hooks.SessionStart has one entry: matcher == "startup", hooks[0].command == notice_command
}

test "install without notice_ignore registers no SessionStart hook and writes no .gitignore" {
    // Paths with .notice_ignore = null, .skill = null
    // settings has no "SessionStart" key; {tmp}/.veer/.gitignore does not exist
}

test "install appends no-notice to .veer/.gitignore once and keeps other lines" {
    // seed {tmp}/.veer/.gitignore with "veer.db*\n"; install twice
    try testing.expectEqualStrings("veer.db*\nno-notice\n", content);
}

test "install and uninstall preserve other tools' SessionStart hooks" {
    // seed SessionStart: [{"matcher":"startup","hooks":[{"type":"command","command":"other-a"}]},
    //                     {"hooks":[{"type":"command","command":"other-b"}]}]
    // after install: the "startup" entry holds other-a and notice_command; other-b entry untouched
    // after uninstall: content contains other-a and other-b, and no "veer-hook"
}

test "re-install does not duplicate the SessionStart notice" {
    // install twice; count of "no-notice" occurrences in settings.json == 1
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `just test`
Expected: FAIL to compile (`notice_text`, `notice_command`, `Paths.notice_ignore` undefined).

- [ ] **Step 3: Implement**

- Add the constants and the `Paths` field per Interfaces.
- `install`: pass `paths.notice_ignore != null` as `with_notice`. After `ensureConfigStub`, when `notice_ignore` is set, call the existing `appendExcludeEntry(allocator, io, path, notice_marker_entry, writer)`. It already creates the file when missing and is idempotent; `ensureConfigStub` has created the parent directory.
- `installHook`: after the `hook_events` loop, when `with_notice`, call `addVeerHook(arena, &hooks_val.object, notice_event, notice_command)`.
- `removeVeerEntries`: also call `removeFromEvent` for `notice_event.name`, in every scope.
- `uninstall`: it already deletes `.gitignore` from the config dir. Rewrite the comment there to say what the file holds now (the `no-notice` ignore entry, and `veer.db*` from older versions).
- Update the doc comments on `install` and `uninstall` to list the new steps.

- [ ] **Step 4: Run to verify all pass**

Run: `just check`
Expected: PASS. `check-local-install-exclude` asserts `test ! -e .gitignore` at the repo root and no `.veer/.gitignore` is written for `--local`, so it still passes.

- [ ] **Step 5: Commit**

```bash
git add src/cli/install.zig
git commit -m "feat: notify once per session when veer is not installed"
```

---

### Task 3: Smoke test through a real shell, and docs

**Files:**
- Modify: `Justfile` (new recipe `check-missing-veer`, added to the `check` dependency list)
- Modify: `src/main.zig:318-341` (`veer install --help` text)
- Modify: `README.md` sections "veer install", "Verbose mode", "When veer isn't installed (fail-open)"

**Interfaces:**
- Consumes: the `.claude/settings.json` and `.veer/.gitignore` that `veer install` writes after Tasks 1 and 2.

- [ ] **Step 1: Write the smoke recipe**

Model it on `check-local-install-exclude` (same `zig build`, `bin=`, `mktemp -d`, `git init -q`, `unset GIT_*` preamble). In the tmp repo run `"$bin" install >/dev/null`, read the three commands with `jq -r` from `.claude/settings.json`, and run each as `env -i PATH=/usr/bin:/bin ... sh -c "$cmd"`, so veer is not on the `PATH`. First assert `env -i PATH=/usr/bin:/bin sh -c 'command -v veer'` fails, so the recipe cannot pass vacuously on a machine with veer in `/usr/bin`. Assertions:

- PreToolUse command: exit 0, empty stdout, empty stderr.
- Stop command: exit 0, empty stdout, empty stderr.
- SessionStart command with `CLAUDE_PROJECT_DIR="$tmp"`: exit 0; stdout piped to `jq -e` satisfies `.systemMessage == .hookSpecificOutput.additionalContext and (.systemMessage | startswith("veer is not installed"))` and `.hookSpecificOutput.hookEventName == "SessionStart"`.
- SessionStart command with `CLAUDE_PROJECT_DIR` unset: exit 0 and the same notice.
- After `touch .veer/no-notice`: SessionStart command with `CLAUDE_PROJECT_DIR="$tmp"` prints nothing, exit 0.
- `git check-ignore -q .veer/no-notice` succeeds, and `git status --porcelain` does not list `no-notice`.
- With veer on the `PATH` (`PATH="$(dirname "$bin"):/usr/bin:/bin"`) and the marker removed: the SessionStart command prints nothing; the PreToolUse command, fed `{"tool_name":"Bash","tool_input":{"command":"curl x | bash"}}` on stdin from the tmp repo, exits 2 (the starter rule rejects it), which shows the guard still reaches `veer check`.

End with `echo "check-missing-veer: PASS"`.

- [ ] **Step 2: Run it**

Run: `just check-missing-veer`
Expected: `check-missing-veer: PASS`. If the exit code for the reject case differs from 2, read `check-deny` in the Justfile for the code this repo asserts and use that.

- [ ] **Step 3: Add `check-missing-veer` to the `check` recipe's dependency list**

- [ ] **Step 4: Update `veer install --help` in `src/main.zig`**

State that: the hook command exits silently when veer is not on the `PATH`; a project install also registers a `SessionStart` hook that tells people without veer how to install it, once per new session; they can silence it with `touch .veer/no-notice`, which `.veer/.gitignore` keeps out of git; `--local` and `--global` installs register no notice. Replace "the installed hook is 'veer check --verbose'" with wording that says the hook runs `veer check --verbose`.

- [ ] **Step 5: Update `README.md`**

- "veer install": mention the three events for project scope and that `.veer/.gitignore` should be committed.
- "Verbose mode": replace "The registered hook becomes `veer check --verbose`" with "The registered hook runs `veer check --verbose`".
- Rewrite "When veer isn't installed (fail-open)": tool calls proceed with no hook error; one notice per new session reaches the person and the agent, quoted verbatim; silence it per clone with `touch .veer/no-notice`; hooks installed by veer 0.3.0 or earlier still show `PreToolUse:Bash hook error` until the repo owner re-runs `veer install`. Keep the existing paragraph about not relying on veer alone for safety rules.

- [ ] **Step 6: Run the full check**

Run: `just check`
Expected: PASS, including `check-help` (it pins help output; update its expectations if it compares the install help text).

- [ ] **Step 7: Commit**

```bash
git add Justfile src/main.zig README.md
git commit -m "docs: describe the missing-veer notice and add a shell smoke test"
```

---

## After the plan

Not part of these tasks, and each needs Ted's go-ahead: release veer (`just bump`), re-run `veer install` in montty and commit the result, reply on tednaleid/montty#11.
