# Re-running a rewritten call through the rules

Design for feeding a rewritten tool call back through the rule list instead of
returning it immediately.

Written against veer 0.2.0.

## Motivation

`rewrite` short-circuits. `engine.check` returns as soon as a rewrite rule
matches, so no rule below it is consulted. That breaks the property the `allow`
gate was built to provide.

Gates are supposed to be monotonically narrowing: adding one can only reduce
what passes. `config.zig` orders rules local tier, then project, then global,
so a private `.veer/config.local.toml` sits above every team rule. The
narrowing property is what makes that ordering safe. A rewrite rule in the
private tier defeats it, because it returns before any team gate below it runs.

There is a second, smaller reason. A guard should judge what will actually
execute. If `pytest` rewrites to `just test` and a gate below forbids `just`
invocations, the gate is reasoning about a command that will never run.

## What this does not fix

A separate hole, already closed: `rewrite` on a tool carrying no `command`
field emitted `updatedInput: {"command": ...}` plus
`permissionDecision: "allow"`, auto-approving the call. That is now a
validation error and is not what this design addresses. Re-running would not
have fixed it, because a rewrite rule placed first still fires before any gate.

## Design invariants

Two properties to preserve, both inherited from the path-matching work.

**veer fails open.** Every "cannot evaluate" case resolves to "do not fire".
An unparseable command approves. This design adds a re-parse per pass, and a
parse failure on a rewritten command must approve rather than block.

**Termination is structural, not a timeout.** The hot path cannot rely on an
iteration cap chosen by feel. Termination must follow from the algorithm.

## Design

### The loop

`engine.check` gains an outer loop around the existing rule scan.

```
fired: bitset over rule indices, initially empty
command: the call's original command
for pass in 0..rules.len:
    scan rules, skipping any index in `fired`
    no rule matched                  -> return allow
    matched rule is reject or allow  -> return that result immediately
    matched rule is rewrite          -> command = splice(command, rule)
                                        fired.set(rule_index)
                                        continue to next pass
return rewrite result carrying the final `command`
```

### Termination

`fired` is monotone: a rule is added and never removed, and a rule already in
the set is skipped. Each pass either returns or adds exactly one index, so
there are at most `rules.len` passes.

Excluding only the rule that just fired is **not** sufficient. Rule A rewrites
X to Y, rule B rewrites Y to X, and the pair loops forever. The monotone set
costs the same and is provably terminating, so use it.

### The command string carries forward

Each pass matches against the output of the previous one. This is the whole
point: the last pass sees what will actually execute.

`spliceRewrite` in `src/cli/check.zig` currently splices `rewrite_to` into the
original command at `[match_start, match_end)`, the byte range of the matched
command inside a compound statement. That range is what makes
`pytest tests/ && echo done` rewrite to `just test && echo done` rather than
collapsing to `just test`.

After one rewrite, a second pass's `match_start` and `match_end` refer to the
*previous pass's output*, not the original input. Two ways to handle it:

1. **Materialize each pass.** Splice into a fresh buffer and carry that buffer
   forward as the new command. Each pass allocates one string.
2. **Compose offset maps.** Keep the original and a list of edits, translating
   later offsets back through earlier ones.

Take option 1. Option 2 is a source of off-by-one bugs for no benefit at these
sizes. The allocation is bounded by the pass count, which is bounded by the
rule count, and every pass but the first is rare in practice.

Splicing must move from `check.zig` into the engine, or the engine must return
enough for `check.zig` to do it. Moving it in is cleaner: the engine already
owns match offsets, and `check.zig` keeping a splice helper that only applies
to the final pass would be a trap.

### Re-parsing

Command matchers run against a tree-sitter AST, not the raw string. A rewritten
command is a different string, so evaluating any command matcher against it
requires a fresh `shell.parse`.

Parsing dominates `veer check`. Today it happens once. Under this design it
happens once per pass. Mitigations, in order of preference:

- **Parse lazily.** Only re-parse when a rule below actually reads the
  `command` field. A config whose remaining rules are all path or content
  gates needs no second parse at all, which is the common case for the
  tier-safety scenario that motivates this work.
- **Bound by the rule count**, which is already the pass bound.

A parse failure on a rewritten command approves the call, matching the existing
fail-open behavior for an unparseable original.

`src/bench.zig` gains a chained-rewrite case, since this adds work to the hot
path and the PRD asks for a benchmark on every PR.

### What the agent sees when a later rule rejects

The awkward case: the agent runs `pytest`, a rewrite turns it into
`just test`, and a gate below rejects `just test`. The agent gets a message
about a command it never wrote.

The reject message must name the rewrite chain. Something like:

```
[no-bare-just] pytest tests/ was rewritten to just test by [use-just-test],
which this rule rejects: use a specific recipe, not bare just.
```

This needs `CheckResult` to carry the chain, or at least the id of the last
rewriting rule and the pre-rewrite command. Without it the reject is baffling
and the feature is worse than the bug it fixes.

### Verbose mode

The banner today renders `original -> rewritten`. With chaining it should
render the full chain, `pytest tests/ -> just test -> just test --fast`, so the
transcript shows what happened rather than only the endpoints.

## Alternatives considered

**Leave it, document it.** What shipped in 0.2.0. The README's tier-safety
claim had to be narrowed to reject and allow rules. Cheapest, but leaves the
narrowing invariant conditional on rule authors not using rewrite, which is not
an invariant.

**Forbid rewrite in the local tier.** Directly targets the escape and needs no
loop. Rejected: the local tier is where a developer's personal
`pytest` to `just test` redirects most naturally live, and forbidding the most
useful action there to protect a property most configs never exercise is a bad
trade.

**Make gates evaluate before all other actions**, regardless of file order.
A gate pass would then always precede a rewrite. Rejected: it makes evaluation
order depend on action type rather than document order, which is harder to
reason about and breaks the existing first-match-wins mental model that the
rest of veer is built on.

## Testing

- Termination: a two-rule cycle (A rewrites to B's trigger, B rewrites to A's)
  terminates and returns a defined result.
- A gate below a rewrite sees the rewritten command and can reject it.
- A gate below a rewrite that the rewritten command satisfies falls through.
- Chained rewrites compose: A then B produces both edits, with the compound
  command's untouched portions intact.
- A rewrite whose output fails to parse approves rather than blocks.
- The single-rewrite case produces byte-identical output to 0.2.0, pinned by
  the existing rewrite tests.
- Bench: one rewrite, and a three-deep chain.

## Non-goals

**No cycle detection beyond the fired set.** A rule that rewrites to its own
trigger simply fires once and is then skipped.

**No fixpoint semantics.** Evaluation stops at the first reject, allow
failure, or exhausted rule list. It does not re-run until the command stops
changing.

**Rewrite still cannot target a non-command tool.** That is a validation error
as of 0.2.0 and stays one.
