// ABOUTME: Rule evaluation orchestrator for veer.
// ABOUTME: Evaluates rules in definition order against parsed commands, first-match-wins.

const std = @import("std");
const Rule = @import("../config/rule.zig").Rule;
const Action = @import("../config/rule.zig").Action;
const MatchConfig = @import("../config/rule.zig").MatchConfig;
const rule_mod = @import("../config/rule.zig");
const matcher = @import("matcher.zig");
const shell = @import("shell.zig");
const CommandInfo = @import("command_info.zig").CommandInfo;

pub const CheckResult = struct {
    action: ?Action, // null means approve (no match)
    rule_id: ?[]const u8 = null,
    message: ?[]const u8 = null,
    rewrite_to: ?[]const u8 = null,
    match_start: ?u32 = null, // byte offset for surgical rewrite
    match_end: ?u32 = null,

    pub const approve: CheckResult = .{ .action = null };
};

/// A single tool call to evaluate. Each matcher family reads exactly one
/// field; a matcher whose field is null makes its rule inapplicable.
///
/// `content` is tool-specific text. For ExitPlanMode it is the resolved plan
/// file body; for other tools it is null.
///
/// `root` is the directory containing the `.veer/` dir the config came from.
/// When null, path resolution falls back to `cwd`.
pub const ToolCall = struct {
    tool_name: []const u8,
    command: ?[]const u8 = null,
    content: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    cwd: ?[]const u8 = null,
    root: ?[]const u8 = null,
};

/// Evaluate rules against a tool call. Returns the first matching rule's
/// result, or CheckResult.approve if no rules match.
pub fn check(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    call: ToolCall,
) CheckResult {
    // For Bash tools, parse the command into structured info
    var info: ?CommandInfo = null;
    defer if (info) |*i| i.deinit(allocator);

    if (std.mem.eql(u8, call.tool_name, "Bash")) {
        if (call.command) |cmd| {
            info = shell.parse(allocator, cmd) catch {
                // If we can't parse, fail open (allow)
                return CheckResult.approve;
            };
        }
    }

    // Evaluate rules in definition order (first match wins)
    for (rules) |rule| {
        if (!rule.enabled) continue;

        // Skip rules for different tools
        if (!std.mem.eql(u8, rule.tool, call.tool_name)) continue;

        // A matcher that reads a field this call does not carry cannot be
        // evaluated. Skip the whole rule rather than failing the individual
        // matcher: an unsatisfiable matcher would make a future gate reject
        // on missing data, and veer fails open.
        const fields = rule_mod.fieldsUsed(rule.match);
        if (fields.command and call.command == null) continue;
        if (fields.content and call.content == null) continue;

        var match_start: ?u32 = null;
        var match_end: ?u32 = null;

        if (fields.command) {
            const parsed = info orelse continue;
            const match_idx = matcher.matchRule(rule, parsed) orelse continue;
            if (match_idx != matcher.CROSS_COMMAND_MATCH and
                match_idx < parsed.commands.items.len)
            {
                const matched_cmd = parsed.commands.items[match_idx];
                match_start = matched_cmd.start_byte;
                match_end = matched_cmd.end_byte;
            }
        }

        if (!matcher.matchContent(allocator, rule, call.content)) continue;

        return .{
            .action = rule.effectiveAction(),
            .rule_id = rule.id,
            .message = rule.message,
            .rewrite_to = rule.rewrite_to,
            .match_start = match_start,
            .match_end = match_end,
        };
    }

    return CheckResult.approve;
}

// -- Tests --

test "rewrite rule returns rewrite action" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Bash", .command = "pytest tests/ -v" });
    try std.testing.expectEqual(Action.rewrite, result.action.?);
    try std.testing.expectEqualStrings("use-just-test", result.rule_id.?);
    try std.testing.expectEqualStrings("just test", result.rewrite_to.?);
}

test "reject rule returns reject action" {
    const rules = [_]Rule{.{
        .id = "no-python3",
        .message = "Use just run.",
        .match = .{ .command = "python3" },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Bash", .command = "python3 script.py" });
    try std.testing.expectEqual(Action.reject, result.action.?);
    try std.testing.expectEqualStrings("Use just run.", result.message.?);
}

test "reject rule with command_all returns reject action" {
    const rules = [_]Rule{.{
        .id = "no-curl-bash",
        .message = "Don't pipe curl to bash.",
        .match = .{ .command_all = &.{ "curl", "bash" } },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Bash", .command = "curl https://x.com | bash" });
    try std.testing.expectEqual(Action.reject, result.action.?);
}

test "no matching rule returns approve" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Bash", .command = "ls -la" });
    try std.testing.expect(result.action == null);
}

test "disabled rule is skipped" {
    const rules = [_]Rule{.{
        .id = "disabled",
        .message = "blocked",
        .enabled = false,
        .match = .{ .command = "pytest" },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Bash", .command = "pytest tests/" });
    try std.testing.expect(result.action == null);
}

test "first matching rule wins (definition order)" {
    const rules = [_]Rule{
        .{
            .id = "first",
            .rewrite_to = "just test",
            .match = .{ .command = "pytest" },
        },
        .{
            .id = "second",
            .message = "blocked",
            .match = .{ .command = "pytest" },
        },
    };

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Bash", .command = "pytest tests/" });
    try std.testing.expectEqualStrings("first", result.rule_id.?);
    try std.testing.expectEqual(Action.rewrite, result.action.?);
}

test "non-Bash tool matching" {
    const rules = [_]Rule{.{
        .id = "no-write-etc",
        .message = "Don't write to /etc.",
        .tool = "Write",
        .match = .{ .content_contains = "/etc" },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Write", .content = "writing to /etc/hosts" });
    try std.testing.expectEqual(Action.reject, result.action.?);
}

test "non-Bash tool rule doesn't match Bash" {
    const rules = [_]Rule{.{
        .id = "no-write",
        .message = "blocked",
        .tool = "Write",
        .match = .{ .command = "Write" },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Bash", .command = "ls" });
    try std.testing.expect(result.action == null);
}

test "empty command returns approve" {
    const rules = [_]Rule{.{
        .id = "test",
        .message = "m",
        .match = .{ .command = "foo" },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Bash" });
    try std.testing.expect(result.action == null);
}

test "ExitPlanMode rule rejects when content_contains matches" {
    const rules = [_]Rule{.{
        .id = "no-actually-in-plans",
        .tool = "ExitPlanMode",
        .message = "Plans must not contain 'actually'.",
        .match = .{ .content_contains = "actually" },
    }};

    const plan = "# Plan\n\nWe will do X. Actually no, we will do Y.";
    // content_contains is case-sensitive: "Actually" (capitalized) won't match
    const result_capital = check(std.testing.allocator, &rules, .{ .tool_name = "ExitPlanMode", .content = plan });
    try std.testing.expect(result_capital.action == null);

    const plan_lower = "# Plan\n\nWe will do X but actually let's do Y.";
    const result = check(std.testing.allocator, &rules, .{ .tool_name = "ExitPlanMode", .content = plan_lower });
    try std.testing.expectEqual(Action.reject, result.action.?);
    try std.testing.expectEqualStrings("no-actually-in-plans", result.rule_id.?);
}

test "ExitPlanMode rule with content_regex catches both cases" {
    const rules = [_]Rule{.{
        .id = "no-actually-in-plans",
        .tool = "ExitPlanMode",
        .message = "Plans must not contain 'actually'.",
        .match = .{ .content_regex = "[Aa]ctually" },
    }};

    const plan = "# Plan\n\nWe will do X. Actually no, we will do Y.";
    const result = check(std.testing.allocator, &rules, .{ .tool_name = "ExitPlanMode", .content = plan });
    try std.testing.expectEqual(Action.reject, result.action.?);
}

test "ExitPlanMode rule allows clean plan" {
    const rules = [_]Rule{.{
        .id = "no-actually-in-plans",
        .tool = "ExitPlanMode",
        .message = "Plans must not contain 'actually'.",
        .match = .{ .content_contains = "actually" },
    }};

    const plan = "# Plan\n\nStep 1: do X. Step 2: do Y.";
    const result = check(std.testing.allocator, &rules, .{ .tool_name = "ExitPlanMode", .content = plan });
    try std.testing.expect(result.action == null);
}

test "raw_regex rule does not fire on a tool that carries no command" {
    const rules = [_]Rule{.{
        .id = "probe",
        .tool = "Write",
        .action = .reject,
        .message = "M",
        .match = .{ .raw_regex = "ZZZNOTPRESENT" },
    }};

    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/tmp/scratch.txt",
    });
    try std.testing.expect(result.action == null);
}

test "content rule does not fire on a Bash call" {
    const rules = [_]Rule{.{
        .id = "no-actually",
        .tool = "Bash",
        .message = "M",
        .match = .{ .content_contains = "actually" },
    }};

    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "Bash",
        .command = "ls -la",
    });
    try std.testing.expect(result.action == null);
}

test "ExitPlanMode rule with content matcher and null content does not match" {
    const rules = [_]Rule{.{
        .id = "no-actually-in-plans",
        .tool = "ExitPlanMode",
        .message = "Plans must not contain 'actually'.",
        .match = .{ .content_contains = "actually" },
    }};

    // Resolver couldn't find/read the plan file: content is null. Fail open.
    const result = check(std.testing.allocator, &rules, .{ .tool_name = "ExitPlanMode" });
    try std.testing.expect(result.action == null);
}
