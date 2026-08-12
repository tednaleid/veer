// ABOUTME: Rule evaluation orchestrator for veer.
// ABOUTME: Evaluates rules in definition order against parsed commands, first-match-wins.

const std = @import("std");
const Rule = @import("../config/rule.zig").Rule;
const Action = @import("../config/rule.zig").Action;
const MatchConfig = @import("../config/rule.zig").MatchConfig;
const rule_mod = @import("../config/rule.zig");
const matcher = @import("matcher.zig");
const shell = @import("shell.zig");
const path_mod = @import("path.zig");
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

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved: ?path_mod.Resolved = if (call.file_path) |fp|
        path_mod.resolve(fp, call.cwd, call.root, &path_buf)
    else
        null;
    const home = std.posix.getenv("HOME");

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
        if (fields.path and resolved == null) continue;

        var matched = true;
        var match_start: ?u32 = null;
        var match_end: ?u32 = null;

        if (fields.command) {
            const parsed = info orelse continue;
            if (matcher.matchRule(rule, parsed)) |match_idx| {
                if (match_idx != matcher.CROSS_COMMAND_MATCH and
                    match_idx < parsed.commands.items.len)
                {
                    const matched_cmd = parsed.commands.items[match_idx];
                    match_start = matched_cmd.start_byte;
                    match_end = matched_cmd.end_byte;
                }
            } else {
                matched = false;
            }
        }

        if (matched and fields.path) {
            matched = matcher.matchPathMatchers(rule, resolved.?, home);
        }

        if (matched) {
            matched = matcher.matchContent(allocator, rule, call.content);
        }

        const action = rule.effectiveAction();
        if (action == .allow) {
            // A gate: pass means fall through, fail means reject.
            if (matched) continue;
            return .{
                .action = .reject,
                .rule_id = rule.id,
                .message = rule.message,
            };
        }

        if (!matched) continue;

        return .{
            .action = action,
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

test "non-Bash tool rule doesn't match Bash" {
    const rules = [_]Rule{.{
        .id = "no-plan-todos",
        .message = "blocked",
        .tool = "ExitPlanMode",
        .match = .{ .content_contains = "TODO" },
    }};

    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "Bash",
        .command = "ls",
    });
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

test "path_any rejects a Write outside the allowed tree" {
    const rules = [_]Rule{.{
        .id = "no-src-writes",
        .tool = "Write",
        .message = "Generated. Edit the template.",
        .match = .{ .path_any = &.{ "**/*_pb2.py", "**/*.gen.ts" } },
    }};

    const hit = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/api/schema_pb2.py",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, hit.action.?);

    const miss = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/api/main.py",
        .root = "/p",
    });
    try std.testing.expect(miss.action == null);
}

test "a path rule is skipped when the call carries no path" {
    const rules = [_]Rule{.{
        .id = "no-src-writes",
        .tool = "Write",
        .message = "M",
        .match = .{ .path_any = &.{"**"} },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Write" });
    try std.testing.expect(result.action == null);
}

test "allow gate falls through when the path is in the allowlist" {
    const rules = [_]Rule{
        .{
            .id = "worktree-only-writes",
            .action = .allow,
            .tool = "Write",
            .message = "Work in a worktree.",
            .match = .{ .path_any = &.{".claude/worktrees/**"} },
        },
        .{
            .id = "no-gen-edits",
            .tool = "Write",
            .message = "Generated.",
            .match = .{ .path_any = &.{"**/*.gen.ts"} },
        },
    };

    // In the allowlist, and not generated: falls through both, allowed.
    const ok = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/.claude/worktrees/a/src/App.vue",
        .root = "/p",
    });
    try std.testing.expect(ok.action == null);

    // In the allowlist, but generated: gate passes, next rule rejects.
    const gen = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/.claude/worktrees/a/src/api.gen.ts",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, gen.action.?);
    try std.testing.expectEqualStrings("no-gen-edits", gen.rule_id.?);
}

test "allow gate rejects what is not in the allowlist" {
    const rules = [_]Rule{.{
        .id = "worktree-only-writes",
        .action = .allow,
        .tool = "Write",
        .message = "Work in a worktree.",
        .match = .{ .path_any = &.{".claude/worktrees/**"} },
    }};

    const result = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/api/main.py",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, result.action.?);
    try std.testing.expectEqualStrings("Work in a worktree.", result.message.?);
    try std.testing.expectEqualStrings("worktree-only-writes", result.rule_id.?);
}

test "a gate whose field is null does not apply" {
    const rules = [_]Rule{.{
        .id = "worktree-only-writes",
        .action = .allow,
        .tool = "Write",
        .message = "Work in a worktree.",
        .match = .{ .path_any = &.{".claude/worktrees/**"} },
    }};

    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Write" });
    try std.testing.expect(result.action == null);
}

test "two gates on the same tool intersect" {
    const rules = [_]Rule{
        .{
            .id = "src-only",
            .action = .allow,
            .tool = "Write",
            .message = "Writes belong under src.",
            .match = .{ .path_any = &.{"src/**"} },
        },
        .{
            .id = "vue-only",
            .action = .allow,
            .tool = "Write",
            .message = "Writes must be .vue files.",
            .match = .{ .path_any = &.{"**/*.vue"} },
        },
    };

    // Satisfies both.
    const both = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/src/App.vue",
        .root = "/p",
    });
    try std.testing.expect(both.action == null);

    // Satisfies the first only: the second gate rejects.
    const one = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/src/main.ts",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, one.action.?);
    try std.testing.expectEqualStrings("vue-only", one.rule_id.?);
}

test "stay-in-repo gate rejects a write outside the root" {
    const rules = [_]Rule{.{
        .id = "stay-in-repo",
        .action = .allow,
        .tool = "Write",
        .message = "Stay inside the project.",
        .match = .{ .path_any = &.{"*"} },
    }};

    const outside = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/tmp/scratch.txt",
        .root = "/p",
    });
    try std.testing.expectEqual(Action.reject, outside.action.?);

    const inside = check(std.testing.allocator, &rules, .{
        .tool_name = "Write",
        .file_path = "/p/apps/web/main.ts",
        .root = "/p",
    });
    try std.testing.expect(inside.action == null);
}
