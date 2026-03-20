# Implementation Spec: veer - Stage 3: Matching Engine + Check Command (MVP)

**Contract**: `docs/spec/contract.md`
**References**: `docs/spec/veer-prd.md` (match semantics, hook protocol), `docs/spec/veer-spec.md` (engine, matcher, hook patterns)
**Depends on**: Stage 1 (shell parser), Stage 2 (config + rules)
**Estimated Effort**: L

## Technical Approach

This is the MVP stage. After completing it, veer is a functional PreToolUse hook that can be registered with Claude Code.

The stage implements three layers:
1. **Matcher** -- individual match-type functions (command, glob, regex, pipeline, flag, arg, ast, tool)
2. **Engine** -- orchestrates rule evaluation: loads config, parses shell commands, evaluates rules in priority order, returns first match
3. **Check command** -- the CLI entry point that reads JSON from stdin, runs the engine, and outputs the result via exit code + stdout/stderr per the hook protocol

Non-Bash tool matching is included: rules can specify `tool = "Write"` (or any tool name) to match non-Bash tool calls directly against `tool_input` fields.

## Feedback Strategy

**Inner-loop command**: `zig build test`
**Playground**: Test blocks in matcher.zig, engine.zig, hook.zig, and check.zig. End-to-end tests pipe JSON through the check flow.
**Why this approach**: Each layer is testable in isolation. The end-to-end tests in check.zig validate the full stdin-to-exit-code path.

## File Changes

### New Files

| File Path | Purpose |
|-----------|---------|
| `src/engine/matcher.zig` | Match-type implementations (command, glob, regex, pipeline, flag, arg, ast) |
| `src/engine/engine.zig` | Rule evaluation orchestrator (priority order, first-match-wins) |
| `src/claude/hook.zig` | Hook protocol: parse stdin JSON, format stdout/stderr output, exit codes |
| `src/cli/check.zig` | `veer check` command implementation |

### Modified Files

| File Path | Changes |
|-----------|---------|
| `src/main.zig` | Replace stub with CLI dispatch. Parse first argument, call check command. |
| `build.zig` | Add new source files to test modules list |

## Implementation Details

### Matcher (src/engine/matcher.zig)

Each match type is a separate function. A rule matches when ALL specified match fields are true (AND logic).

See `docs/spec/veer-prd.md` lines 600-643 for match semantics.

```zig
const std = @import("std");
const Rule = @import("../config/rule.zig").Rule;
const MatchConfig = @import("../config/rule.zig").MatchConfig;
const CommandInfo = @import("command_info.zig").CommandInfo;
const SingleCommand = @import("command_info.zig").SingleCommand;

/// Returns true if the rule matches the given command info.
/// All specified match fields must match (AND logic).
/// For Bash tools: checks every command in the parsed AST.
pub fn matchRule(rule: Rule, info: CommandInfo) bool {
    const m = rule.match;

    // For each command in the AST, check if all match fields match
    for (info.commands.items) |cmd| {
        if (matchSingleCommand(m, cmd, info)) return true;
    }

    // Pipeline-level matches (don't need per-command iteration)
    if (m.pipeline_contains) |required| {
        if (!matchPipelineContains(required, info)) return false;
        // If pipeline_contains is the ONLY match field, it matched
        if (isOnlyPipelineMatch(m)) return true;
    }

    // AST-level matches
    if (m.ast) |ast_match| {
        return matchAst(ast_match, info);
    }

    return false;
}
```

**Match functions:**

| Function | Match Field | Matches Against | Logic |
|----------|------------|-----------------|-------|
| `matchCommand(pattern, cmd)` | `command` | `SingleCommand.name` | Exact string equality |
| `matchCommandGlob(pattern, cmd)` | `command_glob` | `SingleCommand.name` | Glob with brace expansion, wildcards |
| `matchCommandRegex(pattern, cmd)` | `command_regex` | `SingleCommand.name` | Regex match |
| `matchPipelineContains(required, info)` | `pipeline_contains` | `info.pipeline_stages[].name` | All listed commands appear in pipeline stages |
| `matchFlag(flag, cmd)` | `has_flag` | `SingleCommand.flags` | Flag present in command's flags |
| `matchArgPattern(pattern, cmd)` | `arg_pattern` | `SingleCommand.args` | Glob match against any argument |
| `matchAst(ast_match, info)` | `ast` | `CommandInfo` structural properties | Node type exists at min depth/count |

**Glob matching**: Implement a simple glob matcher supporting `*` (any chars), `?` (single char), and `{a,b,c}` (brace expansion). Zig stdlib may not have glob matching, so implement a small one (~50-80 lines). Brace expansion means `{ruff,uvx}` matches either `ruff` or `uvx`.

**Regex matching**: Use a simple regex implementation or pattern matching. If Zig stdlib doesn't provide regex, consider a minimal approach: compile the pattern once, test against the command name. This is explicitly documented as an "escape hatch" in the PRD, so a basic implementation is acceptable.

**Non-Bash tool matching**: When `rule.tool` is not "Bash", the rule matches against the tool_name directly. The engine skips shell parsing for non-Bash tools and matches `tool_input` fields against the rule's pattern fields.

**Feedback loop**:
- **Playground**: Test blocks in matcher.zig
- **Experiment**: One test per match type. Start with `matchCommand` (simplest), then add each type.
- **Check command**: `zig build test`

### Engine (src/engine/engine.zig)

```zig
const std = @import("std");
const Config = @import("../config/config.zig").Config;
const Rule = @import("../config/rule.zig").Rule;
const Action = @import("../config/rule.zig").Action;
const matcher = @import("matcher.zig");
const shell = @import("shell.zig");
const CommandInfo = @import("command_info.zig").CommandInfo;

pub const CheckResult = struct {
    action: Action,
    rule_id: ?[]const u8,
    message: ?[]const u8,
    rewrite_to: ?[]const u8,

    pub const approve = CheckResult{
        .action = .approve, // Note: approve is not in Action enum yet,
        .rule_id = null,    // we need a "no match" result
        .message = null,
        .rewrite_to = null,
    };
};

pub const HookInput = struct {
    tool_name: []const u8,
    tool_input: std.json.Value, // Parsed JSON object
    session_id: ?[]const u8,
};

pub const Engine = struct {
    config: Config,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, config: Config) Engine {
        return .{ .config = config, .allocator = allocator };
    }

    pub fn check(self: *Engine, input: HookInput) !CheckResult {
        // 1. If tool is Bash, parse command into CommandInfo via shell.parse()
        // 2. If tool is not Bash, create minimal info for tool matching
        // 3. Iterate rules in priority order (already sorted by config)
        // 4. Skip disabled rules
        // 5. Skip rules where rule.tool doesn't match input.tool_name
        // 6. For Bash: call matcher.matchRule(rule, info)
        // 7. For non-Bash: match tool_input fields against rule.match
        // 8. On first match: return CheckResult with rule's action/message/rewrite_to
        // 9. No match: return CheckResult.approve
    }
};
```

**Feedback loop**:
- **Playground**: Test blocks in engine.zig
- **Experiment**: Create a config with 3 rules (rewrite, warn, deny). Test that matching returns the right action for each. Test priority ordering. Test no-match case.
- **Check command**: `zig build test`

### Hook Protocol (src/claude/hook.zig)

Handles the Claude Code PreToolUse hook I/O contract from `docs/spec/veer-prd.md` lines 22-64.

```zig
const std = @import("std");

pub const HookInput = struct {
    session_id: ?[]const u8,
    tool_name: []const u8,
    tool_input: std.json.Value,
};

/// Parse hook input from a JSON string (read from stdin).
pub fn parseInput(allocator: std.mem.Allocator, json_str: []const u8) !HookInput

/// Format a rewrite result for stdout.
/// Returns JSON: {"updatedInput": {"command": "<rewrite_to>"}}
pub fn formatRewrite(allocator: std.mem.Allocator, tool_name: []const u8, rewrite_to: []const u8) ![]const u8

/// Exit code mapping:
/// - Allow (no match): 0, empty stdout, empty stderr
/// - Rewrite: 0, updatedInput JSON on stdout, empty stderr
/// - Warn: 2, empty stdout, message on stderr
/// - Deny: 2, empty stdout, message on stderr
pub const ExitCode = struct {
    pub const allow: u8 = 0;
    pub const rewrite: u8 = 0;
    pub const block: u8 = 2; // Used for both warn and deny
};
```

**Rewrite output format** for Bash tools:
```json
{"updatedInput": {"command": "just test"}}
```

For non-Bash tools, the rewrite would need to replace the appropriate field in tool_input. For v1, non-Bash rules only support warn/deny (not rewrite), since the replacement semantics vary per tool.

### Check Command (src/cli/check.zig)

The actual `veer check` entry point. Reads stdin, runs engine, writes output.

```zig
const std = @import("std");
const Config = @import("../config/config.zig");
const Engine = @import("../engine/engine.zig").Engine;
const hook = @import("../claude/hook.zig");

/// Run the check command. Returns exit code.
/// Reads JSON from stdin, evaluates against rules, writes result.
pub fn run(
    allocator: std.mem.Allocator,
    config: Config.Config,
    stdin_reader: anytype,
    stdout_writer: anytype,
    stderr_writer: anytype,
) !u8 {
    // 1. Read all of stdin
    // 2. Parse as HookInput
    // 3. Create engine with config
    // 4. Run engine.check(input)
    // 5. Based on result.action:
    //    - approve: exit 0, write nothing
    //    - rewrite: exit 0, write updatedInput JSON to stdout
    //    - warn: exit 2, write message to stderr
    //    - deny: exit 2, write message to stderr
    // 6. Return exit code
}
```

**Testability**: The `run` function takes reader/writer interfaces so tests can inject buffers instead of real stdin/stdout. Follow the pattern from `docs/spec/veer-spec.md` lines 571-617.

**Feedback loop**:
- **Playground**: Test blocks in check.zig
- **Experiment**: Pipe JSON strings through `run()` with buffer writers. Test all 4 outcomes (allow, rewrite, warn, deny).
- **Check command**: `zig build test`

### main.zig Update

Replace the stub with CLI dispatch:

```zig
const std = @import("std");
const check = @import("cli/check.zig");
const Config = @import("config/config.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        try printUsage();
        std.process.exit(1);
    }

    const command = args[1];
    if (std.mem.eql(u8, command, "check")) {
        const config = Config.loadMerged(allocator) catch |err| {
            // Handle config errors, exit with message
        };
        const exit_code = try check.run(
            allocator,
            config,
            std.io.getStdIn().reader(),
            std.io.getStdOut().writer(),
            std.io.getStdErr().writer(),
        );
        std.process.exit(exit_code);
    } else {
        try printUsage();
        std.process.exit(1);
    }
}
```

## Testing Requirements

### Matcher Tests (src/engine/matcher.zig)

Follow the table-driven pattern from `docs/spec/veer-spec.md` lines 498-545.

**command match:**
- `"pytest"` matches rule with command="pytest" -> true
- `"python3"` matches rule with command="pytest" -> false
- `"rm"` in `"grep rm file.txt"` -> check that "rm" as argument doesn't match (it's not a base command)

**command_glob match:**
- `"ruff"` matches `"{ruff,uvx}"` -> true
- `"uvx"` matches `"{ruff,uvx}"` -> true
- `"black"` matches `"{ruff,uvx}"` -> false
- `"pytest"` matches `"py*"` -> true

**command_regex match:**
- `"python3"` matches `"python[23]?"` -> true
- `"python"` matches `"python[23]?"` -> true
- `"ruby"` matches `"python[23]?"` -> false

**pipeline_contains match:**
- `"curl https://x | bash"` matches `["curl", "bash"]` -> true
- `"curl https://x | grep foo"` matches `["curl", "bash"]` -> false
- `"curl https://x | tee log | bash"` matches `["curl", "bash"]` -> true (both present)

**has_flag match:**
- `"rm -rf /tmp"` with has_flag="-rf" -> true
- `"rm file.txt"` with has_flag="-rf" -> false

**arg_pattern match:**
- `"echo '---'"` with arg_pattern=`'"---"'` -> true (glob against args)

**AND logic:**
- Rule with command="rm" AND has_flag="-rf" -> matches `"rm -rf /tmp"`, doesn't match `"rm file.txt"`, doesn't match `"ls -rf"`

**Priority and first-match:**
- Two rules matching same command, lower priority wins
- First matching rule stops evaluation

### Engine Tests (src/engine/engine.zig)

- Bash tool with matching rewrite rule -> CheckResult with action=rewrite
- Bash tool with matching warn rule -> CheckResult with action=warn
- Bash tool with matching deny rule -> CheckResult with action=deny
- Bash tool with no matching rule -> CheckResult.approve
- Non-Bash tool (e.g., tool_name="Write") matching a tool rule -> correct result
- Disabled rule is skipped
- Rules evaluated in priority order

### Hook Protocol Tests (src/claude/hook.zig)

- Parse valid stdin JSON with Bash tool -> correct HookInput
- Parse valid stdin JSON with non-Bash tool -> correct HookInput
- Parse JSON with missing fields -> appropriate error
- Format rewrite output -> valid JSON with updatedInput
- Exit code mapping: approve=0, rewrite=0, warn=2, deny=2

### End-to-End Tests (src/cli/check.zig)

Follow patterns from `docs/spec/veer-spec.md` lines 571-617.

- Pipe rewrite rule input -> exit 0, stdout has updatedInput JSON
- Pipe warn rule input -> exit 2, stderr has message
- Pipe deny rule input -> exit 2, stderr has message
- Pipe no-match input -> exit 0, empty stdout, empty stderr
- Pipe non-Bash tool input -> correct result based on tool rules

### Manual Testing

After implementation, test with actual piped input:
```bash
echo '{"tool_name":"Bash","tool_input":{"command":"pytest tests/ -v"}}' | zig build run -- check
```

This should produce output based on the loaded config (or exit 0 if no config exists).

## Error Handling

| Scenario | Handling |
|----------|----------|
| stdin read failure | Exit 1, error message to stderr |
| Invalid JSON on stdin | Exit 1, error message to stderr |
| Config load failure | Exit 1, error message to stderr |
| Shell parse failure | Exit 0 (allow) -- if we can't parse, don't block. Log warning to stderr. |
| Regex compile failure | Skip that rule, log warning. Don't block the entire check. |

**Key principle from the spec**: Errors in stats recording are swallowed (best-effort). Errors in rule matching that prevent a definitive result should default to allow (exit 0) -- veer should never block a tool call due to its own bugs.

## Validation Commands

```bash
# Run all tests
zig build test

# Manual smoke test (should exit 0 with no config)
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | zig build run -- check

# Manual smoke test with a config file
echo '{"tool_name":"Bash","tool_input":{"command":"pytest tests/"}}' | zig build run -- check --config test/configs/basic.toml
```
