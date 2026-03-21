// ABOUTME: In-memory Store implementation for tests.
// ABOUTME: Stores entries in an ArrayListUnmanaged, queries iterate the list.

const std = @import("std");
const store_mod = @import("store.zig");
const Store = store_mod.Store;
const CheckEntry = store_mod.CheckEntry;
const StatsQuery = store_mod.StatsQuery;
const StatsResult = store_mod.StatsResult;
const RuleStats = store_mod.RuleStats;
const CommandFrequency = store_mod.CommandFrequency;
const Action = store_mod.Action;

pub const MemoryStore = struct {
    entries: std.ArrayListUnmanaged(CheckEntry) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *MemoryStore) void {
        self.entries.deinit(self.allocator);
    }

    /// Return a Store interface backed by this MemoryStore.
    pub fn store(self: *MemoryStore) Store {
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
        .close = closeImpl,
    };

    fn recordCheckImpl(ptr: *anyopaque, entry: CheckEntry) void {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        self.entries.append(self.allocator, entry) catch {};
    }

    fn getStatsImpl(ptr: *anyopaque, _: std.mem.Allocator, opts: StatsQuery) anyerror!StatsResult {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        var result = StatsResult{};

        for (self.entries.items) |entry| {
            if (opts.since) |since| {
                if (entry.timestamp < since) continue;
            }
            result.total_checks += 1;
            switch (entry.action) {
                .approve => result.approved += 1,
                .rewrite => result.rewritten += 1,
                .warn => result.warned += 1,
                .deny => result.denied += 1,
            }
        }
        return result;
    }

    fn getRuleStatsImpl(ptr: *anyopaque, _: std.mem.Allocator, rule_id: []const u8) anyerror!?RuleStats {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));
        var hit_count: u64 = 0;
        var last_hit: i64 = 0;
        var action: Action = .approve;

        for (self.entries.items) |entry| {
            if (entry.rule_id) |rid| {
                if (std.mem.eql(u8, rid, rule_id)) {
                    hit_count += 1;
                    if (entry.timestamp > last_hit) last_hit = entry.timestamp;
                    action = entry.action;
                }
            }
        }

        if (hit_count == 0) return null;
        return .{
            .rule_id = rule_id,
            .hit_count = hit_count,
            .last_hit = last_hit,
            .action = action,
        };
    }

    fn getTopCommandsImpl(ptr: *anyopaque, allocator: std.mem.Allocator, limit: u32) anyerror![]CommandFrequency {
        const self: *MemoryStore = @ptrCast(@alignCast(ptr));

        // Count command frequencies
        const CountEntry = struct { count: u64, last_seen: i64 };
        var counts = std.StringHashMap(CountEntry).init(allocator);
        defer counts.deinit();

        for (self.entries.items) |entry| {
            if (entry.base_command) |cmd| {
                const gop = try counts.getOrPut(cmd);
                if (gop.found_existing) {
                    gop.value_ptr.count += 1;
                    gop.value_ptr.last_seen = @max(gop.value_ptr.last_seen, entry.timestamp);
                } else {
                    gop.value_ptr.* = .{ .count = 1, .last_seen = entry.timestamp };
                }
            }
        }

        // Collect into slice
        var result = std.ArrayListUnmanaged(CommandFrequency).empty;
        var iter = counts.iterator();
        while (iter.next()) |kv| {
            try result.append(allocator, .{
                .base_command = kv.key_ptr.*,
                .count = kv.value_ptr.count,
                .last_seen = kv.value_ptr.last_seen,
            });
        }

        // Sort by count descending
        std.mem.sort(CommandFrequency, result.items, {}, struct {
            fn cmp(_: void, a: CommandFrequency, b: CommandFrequency) bool {
                return a.count > b.count;
            }
        }.cmp);

        // Trim to limit
        if (result.items.len > limit) {
            result.items.len = limit;
        }

        return try result.toOwnedSlice(allocator);
    }

    fn closeImpl(_: *anyopaque) void {
        // No-op for memory store
    }
};

// -- Tests --

test "recordCheck appends entry" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.store();

    s.recordCheck(.{ .timestamp = 1000, .tool_name = "Bash", .action = .approve });
    s.recordCheck(.{ .timestamp = 2000, .tool_name = "Bash", .action = .warn });

    try std.testing.expectEqual(@as(usize, 2), ms.entries.items.len);
}

test "getStats returns correct counts" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.store();

    s.recordCheck(.{ .timestamp = 1000, .tool_name = "Bash", .action = .approve });
    s.recordCheck(.{ .timestamp = 2000, .tool_name = "Bash", .action = .rewrite });
    s.recordCheck(.{ .timestamp = 3000, .tool_name = "Bash", .action = .warn });
    s.recordCheck(.{ .timestamp = 4000, .tool_name = "Bash", .action = .deny });
    s.recordCheck(.{ .timestamp = 5000, .tool_name = "Bash", .action = .approve });

    const stats = try s.getStats(std.testing.allocator, .{});
    try std.testing.expectEqual(@as(u64, 5), stats.total_checks);
    try std.testing.expectEqual(@as(u64, 2), stats.approved);
    try std.testing.expectEqual(@as(u64, 1), stats.rewritten);
    try std.testing.expectEqual(@as(u64, 1), stats.warned);
    try std.testing.expectEqual(@as(u64, 1), stats.denied);
}

test "getStats with since filter" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.store();

    s.recordCheck(.{ .timestamp = 1000, .tool_name = "Bash", .action = .approve });
    s.recordCheck(.{ .timestamp = 5000, .tool_name = "Bash", .action = .warn });

    const stats = try s.getStats(std.testing.allocator, .{ .since = 3000 });
    try std.testing.expectEqual(@as(u64, 1), stats.total_checks);
    try std.testing.expectEqual(@as(u64, 1), stats.warned);
}

test "getRuleStats returns stats for known rule" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.store();

    s.recordCheck(.{ .timestamp = 1000, .tool_name = "Bash", .action = .rewrite, .rule_id = "use-just-test" });
    s.recordCheck(.{ .timestamp = 2000, .tool_name = "Bash", .action = .rewrite, .rule_id = "use-just-test" });
    s.recordCheck(.{ .timestamp = 3000, .tool_name = "Bash", .action = .warn, .rule_id = "other-rule" });

    const stats = (try s.getRuleStats(std.testing.allocator, "use-just-test")).?;
    try std.testing.expectEqual(@as(u64, 2), stats.hit_count);
    try std.testing.expectEqual(@as(i64, 2000), stats.last_hit);
}

test "getRuleStats returns null for unknown rule" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.store();

    const stats = try s.getRuleStats(std.testing.allocator, "nonexistent");
    try std.testing.expect(stats == null);
}

test "getTopCommands returns ordered by frequency" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    var s = ms.store();

    s.recordCheck(.{ .timestamp = 1000, .tool_name = "Bash", .action = .approve, .base_command = "ls" });
    s.recordCheck(.{ .timestamp = 2000, .tool_name = "Bash", .action = .approve, .base_command = "grep" });
    s.recordCheck(.{ .timestamp = 3000, .tool_name = "Bash", .action = .approve, .base_command = "ls" });
    s.recordCheck(.{ .timestamp = 4000, .tool_name = "Bash", .action = .approve, .base_command = "ls" });
    s.recordCheck(.{ .timestamp = 5000, .tool_name = "Bash", .action = .approve, .base_command = "grep" });

    const cmds = try s.getTopCommands(std.testing.allocator, 10);
    defer std.testing.allocator.free(cmds);

    try std.testing.expectEqual(@as(usize, 2), cmds.len);
    try std.testing.expectEqualStrings("ls", cmds[0].base_command);
    try std.testing.expectEqual(@as(u64, 3), cmds[0].count);
    try std.testing.expectEqualStrings("grep", cmds[1].base_command);
    try std.testing.expectEqual(@as(u64, 2), cmds[1].count);
}
