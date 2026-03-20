# Implementation Spec: veer - Stage 4: Storage Layer

**Contract**: `docs/spec/contract.md`
**References**: `docs/spec/veer-prd.md` (SQLite schema, pragmas), `docs/spec/veer-spec.md` (Store interface, SqliteStore, MemoryStore, async write thread)
**Depends on**: Stage 1 (SQLite in build system), Stage 3 (engine to wire into)
**Estimated Effort**: M

## Technical Approach

This stage adds persistence for check results. The key design principle from the spec: **the rest of the codebase never imports SQLite**. All storage access goes through a `Store` interface using a vtable pattern.

Three components:
1. **Store interface** -- vtable-based abstraction (`src/store/store.zig`)
2. **MemoryStore** -- in-memory implementation for tests (`src/store/memory_store.zig`)
3. **SqliteStore** -- production implementation with async write thread (`src/store/sqlite_store.zig`)

Stats recording is fire-and-forget: the engine calls `store.recordCheck()` and it returns immediately. A background thread drains a bounded queue and writes to SQLite. If the queue is full, entries are dropped (stats are best-effort).

## Feedback Strategy

**Inner-loop command**: `zig build test`
**Playground**: Test blocks in each store module. MemoryStore tests validate the interface contract. SqliteStore tests validate real database operations.
**Why this approach**: The Store interface is tested via MemoryStore (fast, no I/O). SqliteStore is tested separately against a temporary database file.

## File Changes

### New Files

| File Path | Purpose |
|-----------|---------|
| `src/store/store.zig` | Store interface definition (vtable pattern) + CheckEntry struct |
| `src/store/memory_store.zig` | In-memory Store implementation (for tests) |
| `src/store/sqlite_store.zig` | SQLite Store implementation with async write thread |

### Modified Files

| File Path | Changes |
|-----------|---------|
| `src/engine/engine.zig` | Accept optional Store at init. Call `store.recordCheck()` after each check. |
| `src/cli/check.zig` | Initialize SqliteStore (or skip if stats disabled), pass to engine. |
| `build.zig` | Add store modules to test list. |

## Implementation Details

### Store Interface (src/store/store.zig)

Follow the vtable pattern from `docs/spec/veer-spec.md` lines 33-76.

```zig
const std = @import("std");

pub const Action = enum { approve, rewrite, warn, deny };

pub const CheckEntry = struct {
    timestamp: i64,              // unix millis
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

pub const StatsQuery = struct {
    since: ?i64 = null,    // unix millis
    rule_id: ?[]const u8 = null,
};

pub const StatsResult = struct {
    total_checks: u64,
    approved: u64,
    rewritten: u64,
    warned: u64,
    denied: u64,
};

pub const RuleStats = struct {
    rule_id: []const u8,
    hit_count: u64,
    last_hit: i64,
    first_hit: i64,
    action: Action,
};

pub const CommandFrequency = struct {
    base_command: []const u8,
    count: u64,
    last_seen: i64,
};

pub const Store = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        recordCheck: *const fn (ptr: *anyopaque, entry: CheckEntry) void,
        getStats: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, opts: StatsQuery) anyerror!StatsResult,
        getRuleStats: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, rule_id: []const u8) anyerror!?RuleStats,
        getTopCommands: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, limit: u32) anyerror![]CommandFrequency,
        close: *const fn (ptr: *anyopaque) void,
    };

    pub fn recordCheck(self: Store, entry: CheckEntry) void {
        self.vtable.recordCheck(self.ptr, entry);
    }
    pub fn getStats(self: Store, allocator: std.mem.Allocator, opts: StatsQuery) !StatsResult {
        return self.vtable.getStats(self.ptr, allocator, opts);
    }
    pub fn getRuleStats(self: Store, allocator: std.mem.Allocator, rule_id: []const u8) !?RuleStats {
        return self.vtable.getRuleStats(self.ptr, allocator, rule_id);
    }
    pub fn getTopCommands(self: Store, allocator: std.mem.Allocator, limit: u32) ![]CommandFrequency {
        return self.vtable.getTopCommands(self.ptr, allocator, limit);
    }
    pub fn close(self: Store) void {
        self.vtable.close(self.ptr);
    }
};
```

### MemoryStore (src/store/memory_store.zig)

Follow `docs/spec/veer-spec.md` lines 161-183. Stores entries in an ArrayList. Query methods iterate the list. Used exclusively for tests.

```zig
pub const MemoryStore = struct {
    entries: std.ArrayList(CheckEntry),

    pub fn init(allocator: std.mem.Allocator) MemoryStore { ... }
    pub fn deinit(self: *MemoryStore) void { ... }
    pub fn store(self: *MemoryStore) Store { ... } // Returns Store interface

    // VTable implementations operate on the ArrayList
};
```

### SqliteStore (src/store/sqlite_store.zig)

Follow `docs/spec/veer-spec.md` lines 80-158.

**Schema** from `docs/spec/veer-prd.md` lines 509-552:
```sql
CREATE TABLE IF NOT EXISTS checks (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
    session_id TEXT,
    tool_name TEXT NOT NULL,
    command TEXT,
    base_command TEXT,
    rule_id TEXT,
    action TEXT NOT NULL,
    message TEXT,
    rewritten_to TEXT,
    duration_us INTEGER
);
CREATE INDEX idx_checks_timestamp ON checks(timestamp);
CREATE INDEX idx_checks_rule_id ON checks(rule_id);
CREATE INDEX idx_checks_base_command ON checks(base_command);
CREATE INDEX idx_checks_action ON checks(action);
```

**Pragmas** (applied on connection open):
```sql
PRAGMA journal_mode=WAL;
PRAGMA synchronous=NORMAL;
PRAGMA temp_store=MEMORY;
PRAGMA cache_size=-2000;
```

**Async write thread**: SqliteStore spawns a background thread that drains a BoundedQueue. `recordCheck()` pushes to the queue (non-blocking, drops on full queue). The write thread batches inserts.

```zig
pub const SqliteStore = struct {
    db: ?*c.sqlite3,
    insert_stmt: ?*c.sqlite3_stmt, // Prepared once, reused
    write_thread: ?std.Thread,
    queue: BoundedQueue(CheckEntry, 256),
    shutdown: std.atomic.Value(bool),

    pub fn init(path: [:0]const u8) !SqliteStore { ... }
    pub fn close(self: *SqliteStore) void {
        // 1. Signal shutdown
        // 2. Join write thread (drains remaining entries)
        // 3. Finalize prepared statements
        // 4. Close database
    }
    pub fn store(self: *SqliteStore) Store { ... }
};
```

**BoundedQueue**: A simple lock-free (or mutex-protected) ring buffer. `tryPush()` returns false if full. `tryPop()` returns null if empty.

**Database location**:
- Project: `.veer/veer.db`
- Global: `~/.config/veer/veer.db`
- Match the config file location (project vs global)

**Feedback loop**:
- **Playground**: Test blocks in sqlite_store.zig with temp database files
- **Experiment**: Record entries, then query stats. Verify counts match. Test concurrent writes.
- **Check command**: `zig build test`

### Engine Wiring

Modify `Engine.init()` to accept an optional Store:

```zig
pub const Engine = struct {
    config: Config,
    allocator: std.mem.Allocator,
    store: ?Store,

    pub fn check(self: *Engine, input: HookInput) !CheckResult {
        // ... existing logic ...
        // After determining result, record to store (fire-and-forget):
        if (self.store) |s| {
            s.recordCheck(.{
                .timestamp = std.time.milliTimestamp(),
                .session_id = input.session_id,
                .tool_name = input.tool_name,
                .command = extractCommand(input),
                .base_command = extractBaseCommand(result, info),
                .rule_id = result.rule_id,
                .action = mapAction(result.action),
                .message = result.message,
                .rewritten_to = result.rewrite_to,
                .duration_us = timer.read(),
            });
        }
        return result;
    }
};
```

## Testing Requirements

### MemoryStore Tests

- `recordCheck` appends entry to list
- `getStats` returns correct counts (total, by action)
- `getStats` with `since` filter excludes old entries
- `getRuleStats` returns stats for specific rule ID
- `getRuleStats` returns null for unknown rule ID
- `getTopCommands` returns commands ordered by frequency

### SqliteStore Tests

- Init creates database and tables
- `recordCheck` + `getStats` round-trip
- Schema includes all expected indexes
- WAL mode is enabled
- Close drains remaining queue entries
- Multiple concurrent recordCheck calls don't lose data

### Engine + Store Integration

- Engine with MemoryStore records check results
- Engine with null store (stats disabled) still returns correct results
- Recorded entry has correct rule_id, action, duration

## Error Handling

| Scenario | Handling |
|----------|----------|
| SQLite open failure | Log error, continue without stats (store = null in engine) |
| Queue full (write backpressure) | Drop entry silently (stats are best-effort) |
| Write thread crash | Log error, mark store as degraded, continue without stats |
| Database locked | WAL mode prevents this for concurrent reads during writes |

## Validation Commands

```bash
zig build test

# Manual: run a check with stats enabled, verify .veer/veer.db is created
echo '{"tool_name":"Bash","tool_input":{"command":"ls"}}' | zig build run -- check
ls -la .veer/veer.db
```
