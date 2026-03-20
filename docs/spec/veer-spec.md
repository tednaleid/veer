# veer — Zig Implementation Spec

## Overview

**veer** is a fast CLI tool written in Zig that acts as a PreToolUse hook for Claude Code. It intercepts tool calls before execution, evaluates them against user-defined rules, and either rewrites, warns, or denies them — emitting helpful redirect messages so the agent self-corrects.

This spec covers the Zig-specific implementation. For product requirements, config format, command behavior, and rule semantics, see the companion PRD (`veer-spec.md`). This document focuses on: project structure, dependency strategy, build system, testing approach, storage abstraction, and Zig idioms.

**You need both documents:** `veer-prd.md` tells you *what* to build; this document tells you *how* to build it in Zig.

---

## Dependency Philosophy: Minimal and Vendored

Every external dependency must justify its existence. We prefer stdlib, then `@cImport` of stable C code, then vetted Zig packages.

| Need | Approach | Rationale |
|------|----------|-----------|
| CLI parsing | **zig-clap** (package) | 1,500+ stars, used by Zig compiler itself. Not worth reimplementing. |
| Shell AST | **tree-sitter** + **tree-sitter-bash** (C, compiled in) | Official zig-tree-sitter bindings. tree-sitter is battle-tested C. tree-sitter-bash used by Neovim, Helix, Zed. |
| JSON | **std.json** (stdlib) | Full-featured, zero deps. Handles Claude Code hook protocol. |
| TOML | **zig-toml** (package, sam701) | TOML v1.0.0 parser with comptime struct deserialization. TOML is too complex to reimplement well; this library is focused and small. |
| SQLite | **SQLite amalgamation via `@cImport`** (C, compiled in) | No wrapper library. We vendor `sqlite3.c` + `sqlite3.h` and call the C API directly through a thin Zig abstraction layer we own. This is the most stable approach possible — the dependency is SQLite itself, not someone's bindings. |
| Terminal colors | **std.io** + ANSI escapes (stdlib) | Write a small `display.zig` module. Not worth a dependency for color output. |
| Table formatting | **Hand-rolled** | Simple column alignment. ~100 lines of Zig. |

**Total external packages: 2** (zig-clap, zig-toml)
**Total vendored C: 2** (SQLite amalgamation, tree-sitter + tree-sitter-bash)

---

## Storage Abstraction

SQLite is an implementation detail. The rest of the codebase interacts with storage through a `Store` interface. This means we can swap SQLite for a flat file, an append-only log, or even an in-memory-only backend for testing — without touching anything outside `src/store/`.

```zig
// src/store/store.zig

/// Storage backend interface.
/// All methods accept an allocator for any dynamic allocation needed.
pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        recordCheck: *const fn (ptr: *anyopaque, entry: CheckEntry) void,
        getStats: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, opts: StatsQuery) anyerror!StatsResult,
        getRuleStats: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, rule_id: []const u8) anyerror!?RuleStats,
        getTopCommands: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, opts: TopCommandsQuery) anyerror![]CommandFrequency,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn recordCheck(self: Store, entry: CheckEntry) void {
        self.vtable.recordCheck(self.ptr, entry);
    }

    pub fn getStats(self: Store, allocator: std.mem.Allocator, opts: StatsQuery) !StatsResult {
        return self.vtable.getStats(self.ptr, allocator, opts);
    }

    // ... delegate other methods similarly
};

pub const CheckEntry = struct {
    timestamp: i64, // unix millis
    session_id: ?[]const u8,
    tool_name: []const u8,
    command: ?[]const u8,
    base_command: ?[]const u8,
    rule_id: ?[]const u8,
    action: Action,
    message: ?[]const u8,
    rewritten_to: ?[]const u8,
    duration_us: u64,
};

pub const Action = enum { approve, rewrite, warn, deny };
```

### SQLite Backend

```zig
// src/store/sqlite_store.zig

const c = @cImport({
    @cInclude("sqlite3.h");
});

pub const SqliteStore = struct {
    db: ?*c.sqlite3,
    insert_stmt: ?*c.sqlite3_stmt,
    write_thread: ?std.Thread,
    queue: BoundedQueue(CheckEntry, 256),
    shutdown: std.atomic.Value(bool),

    pub fn init(path: [:0]const u8) !SqliteStore {
        var db: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path.ptr, &db);
        if (rc != c.SQLITE_OK) return error.SqliteOpenFailed;

        // Run migrations
        try execSql(db, schema_sql);

        // Enable WAL mode for concurrent reads during writes
        try execSql(db, "PRAGMA journal_mode=WAL;");

        var store = SqliteStore{
            .db = db,
            .insert_stmt = null,
            .write_thread = null,
            .queue = BoundedQueue(CheckEntry, 256).init(),
            .shutdown = std.atomic.Value(bool).init(false),
        };

        // Prepare the insert statement once (reuse for all writes)
        store.insert_stmt = try prepareStmt(db, insert_sql);

        // Spawn background writer thread
        store.write_thread = try std.Thread.spawn(.{}, writeLoop, .{&store});

        return store;
    }

    /// Non-blocking enqueue. If queue is full, drop the entry (stats are best-effort).
    pub fn recordCheck(ptr: *anyopaque, entry: CheckEntry) void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        self.queue.tryPush(entry); // fire-and-forget
    }

    fn writeLoop(self: *SqliteStore) void {
        while (!self.shutdown.load(.acquire)) {
            if (self.queue.tryPop()) |entry| {
                self.writeEntry(entry);
            } else {
                std.Thread.sleep(1_000_000); // 1ms idle sleep
            }
        }
        // Drain remaining entries on shutdown
        while (self.queue.tryPop()) |entry| {
            self.writeEntry(entry);
        }
    }

    pub fn store(self: *SqliteStore) Store {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Store.VTable{
        .recordCheck = recordCheck,
        .getStats = getStats,
        .getRuleStats = getRuleStats,
        .getTopCommands = getTopCommands,
        .close = close,
    };

    // ... implementation details
};
```

### In-Memory Backend (for tests)

```zig
// src/store/memory_store.zig

pub const MemoryStore = struct {
    entries: std.ArrayList(CheckEntry),

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{ .entries = std.ArrayList(CheckEntry).init(allocator) };
    }

    pub fn recordCheck(ptr: *anyopaque, entry: CheckEntry) void {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.entries.append(entry) catch {};
    }

    pub fn store(self: *MemoryStore) Store {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    // ... vtable, query implementations over the ArrayList
};
```

This separation means:
- `src/engine/` never imports SQLite
- `src/cmd/` never imports SQLite
- Tests use `MemoryStore` — instant, no filesystem, no cleanup
- We could add a `FileStore` (append-only JSONL log) as a lightweight alternative
- SQLite could be swapped for DuckDB, LMDB, or anything else without touching business logic

---

## Project Structure

```
veer/
├── build.zig                      # Build system (replaces Justfile)
├── build.zig.zon                  # Package dependencies (zig-clap, zig-toml)
├── CLAUDE.md                      # Project instructions for Claude Code
├── README.md
├── LICENSE
│
├── vendor/                        # Vendored C code (checked into repo)
│   ├── sqlite3/
│   │   ├── sqlite3.c             # SQLite amalgamation (one file, ~250KB)
│   │   └── sqlite3.h
│   └── tree-sitter-bash/
│       ├── src/
│       │   ├── parser.c
│       │   └── scanner.c
│       └── src/tree_sitter/
│           └── parser.h
│
├── src/
│   ├── main.zig                   # Entry point — CLI dispatch only
│   │
│   ├── cli/                       # Command implementations
│   │   ├── check.zig              # veer check (hot path)
│   │   ├── scan.zig               # veer scan (transcript mining)
│   │   ├── install.zig            # veer install
│   │   ├── add.zig                # veer add
│   │   ├── list.zig               # veer list
│   │   ├── remove.zig             # veer remove
│   │   └── stats.zig              # veer stats
│   │
│   ├── engine/                    # Core matching engine
│   │   ├── engine.zig             # Rule evaluation orchestrator
│   │   ├── matcher.zig            # Match type implementations
│   │   ├── shell.zig              # tree-sitter-bash → CommandInfo extraction
│   │   └── command_info.zig       # CommandInfo struct definition
│   │
│   ├── config/                    # TOML config loading
│   │   ├── config.zig             # Config struct and loading logic
│   │   └── rule.zig               # Rule struct and validation
│   │
│   ├── claude/                    # Claude Code integration
│   │   ├── hook.zig               # Hook protocol (stdin/stdout/stderr)
│   │   ├── settings.zig           # settings.json reader
│   │   └── transcript.zig         # JSONL transcript parser
│   │
│   ├── store/                     # Storage abstraction
│   │   ├── store.zig              # Store interface definition
│   │   ├── sqlite_store.zig       # SQLite implementation
│   │   └── memory_store.zig       # In-memory implementation (tests)
│   │
│   └── display/                   # Terminal output
│       ├── table.zig              # Column-aligned table rendering
│       └── color.zig              # ANSI color helpers
│
└── test/                          # Test fixtures
    ├── configs/                   # Sample TOML config files
    │   ├── basic.toml
    │   ├── complex_rules.toml
    │   └── empty.toml
    ├── transcripts/               # Sample Claude Code JSONL sessions
    │   ├── simple_session.jsonl
    │   └── compacted_session.jsonl
    ├── settings/                  # Sample Claude Code settings.json
    │   ├── permissive.json
    │   └── restrictive.json
    └── commands/                  # Shell command test cases
        └── tricky_commands.txt
```

---

## build.zig

The build file replaces the Justfile entirely. All build tasks are defined as Zig build steps.

```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Dependencies ──────────────────────────────────────────

    const clap_dep = b.dependency("clap", .{
        .target = target,
        .optimize = optimize,
    });

    const toml_dep = b.dependency("zig-toml", .{
        .target = target,
        .optimize = optimize,
    });

    // ── Main executable ───────────────────────────────────────

    const exe = b.addExecutable(.{
        .name = "veer",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Link C dependencies
    exe.linkLibC();

    // SQLite amalgamation (vendored)
    exe.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_OMIT_TRACE=1",
            "-DSQLITE_OMIT_SHARED_CACHE",
        },
    });
    exe.addIncludePath(b.path("vendor/sqlite3"));

    // tree-sitter-bash (vendored)
    exe.addCSourceFiles(.{
        .root = b.path("vendor/tree-sitter-bash/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{"-std=c11"},
    });
    exe.addIncludePath(b.path("vendor/tree-sitter-bash/src"));

    // tree-sitter core (via zig-tree-sitter package)
    const ts_dep = b.dependency("tree-sitter", .{
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("tree-sitter", ts_dep.module("tree-sitter"));

    // Zig packages
    exe.root_module.addImport("clap", clap_dep.module("clap"));
    exe.root_module.addImport("toml", toml_dep.module("zig-toml"));

    b.installArtifact(exe);

    // ── Run command ───────────────────────────────────────────

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run veer");
    run_step.dependOn(&run_cmd.step);

    // ── Tests ─────────────────────────────────────────────────

    const test_modules = [_][]const u8{
        "src/engine/engine.zig",
        "src/engine/matcher.zig",
        "src/engine/shell.zig",
        "src/config/config.zig",
        "src/config/rule.zig",
        "src/claude/hook.zig",
        "src/claude/settings.zig",
        "src/claude/transcript.zig",
        "src/store/sqlite_store.zig",
        "src/store/memory_store.zig",
        "src/cli/check.zig",
        "src/cli/scan.zig",
    };

    const test_step = b.step("test", "Run all tests");
    for (test_modules) |path| {
        const t = b.addTest(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
        });
        // Add same deps as exe
        t.linkLibC();
        t.addCSourceFile(.{
            .file = b.path("vendor/sqlite3/sqlite3.c"),
            .flags = &.{ "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=1" },
        });
        t.addIncludePath(b.path("vendor/sqlite3"));
        t.root_module.addImport("clap", clap_dep.module("clap"));
        t.root_module.addImport("toml", toml_dep.module("zig-toml"));

        const run_t = b.addRunArtifact(t);
        test_step.dependOn(&run_t.step);
    }

    // ── Cross-compilation targets ─────────────────────────────

    const cross_step = b.step("cross", "Build for all release targets");
    const targets: []const std.Target.Query = &.{
        .{ .cpu_arch = .aarch64, .os_tag = .macos },
        .{ .cpu_arch = .x86_64, .os_tag = .macos },
        .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
        .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
    };
    for (targets) |t| {
        const cross_exe = b.addExecutable(.{
            .name = "veer",
            .root_source_file = b.path("src/main.zig"),
            .target = b.resolveTargetQuery(t),
            .optimize = .ReleaseSmall,
        });
        // ... add same C sources and packages ...
        cross_exe.linkLibC();
        const install = b.addInstallArtifact(cross_exe, .{});
        cross_step.dependOn(&install.step);
    }

    // ── Benchmarks ────────────────────────────────────────────

    const bench_exe = b.addExecutable(.{
        .name = "veer-bench",
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = .ReleaseFast,
    });
    // ... add deps ...
    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run.step);
}
```

### Build Commands

```bash
zig build              # Debug build
zig build test         # Run all tests
zig build bench        # Run benchmarks
zig build cross        # Build all release targets
zig build run -- check # Run veer check
zig build -Doptimize=ReleaseSmall  # Optimized build
```

A **Justfile is still useful** as a convenience wrapper for common compound workflows and for commands that aren't build-system tasks:

```justfile
# Convenience recipes that wrap zig build or do non-build tasks

default: test

# Run all tests
test:
    zig build test

# Run tests for a specific module
test-engine:
    zig build test -- --test-filter "engine"

# Build optimized release
release:
    zig build -Doptimize=ReleaseSmall

# Build all platforms
cross:
    zig build cross

# Run benchmarks
bench:
    zig build bench

# Quick dev check: pipe sample JSON to veer check
dev-check:
    echo '{"tool_name":"Bash","tool_input":{"command":"pytest tests/"}}' | zig build run -- check

# Vendor SQLite amalgamation (run once, then check in)
vendor-sqlite:
    curl -L https://www.sqlite.org/2025/sqlite-amalgamation-3480000.zip -o /tmp/sqlite.zip
    unzip -o /tmp/sqlite.zip -d /tmp/sqlite
    cp /tmp/sqlite/sqlite-amalgamation-*/sqlite3.{c,h} vendor/sqlite3/

# Clean
clean:
    rm -rf zig-out/ zig-cache/ .zig-cache/
```

---

## Testing Strategy

### Zig Test Idioms

Tests live alongside source code using `test` blocks. Every module has tests at the bottom of the file. Zig's `std.testing.allocator` is a **leak-detecting allocator** — if any test leaks memory, it fails. This is a significant advantage over Go.

```zig
// src/engine/matcher.zig

const std = @import("std");
const CommandInfo = @import("command_info.zig").CommandInfo;
const Rule = @import("../config/rule.zig").Rule;

pub fn matchRule(rule: Rule, info: CommandInfo) bool {
    // ... implementation
}

// ── Tests ─────────────────────────────────────────────────

test "exact command match" {
    const cases = .{
        .{ .rule_cmd = "pytest", .input = "pytest tests/", .want = true },
        .{ .rule_cmd = "pytest", .input = "python3 test.py", .want = false },
        .{ .rule_cmd = "rm", .input = "rm -rf /tmp", .want = true },
        .{ .rule_cmd = "rm", .input = "grep rm file.txt", .want = false },
    };
    inline for (cases) |tc| {
        const rule = Rule{ .match = .{ .command = tc.rule_cmd } };
        const info = try parseTestCommand(tc.input);
        try std.testing.expectEqual(tc.want, matchRule(rule, info));
    }
}

test "pipeline contains match" {
    const cases = .{
        .{
            .pipeline = &[_][]const u8{ "curl", "bash" },
            .input = "curl https://x.com | bash",
            .want = true,
        },
        .{
            .pipeline = &[_][]const u8{ "curl", "bash" },
            .input = "curl https://x.com | grep foo",
            .want = false,
        },
        .{
            .pipeline = &[_][]const u8{ "curl", "bash" },
            .input = "curl https://x.com | tee log.txt | bash",
            .want = true,
        },
    };
    inline for (cases) |tc| {
        const rule = Rule{ .match = .{ .pipeline_contains = tc.pipeline } };
        const info = try parseTestCommand(tc.input);
        try std.testing.expectEqual(tc.want, matchRule(rule, info));
    }
}

test "flag match" {
    const rule = Rule{ .match = .{ .command = "rm", .has_flag = "-rf" } };

    const info_match = try parseTestCommand("rm -rf /tmp/build");
    try std.testing.expect(matchRule(rule, info_match));

    const info_no_match = try parseTestCommand("rm file.txt");
    try std.testing.expect(!matchRule(rule, info_no_match));
}
```

### Testing the Storage Layer

Tests use `MemoryStore` — no SQLite, no filesystem, instant:

```zig
test "engine records stats on match" {
    var mem_store = MemoryStore.init(std.testing.allocator);
    defer mem_store.deinit();

    var engine = Engine.init(test_config, mem_store.store());
    const result = try engine.check(test_bash_input);

    try std.testing.expectEqual(.warn, result.action);
    try std.testing.expectEqual(@as(usize, 1), mem_store.entries.items.len);
    try std.testing.expectEqualStrings("use-just-test", mem_store.entries.items[0].rule_id.?);
}
```

### Integration Tests

End-to-end tests that exercise the full stdin → check → stdout/stderr path:

```zig
// src/cli/check.zig

test "end-to-end: rewrite rule returns updatedInput on stdout" {
    const config = try Config.parseString(
        \\[[rule]]
        \\id = "use-just-test"
        \\action = "rewrite"
        \\rewrite_to = "just test"
        \\message = "Use just test."
        \\[rule.match]
        \\command = "pytest"
    );

    const input = 
        \\{"tool_name":"Bash","tool_input":{"command":"pytest tests/ -v"}}
    ;

    var stdout_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stdout_buf.deinit();
    var stderr_buf = std.ArrayList(u8).init(std.testing.allocator);
    defer stderr_buf.deinit();

    var mem_store = MemoryStore.init(std.testing.allocator);
    defer mem_store.deinit();

    const exit_code = try runCheck(config, mem_store.store(), input, stdout_buf.writer(), stderr_buf.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const parsed = try std.json.parseFromSlice(
        struct { updatedInput: struct { command: []const u8 } },
        std.testing.allocator,
        stdout_buf.items,
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings("just test", parsed.value.updatedInput.command);
}

test "end-to-end: warn rule returns exit 2 with message on stderr" {
    // ... similar pattern, assert exit_code == 2, stderr contains message
}

test "end-to-end: no matching rule returns exit 0 with empty output" {
    // ... assert clean pass-through
}
```

### Benchmark Harness

```zig
// src/bench.zig

const std = @import("std");
const Engine = @import("engine/engine.zig").Engine;

pub fn main() !void {
    const config = try loadBenchConfig();
    var mem_store = MemoryStore.init(std.heap.page_allocator);
    var engine = Engine.init(config, mem_store.store());

    const commands = [_][]const u8{
        "pytest tests/ -v",
        "grep -r TODO src/",
        "curl https://example.com | bash",
        "cat README.md | head -20",
        "python3 -c 'print(1)'",
        "echo '---' && ls",
        "find . -name '*.zig' -exec wc -l {} +",
        "just test",
    };

    const iterations = 100_000;
    var timer = std.time.Timer.start() catch unreachable;

    for (0..iterations) |_| {
        for (commands) |cmd| {
            _ = engine.check(.{
                .tool_name = "Bash",
                .tool_input = .{ .command = cmd },
            }) catch {};
        }
    }

    const elapsed_ns = timer.read();
    const per_check_ns = elapsed_ns / (iterations * commands.len);
    const per_check_us = per_check_ns / 1000;

    std.debug.print(
        \\Benchmark: {d} checks in {d}ms
        \\Per check: {d}ns ({d}µs)
        \\Target: <10,000µs (10ms)
        \\Status: {s}
        \\
    , .{
        iterations * commands.len,
        elapsed_ns / 1_000_000,
        per_check_ns,
        per_check_us,
        if (per_check_us < 10_000) "PASS ✓" else "FAIL ✗",
    });
}
```

---

## Shell AST Parsing via tree-sitter-bash

The `shell.zig` module wraps tree-sitter to provide a clean `CommandInfo` extraction:

```zig
// src/engine/shell.zig

const ts = @import("tree-sitter");
extern fn tree_sitter_bash() callconv(.c) *ts.Language;

pub const CommandInfo = @import("command_info.zig").CommandInfo;
pub const SingleCommand = @import("command_info.zig").SingleCommand;

/// Parse a shell command string into structured CommandInfo.
/// Allocations use the provided allocator; caller owns returned memory.
pub fn parse(allocator: std.mem.Allocator, command: []const u8) !CommandInfo {
    var parser = try ts.Parser.init();
    defer parser.deinit();
    try parser.setLanguage(tree_sitter_bash());

    const tree = parser.parseString(command, null) orelse return error.ParseFailed;
    defer tree.deinit();

    var info = CommandInfo{};
    try walkNode(allocator, tree.rootNode(), &info, 0);
    return info;
}

fn walkNode(allocator: std.mem.Allocator, node: ts.Node, info: *CommandInfo, depth: u32) !void {
    const node_type = node.typeAsString();

    if (std.mem.eql(u8, node_type, "pipeline")) {
        info.pipeline_length += 1;
        // Count pipe stages
        var child_count: u32 = 0;
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            const child = node.child(i) orelse continue;
            if (std.mem.eql(u8, child.typeAsString(), "command")) {
                child_count += 1;
            }
        }
        info.pipeline_length = child_count;
    }

    if (std.mem.eql(u8, node_type, "command")) {
        const cmd = try extractCommand(allocator, node);
        try info.commands.append(allocator, cmd);
    }

    if (std.mem.eql(u8, node_type, "command_substitution")) {
        info.has_command_subst = true;
    }

    if (std.mem.eql(u8, node_type, "subshell")) {
        info.has_subshell = true;
    }

    if (std.mem.eql(u8, node_type, "process_substitution")) {
        info.has_process_subst = true;
    }

    info.max_nesting_depth = @max(info.max_nesting_depth, depth);

    // Recurse into children
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const child = node.child(i) orelse continue;
        try walkNode(allocator, child, info, depth + 1);
    }
}

// ── Tests ─────────────────────────────────────────────────

test "parse simple command" {
    const info = try parse(std.testing.allocator, "grep -r TODO src/");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), info.commands.items.len);
    try std.testing.expectEqualStrings("grep", info.commands.items[0].name);
    try std.testing.expect(info.commands.items[0].hasFlag("-r"));
}

test "parse pipeline extracts all stages" {
    const info = try parse(std.testing.allocator, "cat file.txt | grep TODO | wc -l");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), info.commands.items.len);
    try std.testing.expectEqualStrings("cat", info.commands.items[0].name);
    try std.testing.expectEqualStrings("grep", info.commands.items[1].name);
    try std.testing.expectEqualStrings("wc", info.commands.items[2].name);
}

test "parse detects command substitution" {
    const info = try parse(std.testing.allocator, "echo $(rm -rf /)");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.has_command_subst);
    // Should find both 'echo' and 'rm' as commands
    try std.testing.expectEqual(@as(usize, 2), info.commands.items.len);
}

test "parse handles logical operators" {
    const info = try parse(std.testing.allocator, "make && echo done || echo failed");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), info.commands.items.len);
    try std.testing.expectEqualStrings("make", info.commands.items[0].name);
}
```

---

## Claude Code JSONL Transcript Parser

```zig
// src/claude/transcript.zig

/// Stream-parse a JSONL transcript file, yielding Bash commands.
/// Designed for large files: processes line-by-line, never loads full file.
pub fn streamCommands(
    allocator: std.mem.Allocator,
    reader: anytype,
    callback: *const fn (cmd: BashCommand) void,
) !u64 {
    var count: u64 = 0;
    var line_buf: [1024 * 64]u8 = undefined; // 64KB line buffer

    while (reader.readUntilDelimiterOrEof(&line_buf, '\n')) |maybe_line| {
        const line = maybe_line orelse break;
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{ .ignore_unknown_fields = true },
        ) catch continue; // skip malformed lines
        defer parsed.deinit();

        const root = parsed.value;

        // Only process assistant messages with tool_use content
        const msg_type = getStr(root, "type") orelse continue;
        if (!std.mem.eql(u8, msg_type, "assistant")) continue;

        const message = root.object.get("message") orelse continue;
        const content = message.object.get("content") orelse continue;

        for (content.array.items) |block| {
            const block_type = getStr(block, "type") orelse continue;
            if (!std.mem.eql(u8, block_type, "tool_use")) continue;

            const name = getStr(block, "name") orelse continue;
            if (!std.mem.eql(u8, name, "Bash")) continue;

            const input = block.object.get("input") orelse continue;
            const command = getStr(input, "command") orelse continue;

            const timestamp = getStr(root, "timestamp");

            callback(.{
                .command = command,
                .timestamp = timestamp,
                .session_id = getStr(root, "sessionId"),
            });
            count += 1;
        }
    }
    return count;
}

// ── Tests ─────────────────────────────────────────────────

test "streamCommands extracts Bash tool_use commands" {
    const jsonl =
        \\{"type":"user","message":{"role":"user","content":"run tests"}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"pytest tests/"}}]},"timestamp":"2025-07-01T10:00:00Z"}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"src/main.zig"}}]},"timestamp":"2025-07-01T10:00:01Z"}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"just lint"}}]},"timestamp":"2025-07-01T10:00:02Z"}
    ;

    var commands = std.ArrayList([]const u8).init(std.testing.allocator);
    defer commands.deinit();

    var stream = std.io.fixedBufferStream(jsonl);
    const count = try streamCommands(std.testing.allocator, stream.reader(), &struct {
        fn cb(cmd: BashCommand) void { commands.append(cmd.command) catch {}; }
    }.cb);

    try std.testing.expectEqual(@as(u64, 2), count);
    try std.testing.expectEqualStrings("pytest tests/", commands.items[0]);
    try std.testing.expectEqualStrings("just lint", commands.items[1]);
}
```

---

## Implementation Phases

### Phase 1: AST Parser + Transcript Mining (start here)

Build and validate the two hardest unknowns: does tree-sitter-bash integration work cleanly in Zig, and can we reliably parse real JSONL transcripts?

**Deliverables:**
1. `build.zig` with vendored SQLite + tree-sitter-bash compiling
2. `src/engine/shell.zig` — tree-sitter-bash → `CommandInfo` with comprehensive tests
3. `src/claude/transcript.zig` — JSONL streaming parser with tests
4. `src/claude/settings.zig` — settings.json reader with command classification
5. `src/cli/scan.zig` — `veer scan` producing table + TOML output

**Red tests to write first:**
- Shell parser: simple command, pipeline, logical operators, subshell, command substitution, nested structures, eval, process substitution, redirections
- Transcript parser: extract Bash commands, skip non-Bash tools, handle compaction boundaries, handle malformed lines gracefully
- Settings: classify allowed/denied/prompt commands against glob patterns

### Phase 2: Config + Check Engine

1. `src/config/` — TOML config loading with rule validation
2. `src/engine/matcher.zig` — all match types
3. `src/engine/engine.zig` — priority-ordered evaluation
4. `src/cli/check.zig` — full hook protocol with exit codes
5. `src/bench.zig` — performance benchmarks

### Phase 3: Storage + Management

1. `src/store/` — Store interface, SqliteStore, MemoryStore
2. `src/cli/add.zig`, `remove.zig`, `list.zig`, `stats.zig`
3. `src/cli/install.zig`
4. Async write thread for SQLite

### Phase 4: Release

1. `zig build cross` for all targets
2. Homebrew formula (tap)
3. GitHub Actions CI
4. README, CLAUDE.md

---

## Performance Targets

| Operation | Target | Zig advantage |
|-----------|--------|---------------|
| `veer check` (10 rules) | < 2ms | No GC, no runtime init |
| `veer check` (50 rules) | < 5ms | Predictable latency |
| Binary size | < 2 MB | ~7× smaller than Go |
| Startup time | < 100µs | No runtime overhead |
| JSONL parse rate | > 50,000 lines/sec | Zero-alloc streaming |
| Memory usage | < 5 MB RSS | Manual allocation |

---

## Error Handling Pattern

Zig's `errdefer` and exhaustive error unions enforce correctness. The pattern for veer:

```zig
// Errors are typed and explicit — no stringly-typed errors
pub const ConfigError = error{
    FileNotFound,
    ParseFailed,
    InvalidRule,
    MissingRequiredField,
    DuplicateRuleId,
};

pub fn loadConfig(allocator: std.mem.Allocator, path: []const u8) ConfigError!Config {
    const file = std.fs.cwd().openFile(path, .{}) catch return error.FileNotFound;
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch return error.ParseFailed;
    errdefer allocator.free(content); // only frees on error return

    const config = parseToml(content) catch return error.ParseFailed;
    try validateRules(config.rules); // propagates InvalidRule, DuplicateRuleId, etc.

    return config;
}
```

For the `check` hot path, errors in stats recording are **swallowed** (stats are best-effort), while errors in rule matching **propagate** (a broken rule should be visible):

```zig
pub fn check(self: *Engine, input: HookInput) !CheckResult {
    const info = try shell.parse(self.allocator, input.tool_input.command);
    defer info.deinit(self.allocator);

    for (self.rules) |rule| {
        if (matcher.matchRule(rule, info)) {
            // Stats recording is fire-and-forget
            self.store.recordCheck(.{
                .rule_id = rule.id,
                .action = rule.action,
                // ...
            });

            return .{
                .action = rule.action,
                .message = rule.message,
                .rewrite_to = rule.rewrite_to,
            };
        }
    }

    self.store.recordCheck(.{ .action = .approve, .rule_id = null });
    return .{ .action = .approve };
}
```

---

## CLAUDE.md (Project Instructions)

This file goes in the repo root and instructs Claude Code how to work on veer:

```markdown
# veer

A fast CLI tool (Zig) that acts as a Claude Code PreToolUse hook to redirect
agent tool calls toward safer alternatives.

## Build & Test

- Build: `zig build`
- Test: `zig build test`
- Run: `zig build run -- <subcommand>`
- Bench: `zig build bench`
- Cross-compile: `zig build cross`

## Architecture

- `src/engine/` — Core matching engine. CommandInfo + rule matchers.
- `src/store/` — Storage abstraction. **Never import sqlite3 outside this dir.**
- `src/claude/` — Claude Code integration (hook protocol, settings, transcripts).
- `src/config/` — TOML config loading.
- `src/cli/` — Command implementations.
- `vendor/` — Vendored C code (SQLite, tree-sitter-bash). Do not modify.

## Key Conventions

- Tests live alongside source code in `test` blocks at bottom of each file.
- Use `std.testing.allocator` in all tests (detects leaks).
- Table-driven tests via `inline for` over anonymous struct tuples.
- The `Store` interface in `src/store/store.zig` is the ONLY way to access storage.
  Tests use `MemoryStore`. Production uses `SqliteStore`.
- `src/engine/` must not import anything from `src/store/` directly — it receives
  a `Store` interface at init time.
- All C interop is isolated: SQLite in `src/store/sqlite_store.zig`,
  tree-sitter in `src/engine/shell.zig`.

## Just Recipes

- `just test` — run all tests
- `just dev-check` — pipe sample JSON through veer check
- `just vendor-sqlite` — update vendored SQLite amalgamation
```
