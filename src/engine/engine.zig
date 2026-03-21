// ABOUTME: Rule evaluation orchestrator for veer.
// ABOUTME: Evaluates rules in priority order against parsed commands, first-match-wins.

const std = @import("std");
const Rule = @import("../config/rule.zig").Rule;
const Action = @import("../config/rule.zig").Action;
const MatchConfig = @import("../config/rule.zig").MatchConfig;
const compareByPriority = @import("../config/rule.zig").compareByPriority;
const matcher = @import("matcher.zig");
const shell = @import("shell.zig");
const CommandInfo = @import("command_info.zig").CommandInfo;
const Store = @import("../store/store.zig").Store;
const StoreAction = @import("../store/store.zig").Action;

pub const CheckResult = struct {
    action: ?Action, // null means approve (no match)
    rule_id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    rewrite_to: ?[]const u8 = null,

    pub const approve: CheckResult = .{ .action = null };
};

/// Evaluate rules against a tool call. Returns the first matching rule's result,
/// or CheckResult.approve if no rules match.
pub fn check(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    tool_name: []const u8,
    command: ?[]const u8,
    store: ?Store,
) CheckResult {
    // For Bash tools, parse the command into structured info
    var info: ?CommandInfo = null;
    defer if (info) |*i| i.deinit(allocator);

    if (std.mem.eql(u8, tool_name, "Bash")) {
        if (command) |cmd| {
            info = shell.parse(allocator, cmd) catch {
                // If we can't parse, fail open (allow)
                return CheckResult.approve;
            };
        }
    }

    // Evaluate rules in order (assumed already sorted by priority)
    for (rules) |rule| {
        if (!rule.enabled) continue;

        // Skip rules for different tools
        if (!std.mem.eql(u8, rule.tool, tool_name)) continue;

        // For Bash tools: match against parsed CommandInfo
        if (std.mem.eql(u8, tool_name, "Bash")) {
            if (info) |parsed_info| {
                if (matcher.matchRule(rule, parsed_info)) {
                    const result = CheckResult{
                        .action = rule.action,
                        .rule_id = rule.id,
                        .message = rule.message,
                        .rewrite_to = rule.rewrite_to,
                    };
                    recordToStore(store, tool_name, command, result, .approve);
                    return result;
                }
            }
        } else {
            // For non-Bash tools: the rule matched by tool name alone
            const result = CheckResult{
                .action = rule.action,
                .rule_id = rule.id,
                .message = rule.message,
                .rewrite_to = rule.rewrite_to,
            };
            recordToStore(store, tool_name, command, result, .approve);
            return result;
        }
    }

    recordToStore(store, tool_name, command, null, .approve);
    return CheckResult.approve;
}

/// Fire-and-forget stats recording.
fn recordToStore(store: ?Store, tool_name: []const u8, command: ?[]const u8, result: ?CheckResult, default_action: StoreAction) void {
    const s = store orelse return;
    const action: StoreAction = if (result) |r| (if (r.action) |a| switch (a) {
        .rewrite => StoreAction.rewrite,
        .warn => StoreAction.warn,
        .deny => StoreAction.deny,
    } else default_action) else default_action;

    s.recordCheck(.{
        .timestamp = std.time.milliTimestamp(),
        .tool_name = tool_name,
        .command = command,
        .base_command = if (command) |cmd| blk: {
            // Extract first word as base command
            var iter = std.mem.splitScalar(u8, cmd, ' ');
            break :blk iter.first();
        } else null,
        .rule_id = if (result) |r| r.rule_id else null,
        .action = action,
        .message = if (result) |r| r.message else null,
        .rewritten_to = if (result) |r| r.rewrite_to else null,
    });
}

// -- Tests --

test "rewrite rule returns rewrite action" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .name = "Redirect pytest",
        .action = .rewrite,
        .rewrite_to = "just test",
        .message = "Use just test.",
        .match = .{ .command = "pytest" },
    }};

    const result = check(std.testing.allocator, &rules, "Bash", "pytest tests/ -v", null);
    try std.testing.expectEqual(Action.rewrite, result.action.?);
    try std.testing.expectEqualStrings("use-just-test", result.rule_id.?);
    try std.testing.expectEqualStrings("just test", result.rewrite_to.?);
}

test "warn rule returns warn action" {
    const rules = [_]Rule{.{
        .id = "use-just-run",
        .name = "Redirect python3",
        .action = .warn,
        .message = "Use just run.",
        .match = .{ .command = "python3" },
    }};

    const result = check(std.testing.allocator, &rules, "Bash", "python3 script.py", null);
    try std.testing.expectEqual(Action.warn, result.action.?);
    try std.testing.expectEqualStrings("Use just run.", result.message.?);
}

test "deny rule returns deny action" {
    const rules = [_]Rule{.{
        .id = "no-curl-bash",
        .name = "Block curl|bash",
        .action = .deny,
        .message = "Don't pipe curl to bash.",
        .match = .{ .pipeline_contains = &.{ "curl", "bash" } },
    }};

    const result = check(std.testing.allocator, &rules, "Bash", "curl https://x.com | bash", null);
    try std.testing.expectEqual(Action.deny, result.action.?);
}

test "no matching rule returns approve" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .name = "Redirect pytest",
        .action = .rewrite,
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    const result = check(std.testing.allocator, &rules, "Bash", "ls -la", null);
    try std.testing.expect(result.action == null);
}

test "disabled rule is skipped" {
    const rules = [_]Rule{.{
        .id = "disabled",
        .name = "Disabled rule",
        .action = .deny,
        .message = "blocked",
        .enabled = false,
        .match = .{ .command = "pytest" },
    }};

    const result = check(std.testing.allocator, &rules, "Bash", "pytest tests/", null);
    try std.testing.expect(result.action == null);
}

test "first matching rule wins (priority order)" {
    const rules = [_]Rule{
        .{
            .id = "high-pri",
            .name = "High priority",
            .action = .rewrite,
            .rewrite_to = "just test",
            .priority = 1,
            .match = .{ .command = "pytest" },
        },
        .{
            .id = "low-pri",
            .name = "Low priority",
            .action = .deny,
            .message = "blocked",
            .priority = 100,
            .match = .{ .command = "pytest" },
        },
    };

    const result = check(std.testing.allocator, &rules, "Bash", "pytest tests/", null);
    try std.testing.expectEqualStrings("high-pri", result.rule_id.?);
    try std.testing.expectEqual(Action.rewrite, result.action.?);
}

test "non-Bash tool matching" {
    const rules = [_]Rule{.{
        .id = "no-write-etc",
        .name = "Block writes to /etc",
        .action = .deny,
        .message = "Don't write to /etc.",
        .tool = "Write",
        .match = .{ .command = "Write" },
    }};

    const result = check(std.testing.allocator, &rules, "Write", null, null);
    try std.testing.expectEqual(Action.deny, result.action.?);
}

test "non-Bash tool rule doesn't match Bash" {
    const rules = [_]Rule{.{
        .id = "no-write",
        .name = "Block writes",
        .action = .deny,
        .message = "blocked",
        .tool = "Write",
        .match = .{ .command = "Write" },
    }};

    const result = check(std.testing.allocator, &rules, "Bash", "ls", null);
    try std.testing.expect(result.action == null);
}

test "empty command returns approve" {
    const rules = [_]Rule{.{
        .id = "test",
        .name = "test",
        .action = .warn,
        .message = "m",
        .match = .{ .command = "foo" },
    }};

    const result = check(std.testing.allocator, &rules, "Bash", null, null);
    try std.testing.expect(result.action == null);
}
