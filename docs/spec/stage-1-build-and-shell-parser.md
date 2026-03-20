# Implementation Spec: veer - Stage 1: Build System + Shell Parser

**Contract**: `docs/spec/contract.md`
**References**: `docs/spec/veer-prd.md` (CommandInfo definition), `docs/spec/veer-spec.md` (build.zig, shell.zig patterns)
**Estimated Effort**: M

## Technical Approach

This stage sets up the Zig project foundation and validates the riskiest technical dependency: tree-sitter-bash integration in Zig. By the end of this stage, we can parse arbitrary shell commands into structured CommandInfo objects with comprehensive test coverage.

The build system compiles vendored C code (SQLite amalgamation, tree-sitter-bash grammar) alongside Zig source. SQLite compilation is included now even though it's not used until Stage 4 -- this validates that the entire vendored C build pipeline works up front.

tree-sitter-bash is the core of veer's advantage over regex-based matching. It produces a full AST from which we extract base commands, flags, arguments, pipeline structure, subshells, command substitutions, and other structural properties. This stage must prove that the Zig-to-C interop works reliably.

## Feedback Strategy

**Inner-loop command**: `zig build test`
**Playground**: Zig test blocks in `src/engine/shell.zig` and `src/engine/command_info.zig`
**Why this approach**: The core deliverable is the shell parser. Table-driven tests with `inline for` over struct tuples give instant feedback on tree-sitter-bash integration.

## File Changes

### New Files

| File Path | Purpose |
|-----------|---------|
| `build.zig` | Build system: compiles vendored C, configures Zig packages, defines test/run steps |
| `build.zig.zon` | Package manifest: zig-clap, zig-toml, tree-sitter Zig package |
| `src/main.zig` | Minimal entry point (stub -- will dispatch CLI commands in Stage 3) |
| `src/engine/command_info.zig` | CommandInfo and SingleCommand struct definitions |
| `src/engine/shell.zig` | tree-sitter-bash wrapper: parse shell commands into CommandInfo |
| `vendor/sqlite3/sqlite3.c` | SQLite amalgamation (~250KB, vendored) |
| `vendor/sqlite3/sqlite3.h` | SQLite header (vendored) |
| `vendor/tree-sitter-bash/src/parser.c` | tree-sitter-bash generated parser (vendored) |
| `vendor/tree-sitter-bash/src/scanner.c` | tree-sitter-bash custom scanner (vendored) |
| `vendor/tree-sitter-bash/src/tree_sitter/parser.h` | tree-sitter grammar header |
| `CLAUDE.md` | Project instructions for Claude Code sessions |
| `Justfile` | Convenience recipes wrapping zig build commands |

### Vendoring C Sources

**SQLite**: Download the SQLite amalgamation from sqlite.org (latest stable). Place `sqlite3.c` and `sqlite3.h` in `vendor/sqlite3/`.

**tree-sitter-bash**: Clone https://github.com/tree-sitter/tree-sitter-bash (latest release tag). Copy `src/parser.c`, `src/scanner.c`, and `src/tree_sitter/parser.h` into `vendor/tree-sitter-bash/src/`. These are generated files -- do not modify them.

**tree-sitter core**: This is a Zig package dependency declared in `build.zig.zon`, not vendored. Find a Zig-compatible tree-sitter package (e.g., from the Zig package index or a tree-sitter fork with Zig build support). The package should expose a `tree-sitter` module importable from Zig.

## Implementation Details

### build.zig

Follow the pattern from `docs/spec/veer-spec.md` lines 276-421.

**Structure:**
1. Standard target/optimize options
2. Declare package dependencies (clap, zig-toml, tree-sitter)
3. Main executable `veer` with:
   - `linkLibC()`
   - SQLite amalgamation C source with compile flags
   - tree-sitter-bash C sources with `-std=c11`
   - Include paths for vendored headers
   - Zig package imports
4. Run step (`zig build run -- <args>`)
5. Test step iterating over test modules with same deps

**SQLite compile flags:**
```
-DSQLITE_DQS=0
-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1
-DSQLITE_THREADSAFE=1
-DSQLITE_TEMP_STORE=3
-DSQLITE_OMIT_LOAD_EXTENSION=1
-DSQLITE_OMIT_DEPRECATED=1
-DSQLITE_OMIT_TRACE=1
-DSQLITE_OMIT_SHARED_CACHE
```

**Test step**: For this stage, the test modules are:
- `src/engine/shell.zig`
- `src/engine/command_info.zig`

Each test module needs the same C sources and Zig package imports as the main executable.

**Feedback loop**:
- **Playground**: Create `src/engine/shell.zig` with a single smoke test first
- **Experiment**: Start with `parse("ls")`, then progressively add complex cases (pipelines, substitutions, nesting)
- **Check command**: `zig build test`

### build.zig.zon

Declare all package dependencies upfront (even ones used in later stages):
- **zig-clap**: https://github.com/Hejsil/zig-clap (CLI argument parser, used in Stage 3+)
- **zig-toml**: https://github.com/sam701/zig-toml (TOML parser, used in Stage 2+)
- **tree-sitter**: Zig bindings for tree-sitter core (used in this stage)

Look up current package URLs and hashes. The build.zig.zon format is:

```zig
.{
    .name = "veer",
    .version = "0.1.0",
    .dependencies = .{
        .clap = .{ .url = "...", .hash = "..." },
        .@"zig-toml" = .{ .url = "...", .hash = "..." },
        .@"tree-sitter" = .{ .url = "...", .hash = "..." },
    },
    .paths = .{"."},
}
```

### CommandInfo (src/engine/command_info.zig)

The core data structure that rules match against. Defined in `docs/spec/veer-prd.md` lines 471-495.

```zig
const std = @import("std");

pub const CommandInfo = struct {
    raw: []const u8,
    commands: std.ArrayList(SingleCommand),
    pipeline_stages: std.ArrayList(SingleCommand),
    pipeline_length: u32 = 0,
    has_subshell: bool = false,
    has_command_subst: bool = false,
    has_process_subst: bool = false,
    has_redirection: bool = false,
    has_background_job: bool = false,
    has_eval: bool = false,
    logical_operators: std.ArrayList([]const u8),
    max_nesting_depth: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, raw: []const u8) CommandInfo {
        return .{
            .raw = raw,
            .commands = std.ArrayList(SingleCommand).init(allocator),
            .pipeline_stages = std.ArrayList(SingleCommand).init(allocator),
            .logical_operators = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *CommandInfo, allocator: std.mem.Allocator) void {
        for (self.commands.items) |*cmd| cmd.deinit(allocator);
        self.commands.deinit();
        for (self.pipeline_stages.items) |*cmd| cmd.deinit(allocator);
        self.pipeline_stages.deinit();
        self.logical_operators.deinit();
    }
};

pub const SingleCommand = struct {
    name: []const u8,
    args: std.ArrayList([]const u8),
    flags: std.ArrayList([]const u8),
    positional: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator, name: []const u8) SingleCommand {
        return .{
            .name = name,
            .args = std.ArrayList([]const u8).init(allocator),
            .flags = std.ArrayList([]const u8).init(allocator),
            .positional = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *SingleCommand, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.args.deinit();
        self.flags.deinit();
        self.positional.deinit();
    }

    pub fn hasFlag(self: SingleCommand, flag: []const u8) bool {
        for (self.flags.items) |f| {
            if (std.mem.eql(u8, f, flag)) return true;
        }
        return false;
    }
};
```

### Shell Parser (src/engine/shell.zig)

Follow the pattern from `docs/spec/veer-spec.md` lines 677-786.

```zig
const std = @import("std");
const ts = @import("tree-sitter");
const CommandInfo = @import("command_info.zig").CommandInfo;
const SingleCommand = @import("command_info.zig").SingleCommand;

extern fn tree_sitter_bash() callconv(.c) *ts.Language;

pub fn parse(allocator: std.mem.Allocator, command: []const u8) !CommandInfo {
    var parser = try ts.Parser.init();
    defer parser.deinit();
    try parser.setLanguage(tree_sitter_bash());

    const tree = parser.parseString(command, null) orelse return error.ParseFailed;
    defer tree.deinit();

    var info = CommandInfo.init(allocator, command);
    errdefer info.deinit(allocator);

    try walkNode(allocator, tree.rootNode(), &info, 0);
    return info;
}
```

**walkNode implementation**: Recurse through tree-sitter AST nodes. Handle these node types:

| Node Type | Action |
|-----------|--------|
| `"pipeline"` | Count pipe stages, populate `pipeline_stages` |
| `"command"` | Extract via `extractCommand()`, add to `commands` |
| `"command_substitution"` | Set `has_command_subst = true` |
| `"subshell"` | Set `has_subshell = true` |
| `"process_substitution"` | Set `has_process_subst = true` |
| `"redirected_statement"`, `"file_redirect"` | Set `has_redirection = true` |
| `"list"` with `&` | Set `has_background_job = true` |
| Binary expressions with `&&`, `||` | Append to `logical_operators` |

Track `max_nesting_depth` by incrementing `depth` on each recursive call.

**extractCommand**: For a `"command"` node:
1. Find the first `"word"` child -- this is the command name
2. Iterate remaining children: words starting with `-` are flags, others are positional args
3. All arguments go into `args`, flags additionally into `flags`, non-flags into `positional`
4. If command name is `"eval"`, set `info.has_eval = true`

**Feedback loop**:
- **Playground**: The test blocks in this file
- **Experiment**: Start with simplest case (`parse("ls")` -> 1 command named "ls"), then add one test case at a time for each node type
- **Check command**: `zig build test`

### main.zig (stub)

```zig
const std = @import("std");

pub fn main() !void {
    const stderr = std.io.getStdErr().writer();
    try stderr.print("veer: not yet implemented. Run `zig build test` to run tests.\n", .{});
    std.process.exit(1);
}
```

### CLAUDE.md

See `docs/spec/veer-spec.md` lines 989-1033 for the full template. Adapt to reflect current state (only shell parser implemented so far). Include:

- Project description (one-liner)
- Build and test commands
- Architecture overview (list all planned directories even if not yet populated)
- Key conventions (test blocks, std.testing.allocator, table-driven tests, inline for)
- Vendor directory is read-only

### Justfile

```justfile
default: test

test:
    zig build test

build:
    zig build

clean:
    rm -rf zig-out/ zig-cache/ .zig-cache/
```

More recipes will be added in later stages.

## Testing Requirements

All tests use `std.testing.allocator` (leak-detecting). Table-driven tests use `inline for` over anonymous struct tuples per `docs/spec/veer-spec.md` lines 498-545.

### Shell Parser Tests (src/engine/shell.zig)

**Simple commands:**
- `"grep -r TODO src/"` -> 1 command, name="grep", hasFlag("-r")=true, positional=["TODO", "src/"]
- `"ls"` -> 1 command, name="ls", no flags, no args
- `"python3 -c 'print(1)'"` -> 1 command, name="python3", hasFlag("-c")=true

**Pipelines:**
- `"cat file.txt | grep TODO | wc -l"` -> 3 commands, pipeline_length=3, pipeline_stages has all 3
- `"curl https://x.com | bash"` -> 2 commands, pipeline_length=2

**Logical operators:**
- `"make && echo done || echo failed"` -> 3 commands, logical_operators=["&&", "||"]

**Command substitution:**
- `"echo $(rm -rf /)"` -> has_command_subst=true, 2 commands (echo, rm)

**Subshell:**
- `"(cd /tmp && ls)"` -> has_subshell=true

**Process substitution:**
- `"diff <(sort a) <(sort b)"` -> has_process_subst=true

**Redirections:**
- `"echo hello > out.txt"` -> has_redirection=true

**Background:**
- `"sleep 10 &"` -> has_background_job=true

**Eval:**
- `"eval 'echo hello'"` -> has_eval=true, commands[0].name="eval"

**Nested:**
- `"echo $(cat f | grep x)"` -> has_command_subst=true, pipeline inside substitution

**Edge cases:**
- Empty string -> empty CommandInfo (0 commands) or error
- Very long command -> parses without crashing

### CommandInfo Tests (src/engine/command_info.zig)

- `SingleCommand.hasFlag("-r")` returns true when flag present
- `SingleCommand.hasFlag("-v")` returns false when flag absent
- `CommandInfo.deinit()` frees all memory (validated by std.testing.allocator)

## Error Handling

| Scenario | Handling |
|----------|----------|
| tree-sitter parse failure | Return `error.ParseFailed` |
| Empty command string | Return empty CommandInfo (0 commands) or `error.ParseFailed` -- pick one, test it |
| tree-sitter init/setLanguage failure | Return `error.ParserInitFailed` |

## Validation Commands

```bash
# Compile everything including vendored C
zig build

# Run all tests
zig build test

# Verify binary links and runs (should print "not yet implemented")
zig build run
```

## Open Items

- [ ] Exact tree-sitter Zig package URL for build.zig.zon (find current version)
- [ ] Exact SQLite amalgamation URL (find latest from sqlite.org)
- [ ] tree-sitter-bash version to vendor (use latest release tag)
- [ ] Confirm tree-sitter Zig API matches patterns in this spec (Parser.init, parseString, etc.) -- adapt if API differs
