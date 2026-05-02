// ABOUTME: Display current veer rules in a formatted table.
// ABOUTME: Loads merged config (project + global) and renders rule summary.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const Table = @import("../display/table.zig").Table;

/// Run the list command. Outputs rules table to writer.
/// `sources` is parallel to `rules` when non-null (i.e. when the rules came
/// from `loadMerged`); the rendered table then includes a `Source` column.
/// Pass `null` for explicit single-file loads to keep the table compact.
pub fn run(
    allocator: std.mem.Allocator,
    rules: []const config_mod.Rule,
    sources: ?[]const config_mod.RuleSource,
    writer: anytype,
) !u8 {
    if (rules.len == 0) {
        try writer.print("No rules configured.\n", .{});
        return 0;
    }

    const show_source = sources != null;
    if (show_source) std.debug.assert(sources.?.len == rules.len);

    var table = if (show_source)
        Table{ .headers = &.{ "ID", "Source", "Action", "Command/Pattern", "Message" } }
    else
        Table{ .headers = &.{ "ID", "Action", "Command/Pattern", "Message" } };
    defer table.deinit(allocator);

    for (rules, 0..) |rule, i| {
        const pattern = describeMatch(rule.match);
        const message = if (rule.message) |m| truncate(m, 40) else "";
        const action_str = @tagName(rule.effectiveAction());
        if (show_source) {
            const src_str = @tagName(sources.?[i]);
            try table.addRow(allocator, &.{ rule.id, src_str, action_str, pattern, message });
        } else {
            try table.addRow(allocator, &.{ rule.id, action_str, pattern, message });
        }
    }

    try table.render(writer);
    try writer.print("\n{d} rule(s)\n", .{rules.len});
    return 0;
}

fn describeMatch(m: config_mod.MatchConfig) []const u8 {
    if (m.command) |cmd| return cmd;
    if (m.command_regex) |r| return r;
    if (m.flag) |f| return f;
    if (m.arg) |a| return a;
    if (m.raw_regex) |r| return r;
    if (m.command_any != null) return "(command_any)";
    if (m.command_all != null) return "(command_all)";
    return "(complex)";
}

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

// -- Tests --

test "list with rules renders table" {
    const rules = [_]config_mod.Rule{
        .{ .id = "use-just-test", .rewrite_to = "just test", .message = "Use just test.", .match = .{ .command = "pytest" } },
        .{ .id = "no-curl-bash", .message = "Don't pipe curl to bash.", .match = .{ .command_all = &.{ "curl", "bash" } } },
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, null, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "use-just-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rewrite") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2 rule(s)") != null);
    // Single-file load: no Source column.
    try std.testing.expect(std.mem.indexOf(u8, output, "Source") == null);
}

test "list with no rules" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &.{}, null, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "No rules") != null);
}

test "list with sources renders Source column" {
    const rules = [_]config_mod.Rule{
        .{ .id = "p-rule", .message = "from project", .match = .{ .command = "foo" } },
        .{ .id = "g-rule", .message = "from global", .match = .{ .command = "bar" } },
    };
    const sources = [_]config_mod.RuleSource{ .project, .global };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, &sources, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Source") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "project") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "global") != null);
}
