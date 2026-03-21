// ABOUTME: SQLite-backed Store implementation with async write thread.
// ABOUTME: Non-blocking recordCheck via bounded queue, background thread drains to disk.

const std = @import("std");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const CheckEntry = store_mod.CheckEntry;
const StatsQuery = store_mod.StatsQuery;
const StatsResult = store_mod.StatsResult;
const RuleStats = store_mod.RuleStats;
const CommandFrequency = store_mod.CommandFrequency;
const Action = store_mod.Action;

const c = @cImport({
    @cInclude("sqlite3.h");
});

// Use SQLITE_STATIC (null) -- data lives for the bind+step+reset cycle.
// SQLITE_STATIC doesn't translate correctly via @cImport in Zig 0.15.
const SQLITE_STATIC: c.sqlite3_destructor_type = null;

const schema_sql =
    \\CREATE TABLE IF NOT EXISTS checks (
    \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
    \\    timestamp INTEGER NOT NULL,
    \\    session_id TEXT,
    \\    tool_name TEXT NOT NULL,
    \\    command TEXT,
    \\    base_command TEXT,
    \\    rule_id TEXT,
    \\    action TEXT NOT NULL,
    \\    message TEXT,
    \\    rewritten_to TEXT,
    \\    duration_us INTEGER
    \\);
    \\CREATE INDEX IF NOT EXISTS idx_checks_timestamp ON checks(timestamp);
    \\CREATE INDEX IF NOT EXISTS idx_checks_rule_id ON checks(rule_id);
    \\CREATE INDEX IF NOT EXISTS idx_checks_base_command ON checks(base_command);
    \\CREATE INDEX IF NOT EXISTS idx_checks_action ON checks(action);
;

const insert_sql =
    \\INSERT INTO checks (timestamp, session_id, tool_name, command, base_command,
    \\    rule_id, action, message, rewritten_to, duration_us)
    \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
;

const QUEUE_SIZE = 256;

pub const SqliteStore = struct {
    db: ?*c.sqlite3 = null,
    insert_stmt: ?*c.sqlite3_stmt = null,
    write_thread: ?std.Thread = null,
    queue: BoundedQueue(CheckEntry, QUEUE_SIZE) = .{},
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Open the database and prepare statements. Call start() after the
    /// SqliteStore has a stable address (not on the stack of init).
    pub fn init(path: [*:0]const u8) !SqliteStore {
        var self = SqliteStore{};

        if (c.sqlite3_open(path, &self.db) != c.SQLITE_OK) {
            return error.SqliteOpenFailed;
        }

        // Apply pragmas
        try execSql(self.db, "PRAGMA journal_mode=WAL;");
        try execSql(self.db, "PRAGMA synchronous=NORMAL;");
        try execSql(self.db, "PRAGMA temp_store=MEMORY;");
        try execSql(self.db, "PRAGMA cache_size=-2000;");

        // Create schema
        try execSql(self.db, schema_sql);

        // Prepare insert statement
        if (c.sqlite3_prepare_v2(self.db, insert_sql, -1, &self.insert_stmt, null) != c.SQLITE_OK) {
            return error.SqlitePrepareFailed;
        }

        return self;
    }

    /// Spawn the background write thread. Must be called after the SqliteStore
    /// is at a stable address (the caller's var, not init's stack local).
    pub fn start(self: *SqliteStore) !void {
        self.write_thread = std.Thread.spawn(.{}, writeLoop, .{self}) catch {
            return error.ThreadSpawnFailed;
        };
    }

    pub fn close(self: *SqliteStore) void {
        // Signal shutdown and wait for writer to drain
        self.shutdown.store(true, .release);
        if (self.write_thread) |thread| {
            thread.join();
        }

        if (self.insert_stmt) |stmt| {
            _ = c.sqlite3_finalize(stmt);
        }
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
        }
    }

    /// Return a Store interface backed by this SqliteStore.
    pub fn store(self: *SqliteStore) Store {
        return .{
            .ptr = @ptrCast(self),
            .vtable = &vtable,
        };
    }

    const vtable = Store.VTable{
        .recordCheck = recordCheckImpl,
        .getStats = getStatsImpl,
        .getRuleStats = getRuleStatsImpl,
        .getTopCommands = getTopCommandsImpl,
        .close = closeVtableImpl,
    };

    // -- VTable implementations --

    fn recordCheckImpl(ptr: *anyopaque, entry: CheckEntry) void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        // Non-blocking: push to queue, drop if full
        self.queue.tryPush(entry);
    }

    fn getStatsImpl(ptr: *anyopaque, _: std.mem.Allocator, opts: StatsQuery) anyerror!StatsResult {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        var result = StatsResult{};

        const sql = if (opts.since != null)
            "SELECT action, COUNT(*) FROM checks WHERE timestamp >= ?1 GROUP BY action"
        else
            "SELECT action, COUNT(*) FROM checks GROUP BY action";

        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqliteQueryFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        if (opts.since) |since| {
            _ = c.sqlite3_bind_int64(stmt, 1, since);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const action_text = c.sqlite3_column_text(stmt, 0);
            const count: u64 = @intCast(c.sqlite3_column_int64(stmt, 1));

            if (action_text) |txt| {
                const action = std.mem.span(txt);
                if (std.mem.eql(u8, action, "approve")) {
                    result.approved = count;
                } else if (std.mem.eql(u8, action, "rewrite")) {
                    result.rewritten = count;
                } else if (std.mem.eql(u8, action, "warn")) {
                    result.warned = count;
                } else if (std.mem.eql(u8, action, "deny")) {
                    result.denied = count;
                }
            }
            result.total_checks += count;
        }

        return result;
    }

    fn getRuleStatsImpl(ptr: *anyopaque, _: std.mem.Allocator, rule_id: []const u8) anyerror!?RuleStats {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));

        const sql = "SELECT COUNT(*), MAX(timestamp), action FROM checks WHERE rule_id = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqliteQueryFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_text(stmt, 1, rule_id.ptr, @intCast(rule_id.len), SQLITE_STATIC);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const count: u64 = @intCast(c.sqlite3_column_int64(stmt, 0));
            if (count == 0) return null;

            const last_hit = c.sqlite3_column_int64(stmt, 1);
            const action_text = c.sqlite3_column_text(stmt, 2);
            var action: Action = .approve;
            if (action_text) |txt| {
                const a = std.mem.span(txt);
                if (std.mem.eql(u8, a, "rewrite")) action = .rewrite;
                if (std.mem.eql(u8, a, "warn")) action = .warn;
                if (std.mem.eql(u8, a, "deny")) action = .deny;
            }

            return .{
                .rule_id = rule_id,
                .hit_count = count,
                .last_hit = last_hit,
                .action = action,
            };
        }

        return null;
    }

    fn getTopCommandsImpl(ptr: *anyopaque, allocator: std.mem.Allocator, limit: u32) anyerror![]CommandFrequency {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));

        const sql = "SELECT base_command, COUNT(*) as cnt, MAX(timestamp) FROM checks WHERE base_command IS NOT NULL GROUP BY base_command ORDER BY cnt DESC LIMIT ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) {
            return error.SqliteQueryFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        _ = c.sqlite3_bind_int(stmt, 1, @intCast(limit));

        var result = std.ArrayListUnmanaged(CommandFrequency).empty;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const cmd_text = c.sqlite3_column_text(stmt, 0);
            if (cmd_text) |txt| {
                const cmd = try allocator.dupe(u8, std.mem.span(txt));
                try result.append(allocator, .{
                    .base_command = cmd,
                    .count = @intCast(c.sqlite3_column_int64(stmt, 1)),
                    .last_seen = c.sqlite3_column_int64(stmt, 2),
                });
            }
        }

        return try result.toOwnedSlice(allocator);
    }

    fn closeVtableImpl(ptr: *anyopaque) void {
        const self: *SqliteStore = @ptrCast(@alignCast(ptr));
        self.close();
    }

    // -- Background writer --

    fn writeLoop(self: *SqliteStore) void {
        while (!self.shutdown.load(.acquire)) {
            if (self.queue.tryPop()) |entry| {
                self.writeEntry(entry);
            } else {
                std.Thread.sleep(1_000_000); // 1ms idle
            }
        }
        // Drain remaining entries on shutdown
        while (self.queue.tryPop()) |entry| {
            self.writeEntry(entry);
        }
    }

    fn writeEntry(self: *SqliteStore, entry: CheckEntry) void {
        const stmt = self.insert_stmt orelse return;

        _ = c.sqlite3_bind_int64(stmt, 1, entry.timestamp);
        bindOptionalText(stmt, 2, entry.session_id);
        bindText(stmt, 3, entry.tool_name);
        bindOptionalText(stmt, 4, entry.command);
        bindOptionalText(stmt, 5, entry.base_command);
        bindOptionalText(stmt, 6, entry.rule_id);
        bindText(stmt, 7, @tagName(entry.action));
        bindOptionalText(stmt, 8, entry.message);
        bindOptionalText(stmt, 9, entry.rewritten_to);
        _ = c.sqlite3_bind_int64(stmt, 10, @intCast(entry.duration_us));

        _ = c.sqlite3_step(stmt);
        _ = c.sqlite3_reset(stmt);
        _ = c.sqlite3_clear_bindings(stmt);
    }
};

// -- Helpers --

fn execSql(db: ?*c.sqlite3, sql: [*:0]const u8) !void {
    if (c.sqlite3_exec(db, sql, null, null, null) != c.SQLITE_OK) {
        return error.SqliteExecFailed;
    }
}

fn bindText(stmt: ?*c.sqlite3_stmt, col: c_int, text: []const u8) void {
    _ = c.sqlite3_bind_text(stmt, col, text.ptr, @intCast(text.len), SQLITE_STATIC);
}

fn bindOptionalText(stmt: ?*c.sqlite3_stmt, col: c_int, text: ?[]const u8) void {
    if (text) |t| {
        bindText(stmt, col, t);
    } else {
        _ = c.sqlite3_bind_null(stmt, col);
    }
}

/// Simple bounded ring buffer for async message passing.
fn BoundedQueue(comptime T: type, comptime capacity: usize) type {
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn tryPush(self: *Self, item: T) void {
            const tail = self.tail.load(.acquire);
            const next_tail = (tail + 1) % capacity;
            if (next_tail == self.head.load(.acquire)) return; // full, drop
            self.items[tail] = item;
            self.tail.store(next_tail, .release);
        }

        pub fn tryPop(self: *Self) ?T {
            const head = self.head.load(.acquire);
            if (head == self.tail.load(.acquire)) return null; // empty
            const item = self.items[head];
            self.head.store((head + 1) % capacity, .release);
            return item;
        }
    };
}

// -- Tests --

test "SqliteStore init and close with in-memory db" {
    var ss = try SqliteStore.init(":memory:");
    try ss.start();
    ss.close();
}

test "SqliteStore recordCheck and getStats round-trip" {
    var ss = try SqliteStore.init(":memory:");
    try ss.start();
    defer ss.close();
    var s = ss.store();

    s.recordCheck(.{ .timestamp = 1000, .tool_name = "Bash", .action = .approve, .base_command = "ls" });
    s.recordCheck(.{ .timestamp = 2000, .tool_name = "Bash", .action = .rewrite, .rule_id = "test", .base_command = "pytest" });
    s.recordCheck(.{ .timestamp = 3000, .tool_name = "Bash", .action = .deny, .rule_id = "deny", .base_command = "rm" });

    // Wait for background writer to process
    std.Thread.sleep(50_000_000); // 50ms

    const stats = try s.getStats(std.testing.allocator, .{});
    try std.testing.expectEqual(@as(u64, 3), stats.total_checks);
    try std.testing.expectEqual(@as(u64, 1), stats.approved);
    try std.testing.expectEqual(@as(u64, 1), stats.rewritten);
    try std.testing.expectEqual(@as(u64, 1), stats.denied);
}

test "SqliteStore getRuleStats" {
    var ss = try SqliteStore.init(":memory:");
    try ss.start();
    defer ss.close();
    var s = ss.store();

    s.recordCheck(.{ .timestamp = 1000, .tool_name = "Bash", .action = .rewrite, .rule_id = "r1" });
    s.recordCheck(.{ .timestamp = 2000, .tool_name = "Bash", .action = .rewrite, .rule_id = "r1" });

    std.Thread.sleep(50_000_000);

    const stats = (try s.getRuleStats(std.testing.allocator, "r1")).?;
    try std.testing.expectEqual(@as(u64, 2), stats.hit_count);

    const none = try s.getRuleStats(std.testing.allocator, "nonexistent");
    try std.testing.expect(none == null);
}

test "BoundedQueue basic operations" {
    var q = BoundedQueue(u32, 4){};

    q.tryPush(1);
    q.tryPush(2);
    q.tryPush(3);

    try std.testing.expectEqual(@as(?u32, 1), q.tryPop());
    try std.testing.expectEqual(@as(?u32, 2), q.tryPop());
    try std.testing.expectEqual(@as(?u32, 3), q.tryPop());
    try std.testing.expectEqual(@as(?u32, null), q.tryPop());
}

test "BoundedQueue drops when full" {
    var q = BoundedQueue(u32, 3){}; // capacity 3 means 2 usable slots (ring buffer)

    q.tryPush(1);
    q.tryPush(2);
    q.tryPush(3); // should be silently dropped

    try std.testing.expectEqual(@as(?u32, 1), q.tryPop());
    try std.testing.expectEqual(@as(?u32, 2), q.tryPop());
    // Third push was dropped because ring buffer with size 3 holds max 2
    try std.testing.expectEqual(@as(?u32, null), q.tryPop());
}
