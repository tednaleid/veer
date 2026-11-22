# Quiet fail-open and a one-time notice when veer is not installed

## Intent

A repo that commits veer's hooks in `.claude/settings.json` breaks the Claude
Code experience for contributors who do not have veer. Every tool call shows a
`PreToolUse:Bash hook error`, with no hint of the cause (reported as
tednaleid/montty#11).

Contributors without veer should be able to work normally. They get one short
notice per session saying what veer is, how to install it, and how to silence
the notice. People who have veer see no change.

## Goals

- A missing `veer` binary produces no hook error on any tool call or stop.
- One notice per new session, shown to the person and added to the agent's
  context, when veer is missing.
- A contributor can silence the notice for a repo without installing veer and
  without creating a git diff.
- Re-running `veer install` in an existing repo upgrades its hooks in place.

## Non-goals

- Windows support. The hook commands are POSIX shell, run by `sh -c`.
- Any notice for people who have veer installed.
- Auto-creating the marker file. Silencing is a deliberate manual step.

## Approaches

**A. Inline shell in `settings.json` (chosen).** `veer install` writes guarded
shell one-liners as the hook commands. No new executable in the repo. The
`SessionStart` line is long and holds JSON escaped inside a JSON string, but
veer generates it and people rarely read it.

**B. A committed `.veer/hook.sh`.** `settings.json` stays short and the notice
text is readable, but it adds a committed executable that install and
uninstall must manage, and puts a script in front of every `veer check` call.

**C. Handle it inside the veer binary.** Not possible. When veer is missing no
veer code runs.

Ted picked A: it is the smaller change.

## Design

### Hook commands

`PreToolUse` (matcher `*`) and `Stop`, all install scopes:

```
command -v veer >/dev/null 2>&1 || exit 0; veer check
```

The verbose form ends in `veer check --verbose`. Exit 0 with empty stdout is a
no-op for both events.

`SessionStart` with matcher `startup`, project scope only:

```
command -v veer >/dev/null 2>&1 || [ -e "$CLAUDE_PROJECT_DIR/.veer/no-notice" ] || echo '<notice JSON>'
```

The `startup` matcher is what makes it once per session. Without it the hook
also fires on resume, `/clear`, compaction and fork.

The notice JSON carries the same text in two fields:

```json
{"systemMessage":"<text>","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"<text>"}}
```

Notice text:

> veer is not installed, so the Claude Code rules in .veer/config.toml are not
> enforced. veer steers Claude Code toward project-specific tooling. Install:
> brew install tednaleid/veer/veer (https://github.com/tednaleid/veer). To
> silence this notice: touch .veer/no-notice

The text must contain no single or double quotes, so the shell and JSON
escaping stay trivial.

### Marker file

For project installs, `veer install` adds the line `no-notice` to
`.veer/.gitignore`, to be committed. It creates the file when missing and
keeps any lines already there, such as the `veer.db*` that older versions
wrote. `veer uninstall` keeps deleting `.veer/.gitignore`, as it does today.

`--local` and `--global` installs get the guarded `veer check` command but no
`SessionStart` hook and no `.gitignore`: the person installing is the person
running veer.

### Install and uninstall

- Every command veer writes ends with the shell comment ` # veer-hook`, for
  example `command -v veer >/dev/null 2>&1 || exit 0; veer check # veer-hook`.
- `isVeerCommandString` returns true when the command ends with `# veer-hook`,
  or is exactly `veer check` or `veer check --verbose` (the forms existing
  repos contain). Re-install replaces any recognised command with the current
  form and uninstall removes it, for all three events.
- The marker carries no version. Install always rewrites to the current form.
- A hand-edited command that keeps the marker is overwritten on re-install.
- Other tools' `SessionStart` hooks are preserved, as with the other events.

### Docs

README: a short section for contributors to a repo that uses veer (what the
notice means, install, silence), and updated `veer install` text describing
the three hooks.

## Spike results

Run against Claude Code in a throwaway repo with the binary name swapped for
one that does not exist:

- No hook error on a Bash tool call.
- `SessionStart` accepted the combined JSON; the agent saw the
  `additionalContext` text.
- With `.veer/no-notice` present, the hook printed nothing.
- Not verified: that `systemMessage` renders as a banner in the interactive
  UI. Headless mode cannot show this. Check by eye before release. If it does
  not render, the fallback is to rely on the agent relaying the notice.

## Testing

- Unit tests in `src/cli/install.zig`: fresh install writes the three hooks;
  re-install over bare `veer check` upgrades without duplicates; verbose
  toggle; uninstall removes all three and leaves other tools' hooks;
  `--local` and `--global` write no `SessionStart` entry.
- A Justfile smoke recipe that runs the generated command strings under
  `sh -c` with a `PATH` that lacks veer: the check line exits 0 with empty
  output; the notice line prints valid JSON; with the marker present it
  prints nothing.

## Left to the builder

- Exact wording of the README section.
- How the command strings are assembled in Zig (constants or built at
  comptime), provided the written output matches the forms above.

## Follow-up outside veer

After a veer release, re-run `veer install` in montty (this also adds the
`Stop` hook that montty's settings lack) and reply on montty#11.
