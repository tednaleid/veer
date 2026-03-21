// ABOUTME: Display usage statistics from the veer stats database.
// ABOUTME: Shows check counts, top rules, and unmatched commands.

const std = @import("std");
const Store = @import("../store/store.zig").Store;
const StatsQuery = @import("../store/store.zig").StatsQuery;
const Table = @import("../display/table.zig").Table;

/// Run the stats command with an already-opened store.
pub fn run(allocator: std.mem.Allocator, store: Store, writer: anytype) !u8 {
    const stats = try store.getStats(allocator, .{});

    if (stats.total_checks == 0) {
        try writer.print("No check data recorded yet.\n", .{});
        return 0;
    }

    try writer.print("Stats:\n\n", .{});
    try writer.print("  Checks: {d} total | {d} approved | {d} rewritten | {d} rejected\n\n", .{
        stats.total_checks, stats.approved, stats.rewritten, stats.rejected,
    });

    // Top commands
    const top_cmds = try store.getTopCommands(allocator, 10);
    defer allocator.free(top_cmds);

    if (top_cmds.len > 0) {
        try writer.print("  Top commands:\n", .{});
        for (top_cmds) |cmd| {
            try writer.print("    {s: <20} {d} occurrences\n", .{ cmd.base_command, cmd.count });
        }
        try writer.print("\n", .{});
    }

    return 0;
}

// -- Tests --

const MemoryStore = @import("../store/memory_store.zig").MemoryStore;

test "stats with data shows counts" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();

    s.recordCheck(.{ .timestamp = 1000, .tool_name = "Bash", .action = .approve, .base_command = "ls" });
    s.recordCheck(.{ .timestamp = 2000, .tool_name = "Bash", .action = .rewrite, .rule_id = "r1", .base_command = "pytest" });
    s.recordCheck(.{ .timestamp = 3000, .tool_name = "Bash", .action = .reject, .rule_id = "r2", .base_command = "rm" });

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, s, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "3 total") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1 approved") != null);
}

test "stats with no data" {
    var ms = MemoryStore.init(std.testing.allocator);
    defer ms.deinit();
    const s = ms.store();

    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, s, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "No check data") != null);
}
