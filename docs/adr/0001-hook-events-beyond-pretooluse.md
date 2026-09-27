# veer handles hook events beyond PreToolUse

veer began as a PreToolUse hook, but the corrections users most want to codify include things Claude writes as plain replies, such as emoji, which never pass through a tool call. Rules therefore carry an `event` (defaulting to `PreToolUse`), and veer registers for `Stop` as well, branching on the `hook_event_name` in each hook's input. A `Stop` rejection is returned as `additionalContext` ("Stop hook feedback") rather than `decision: "block"`, because a style correction is not an error, and it fires at most once per reply (it is skipped when `stop_hook_active` is true) so a misfiring rule cannot loop.

## Considered Options

- **Treat events as pseudo-tools (`tool = "Stop"`)**: rejected because it overloads "tool" and hides that each event has a different effect (blocking a call, adding a turn, changing only the display).
- **An event-neutral "text surface" abstraction**: rejected for the same reason; the rule author should see which hook does what.
- **An in-band opt-out marker Claude can add to use a banned character**: rejected because the cheapest response to a rejection becomes adding the marker. Code spans, escape sequences, and the user's local config override cover the legitimate cases.

## Consequences

- `MessageDisplay` (display-only rewriting) is deferred: it needs state carried across line batches to track code fences, and without `Stop` feedback it would hide drift from the user while Claude keeps reinforcing it in context.
- `SubagentStop` is not supported; since Claude Code 2.1.271 subagent reports arrive through the `SubagentHandback` tool, which PreToolUse rules already cover.
