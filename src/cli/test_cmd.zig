// ABOUTME: Test a command against veer rules without crafting hook JSON.
// ABOUTME: Prints which rule matched, the action, and relevant details.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const engine = @import("../engine/engine.zig");
const Rule = @import("../config/rule.zig").Rule;
const Action = @import("../config/rule.zig").Action;
const color = @import("../display/color.zig");

pub const TestOptions = struct {
    command: ?[]const u8 = null,
    config_path: []const u8 = ".veer/config.toml",
};

/// Run the test command. Tests a command string against loaded rules.
pub fn run(allocator: std.mem.Allocator, rules: []const Rule, opts: TestOptions, writer: anytype) !u8 {
    const command = opts.command orelse {
        try writer.print("veer test: command argument required\n", .{});
        try writer.print("Usage: veer test \"<command>\" [--config <path>]\n", .{});
        return 1;
    };

    const result = engine.check(allocator, rules, "Bash", command, null);

    if (result.action) |action| {
        switch (action) {
            .rewrite => {
                try writer.print("REWRITE {s}", .{result.rule_id orelse "?"});
                if (result.rewrite_to) |target| {
                    try writer.print("  {s} -> {s}", .{ command, target });
                }
                try writer.print("\n", .{});
            },
            .reject => {
                try writer.print("REJECT  {s}", .{result.rule_id orelse "?"});
                if (result.message) |msg| {
                    try writer.print("  \"{s}\"", .{msg});
                }
                try writer.print("\n", .{});
            },
        }
    } else {
        try writer.print("ALLOW   (no rule matched)\n", .{});
    }

    return 0;
}

// -- Tests --

test "test command shows REWRITE" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, .{ .command = "pytest tests/" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "REWRITE") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "use-just-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "just test") != null);
}

test "test command shows REJECT" {
    const rules = [_]Rule{.{
        .id = "no-chmod",
        .message = "Avoid world-writable permissions",
        .match = .{ .command = "chmod" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, .{ .command = "chmod 777 server.py" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "REJECT") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "no-chmod") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "world-writable") != null);
}

test "test command shows ALLOW when no match" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, .{ .command = "ls -la" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "ALLOW") != null);
}

test "test command without argument returns error" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &.{}, .{}, stream.writer());

    try std.testing.expectEqual(@as(u8, 1), exit_code);
}
