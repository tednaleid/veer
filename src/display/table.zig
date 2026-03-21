// ABOUTME: Column-aligned table rendering for terminal output.
// ABOUTME: Auto-calculates column widths and renders with consistent spacing.

const std = @import("std");

pub const MAX_COLS = 8;

pub const Table = struct {
    headers: []const []const u8,
    rows: std.ArrayListUnmanaged([]const []const u8) = .empty,

    pub fn addRow(self: *Table, allocator: std.mem.Allocator, row: []const []const u8) !void {
        const owned = try allocator.dupe([]const u8, row);
        try self.rows.append(allocator, owned);
    }

    pub fn render(self: Table, writer: anytype) !void {
        const num_cols = self.headers.len;
        if (num_cols == 0) return;

        // Calculate column widths
        var widths: [MAX_COLS]usize = .{0} ** MAX_COLS;
        for (self.headers, 0..) |h, i| {
            if (i < MAX_COLS) widths[i] = h.len;
        }
        for (self.rows.items) |row| {
            for (row, 0..) |cell, i| {
                if (i < MAX_COLS) widths[i] = @max(widths[i], cell.len);
            }
        }

        // Print headers
        for (self.headers, 0..) |h, i| {
            if (i < MAX_COLS) {
                try writer.print("{s}", .{h});
                if (i < num_cols - 1) {
                    const padding = widths[i] - h.len + 2;
                    try writer.writeByteNTimes(' ', padding);
                }
            }
        }
        try writer.writeByte('\n');

        // Print separator
        for (self.headers, 0..) |_, i| {
            if (i < MAX_COLS) {
                try writer.writeByteNTimes('-', widths[i]);
                if (i < num_cols - 1) {
                    try writer.writeAll("  ");
                }
            }
        }
        try writer.writeByte('\n');

        // Print rows
        for (self.rows.items) |row| {
            for (row, 0..) |cell, i| {
                if (i < MAX_COLS) {
                    try writer.print("{s}", .{cell});
                    if (i < num_cols - 1) {
                        const padding = widths[i] - cell.len + 2;
                        try writer.writeByteNTimes(' ', padding);
                    }
                }
            }
            try writer.writeByte('\n');
        }
    }

    pub fn deinit(self: *Table, allocator: std.mem.Allocator) void {
        for (self.rows.items) |row| {
            allocator.free(row);
        }
        self.rows.deinit(allocator);
    }
};

// -- Tests --

test "table renders with aligned columns" {
    const allocator = std.testing.allocator;
    var t = Table{ .headers = &.{ "ID", "Action", "Command" } };
    defer t.deinit(allocator);

    try t.addRow(allocator, &.{ "use-just-test", "rewrite", "pytest" });
    try t.addRow(allocator, &.{ "no-curl-bash", "deny", "pipeline:curl|bash" });

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try t.render(stream.writer());

    const output = stream.getWritten();
    // Verify headers are present
    try std.testing.expect(std.mem.indexOf(u8, output, "ID") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Action") != null);
    // Verify data is present
    try std.testing.expect(std.mem.indexOf(u8, output, "use-just-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rewrite") != null);
}

test "table with no rows renders headers only" {
    var t = Table{ .headers = &.{ "A", "B" } };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try t.render(stream.writer());

    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "A") != null);
}
