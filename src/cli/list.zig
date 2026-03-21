// ABOUTME: Display current veer rules in a formatted table.
// ABOUTME: Loads merged config (project + global) and renders rule summary.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const Table = @import("../display/table.zig").Table;

/// Run the list command. Outputs rules table to writer.
pub fn run(allocator: std.mem.Allocator, rules: []const config_mod.Rule, writer: anytype) !u8 {
    if (rules.len == 0) {
        try writer.print("No rules configured.\n", .{});
        return 0;
    }

    var table = Table{ .headers = &.{ "ID", "Action", "Command/Pattern", "Message" } };
    defer table.deinit(allocator);

    for (rules) |rule| {
        const pattern = describeMatch(rule.match);
        const message = if (rule.message) |m| truncate(m, 40) else "";
        const action_str = @tagName(rule.action);
        try table.addRow(allocator, &.{ rule.id, action_str, pattern, message });
    }

    try table.render(writer);
    try writer.print("\n{d} rule(s)\n", .{rules.len});
    return 0;
}

fn describeMatch(m: config_mod.MatchConfig) []const u8 {
    if (m.command) |cmd| return cmd;
    if (m.command_glob) |g| return g;
    if (m.command_regex) |r| return r;
    if (m.pipeline_contains != null) return "pipeline:...";
    if (m.has_flag) |f| return f;
    if (m.arg_pattern) |p| return p;
    return "(complex)";
}

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

// -- Tests --

test "list with rules renders table" {
    const rules = [_]config_mod.Rule{
        .{ .id = "use-just-test", .name = "Redirect pytest", .action = .rewrite, .rewrite_to = "just test", .message = "Use just test.", .match = .{ .command = "pytest" } },
        .{ .id = "no-curl-bash", .name = "Block curl|bash", .action = .deny, .message = "Don't pipe curl to bash.", .match = .{ .pipeline_contains = &.{ "curl", "bash" } } },
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "use-just-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rewrite") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2 rule(s)") != null);
}

test "list with no rules" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &.{}, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "No rules") != null);
}
