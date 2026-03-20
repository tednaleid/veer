# veer Contract

**Created**: 2026-03-20
**Confidence Score**: 96/100
**Status**: Approved

**References**:
- `docs/spec/veer-prd.md` -- Product requirements, config format, command semantics
- `docs/spec/veer-spec.md` -- Zig implementation details, code patterns, architecture

## Problem Statement

Claude Code agents frequently execute shell commands that bypass project conventions: running `pytest` instead of `just test`, invoking `python3` directly instead of `just run`, or executing dangerous pipelines like `curl | bash`. The agent doesn't know about project-specific workflows and Claude Code's built-in permission system (allowedTools/deniedTools) is binary -- it can only allow or block, not redirect.

Developers need a tool that intercepts agent tool calls before execution and redirects them toward safer, project-appropriate alternatives -- not as a hard security boundary, but as a gentle nudge that helps the agent self-correct.

## Goals

1. **Intercept and redirect agent tool calls** via Claude Code's PreToolUse hook protocol with < 2ms latency for 10 rules
2. **Parse shell commands structurally** using tree-sitter-bash AST rather than regex, reducing false positives on pipelines, quoting, and command substitution
3. **Ship as a single static binary** under 2MB for each platform (macOS aarch64/x86_64, Linux aarch64/x86_64)
4. **Bootstrap rules from real usage** by mining JSONL session transcripts to discover command patterns
5. **Track and surface usage statistics** to help users identify dormant rules and unmatched commands worth adding rules for

## Success Criteria

- [ ] `veer check` processes stdin JSON and returns correct exit code + output for rewrite/warn/deny/allow actions
- [ ] Shell parser correctly handles: simple commands, pipelines, logical operators, subshells, command substitution, process substitution, redirections, eval, nested structures
- [ ] All match types work: command, command_glob, command_regex, pipeline_contains, has_flag, arg_pattern, ast, tool (non-Bash)
- [ ] Config loading supports TOML with project + global merging, priority ordering, enabled/disabled rules
- [ ] `veer check` completes in < 2ms for 10 rules, < 5ms for 50 rules
- [ ] Binary size < 2MB (ReleaseSmall)
- [ ] Stats recorded to SQLite without adding to check latency (async writes)
- [ ] `veer scan` parses JSONL transcripts at > 50,000 lines/sec
- [ ] `veer install` correctly modifies Claude Code settings.json
- [ ] All management commands work: add, remove, list, stats

## Scope Boundaries

### In Scope

- PreToolUse hook implementation (veer check)
- Shell AST parsing via tree-sitter-bash
- TOML config with rule matching (command, glob, regex, pipeline, flag, arg, ast)
- Non-Bash tool matching (tool field for Read/Write/Edit/etc.)
- SQLite stats with async writes
- Management CLI (install, add, remove, list, stats) -- flag-based only, no interactive mode
- Transcript mining (veer scan)
- Cross-compilation for macOS + Linux
- Homebrew distribution

### Out of Scope

- Interactive `veer add` (flag-based only for v1)
- Rule sharing/import (`veer import <url>`)
- Justfile-aware auto-discovery of recipes
- Watch mode / live dashboard
- Support for non-Claude-Code agents (Cline, Aider)
- Complex rule conditions (UNLESS clauses)
- `veer init` interactive onboarding wizard

### Future Considerations

- Rule sharing/import for community rule packs
- Justfile integration for auto-generated redirect rules
- Agent-agnostic hook protocol for v2
- Complex rule conditions

## Execution Plan

### Dependency Graph

```
Stage 1 (Build + Shell) --+--> Stage 3 (Engine + Check) --> Stage 4 (Storage) --> Stage 7 (Release)
                          |        ^                                                    ^
Stage 2 (Config) ---------+--------'                                                    |
                          |                                                             |
                          +--> Stage 5 (Management CLI, needs 2+4) --------------------+
                          |                                                             |
                          '--> Stage 6 (Transcript Mining, needs 1+2) ------------------'
```

### Execution Steps

**Strategy**: Sequential

1. **Stage 1** -- Build System + Shell Parser _(no dependencies)_
   ```
   docs/spec/stage-1-build-and-shell-parser.md
   ```

2. **Stage 2** -- Config Loading + Rule Validation _(after Stage 1)_
   ```
   docs/spec/stage-2-config-and-rules.md
   ```

3. **Stage 3** -- Matching Engine + Check Command / MVP _(after Stages 1+2)_
   ```
   docs/spec/stage-3-engine-and-check.md
   ```

4. **Stage 4** -- Storage Layer _(after Stage 3)_
   ```
   docs/spec/stage-4-storage.md
   ```

5. **Stage 5** -- Management CLI + Install _(after Stages 2+4)_
   ```
   docs/spec/stage-5-management-cli.md
   ```

6. **Stage 6** -- Transcript Mining _(after Stages 1+2)_
   ```
   docs/spec/stage-6-transcript-mining.md
   ```

7. **Stage 7** -- Benchmarks + Release Infrastructure _(after all)_
   ```
   docs/spec/stage-7-release.md
   ```
