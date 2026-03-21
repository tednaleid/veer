// ABOUTME: Storage interface for veer check statistics.
// ABOUTME: Vtable-based abstraction -- MemoryStore for tests, SqliteStore for production.

const std = @import("std");

pub const Action = enum {
    approve,
    rewrite,
    reject,
};

pub const CheckEntry = struct {
    timestamp: i64, // unix millis
    session_id: ?[]const u8 = null,
    tool_name: []const u8,
    command: ?[]const u8 = null,
    base_command: ?[]const u8 = null,
    rule_id: ?[]const u8 = null,
    action: Action,
    message: ?[]const u8 = null,
    rewritten_to: ?[]const u8 = null,
    duration_us: u64 = 0,
};

pub const StatsQuery = struct {
    since: ?i64 = null, // unix millis, entries after this time
};

pub const StatsResult = struct {
    total_checks: u64 = 0,
    approved: u64 = 0,
    rewritten: u64 = 0,
    rejected: u64 = 0,
};

pub const RuleStats = struct {
    rule_id: []const u8,
    hit_count: u64,
    last_hit: i64,
    action: Action,
};

pub const CommandFrequency = struct {
    base_command: []const u8,
    count: u64,
    last_seen: i64,
};

/// Storage backend interface. All access to check statistics goes through this.
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
