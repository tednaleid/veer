# veer Character Classes and Stop Rules Design

## Problem

Claude drifts into emoji, status-marker glyphs, and em dashes despite CLAUDE.md instructions. A scan of 2,438 local transcripts found them in three places: plain replies (the case the user corrects), tool input (Write, Edit, Bash, Agent prompts, subagent handbacks, plans), and subagent reports. veer only runs as a PreToolUse hook, and `content_regex` / `content_contains` only see ExitPlanMode plan bodies, so none of this is enforceable today.

## Goals

- A rule can forbid named character classes in any text Claude writes through a tool.
- A rule can check Claude's finished reply and give Claude one non-error correction turn.
- The emoji definition is exact (Unicode data), not a hand-picked glyph list.

## Non-goals

- `MessageDisplay` (rewriting what the user sees). Deferred; see `docs/adr/0001-hook-events-beyond-pretooluse.md`.
- `SubagentStop`. Subagent reports arrive as `SubagentHandback` tool calls, which PreToolUse covers.
- An in-band opt-out marker. Code spans, escapes, and the local config override cover the legitimate cases.
- Path exclusion matchers (`path_not_any`).

## Rule schema

```toml
[[rule]]
id = "no-emoji-in-tool-input"
tool = "*"
action = "reject"
message = "..."
[rule.match]
content_chars = ["emoji", "status_markers", "emdash"]

[[rule]]
id = "no-emoji-in-replies"
event = "Stop"
action = "reject"
message = "..."
[rule.match]
content_chars = ["emoji", "status_markers", "emdash"]
```

- `event`: `"PreToolUse"` (default) or `"Stop"`.
- `tool = "*"`: matches every tool, including MCP tools. Not valid with `rewrite`.
- `content_chars`: names of character classes; the rule matches when the content contains at least one character from any listed class. ANDs with `content_regex` / `content_contains` like the other content matchers.

Validation:
- A `Stop` rule must be `reject`, must not set `tool` or `tool_any`, and may only use content matchers.
- An unknown class name, or an empty `content_chars` list, is invalid.

## Character classes

| Name | Definition |
|---|---|
| `emoji` | A code point with `Emoji_Presentation` not followed by U+FE0E; a code point with `Emoji` followed by U+FE0F; or a keycap (`[0-9#*]`, optional U+FE0F, U+20E3). The reported hit extends over trailing U+FE0F, skin-tone modifiers, tag characters, U+20E3, and ZWJ-joined code points. Data comes from Unicode `emoji-data.txt`, compiled into a checked-in generated table. |
| `status_markers` | U+2713 ✓, U+2714 ✔, U+2717 ✗, U+2718 ✘, U+2610 ☐, U+2611 ☑, U+2612 ☒, U+26A0 ⚠, U+2733 ✳, U+2734 ✴, U+2605 ★, U+2606 ☆ |
| `emdash` | U+2014 |

A code point that qualifies as `emoji` is reported once, as emoji.

## Content per tool

| Tool | Content | Format |
|---|---|---|
| Bash | `command` | raw |
| Write | `content` | raw |
| Edit | `new_string` | raw |
| NotebookEdit | `new_source` | raw |
| ExitPlanMode | plan file body (resolved from the transcript, unchanged) | markdown |
| Agent | `prompt` | markdown |
| SubagentHandback | `message` | markdown |
| AskUserQuestion | all string values in `tool_input` | markdown |
| Read, Grep, Glob, WebFetch, WebSearch | none | |
| any other tool (including MCP) | all string values in `tool_input` except `file_path`, `notebook_path`, `path`, joined by newlines | raw |
| `Stop` event | `last_assistant_message` | markdown |

Read-only tools carry no content so that searching for a character (for example, to remove it) is never rejected.

## Code spans

In markdown content, `content_chars` ignores text inside code spans. Raw content is checked in full. Only `content_chars` applies this; `content_regex` and `content_contains` see the content unchanged.

| Input | Result |
|---|---|
| `Done ✅` | reject |
| ``Run `grep -E "✓\|✗"` `` | allow |
| a ```` ``` ```` fence containing `echo "✓ ok"` | allow |
| a `~~~` fence containing ✅ | allow |
| ``` ``a ` ✓`` ``` | allow |
| `⚠️ careful` | reject (emoji) |
| `⚠ careful` | reject (status marker) |
| `Press ⌘K`, `a → b`, `#1`, `1. step`, `©` | allow |
| `pages 1–5` | allow |
| `foo — bar` | reject |
| `> ✓ check passed` | reject |
| a fence that never closes, then ✅ | allow (the rest of the text is code) |
| `` it's `✓ ok `` with no closing backtick | reject (a lone backtick is literal) |
| a line indented four spaces containing ✅ | reject (only fences count as code) |

## Hook behavior

- **PreToolUse reject** keeps its current shape (exit 2, `[rule-id] message` on stderr, reject marker on stdout). When the rule has `content_chars`, stderr also lists up to five hits as `line N: U+XXXX (glyph)` followed by `and N more` when there are more.
- **Stop**: veer reads `hook_event_name`, `last_assistant_message`, and `stop_hook_active`. When `stop_hook_active` is true, veer allows without evaluating. On a reject it exits 0 and writes `{"systemMessage":"[rule-id] reject","hookSpecificOutput":{"hookEventName":"Stop","additionalContext":"[rule-id] message\n<hits>"}}`.
- Any other `hook_event_name` is allowed silently (exit 0, no output). A missing `hook_event_name` means PreToolUse.

## Install

`veer install` (all scopes) registers `veer check` under both `hooks.PreToolUse` (matcher `*`, as today) and `hooks.Stop` (no matcher). Uninstall removes both.

## veer test

`veer test --event Stop --content-file reply.md` and `veer test --tool Write --content-file file.txt` evaluate content rules, using the same content format the hook would use, and print hit lines after the result line.
