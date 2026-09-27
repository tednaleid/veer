# veer

veer is a Claude Code hook that holds an agent to a user's standing corrections, so a "don't do that, do this" is written down once instead of repeated every session.

## Language

**Rule**:
One codified correction: what it applies to, what it matches, and what happens on a match.
_Avoid_: Policy, check

**Hook event**:
The Claude Code lifecycle point a rule applies to, such as a tool call about to run, a reply that has finished, or text about to be displayed.
_Avoid_: Hook type, trigger

**Tool**:
The Claude Code tool a rule applies to, meaningful only for hook events that concern a tool call.
_Avoid_: Command (a command is the shell text inside a Bash tool call)

**Character class**:
A named set of characters a rule can forbid in text, such as emoji or em dashes, each defined by its own source of truth.
_Avoid_: Charset, glyph list
