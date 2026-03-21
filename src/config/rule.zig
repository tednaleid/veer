// ABOUTME: Rule data structures for veer config.
// ABOUTME: Defines Rule, MatchConfig, Action and validation logic.

const std = @import("std");

pub const Action = enum {
    rewrite,
    warn,
    deny,
};

pub const AstMatch = struct {
    has_node: ?[]const u8 = null,
    min_depth: ?i64 = null,
    min_count: ?i64 = null,
};

pub const MatchConfig = struct {
    command: ?[]const u8 = null,
    command_glob: ?[]const u8 = null,
    command_regex: ?[]const u8 = null,
    pipeline_contains: ?[]const []const u8 = null,
    has_flag: ?[]const u8 = null,
    arg_pattern: ?[]const u8 = null,
    ast: ?AstMatch = null,
};

pub const Rule = struct {
    id: []const u8,
    name: []const u8,
    action: Action,
    priority: i64 = 100,
    enabled: bool = true,
    tool: []const u8 = "Bash",
    message: ?[]const u8 = null,
    rewrite_to: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    match: MatchConfig = .{},
};

pub const ValidationError = error{
    MissingRequiredField,
    DuplicateRuleId,
    RewriteRequiresTarget,
    WarnDenyRequiresMessage,
    EmptyMatch,
};

/// Validate a slice of rules. Returns the first validation error found.
pub fn validate(rules: []const Rule) ValidationError!void {
    for (rules, 0..) |rule, i| {
        if (rule.id.len == 0 or rule.name.len == 0) {
            return ValidationError.MissingRequiredField;
        }

        // Check for duplicate IDs
        for (rules[0..i]) |prev| {
            if (std.mem.eql(u8, rule.id, prev.id)) {
                return ValidationError.DuplicateRuleId;
            }
        }

        if (rule.action == .rewrite and rule.rewrite_to == null) {
            return ValidationError.RewriteRequiresTarget;
        }

        if ((rule.action == .warn or rule.action == .deny) and rule.message == null) {
            return ValidationError.WarnDenyRequiresMessage;
        }

        if (!hasAnyMatch(rule.match)) {
            return ValidationError.EmptyMatch;
        }
    }
}

fn hasAnyMatch(m: MatchConfig) bool {
    return m.command != null or
        m.command_glob != null or
        m.command_regex != null or
        m.pipeline_contains != null or
        m.has_flag != null or
        m.arg_pattern != null or
        m.ast != null;
}

/// Compare rules by priority (lower first) for sorting.
pub fn compareByPriority(_: void, a: Rule, b: Rule) bool {
    return a.priority < b.priority;
}

// -- Tests --

test "valid rewrite rule passes validation" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .name = "Redirect pytest",
        .action = .rewrite,
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};
    try validate(&rules);
}

test "valid warn rule passes validation" {
    const rules = [_]Rule{.{
        .id = "use-just-run",
        .name = "Redirect python3",
        .action = .warn,
        .message = "Use just run instead.",
        .match = .{ .command = "python3" },
    }};
    try validate(&rules);
}

test "valid deny rule passes validation" {
    const rules = [_]Rule{.{
        .id = "no-curl-bash",
        .name = "Block curl pipe bash",
        .action = .deny,
        .message = "Don't pipe curl to bash.",
        .match = .{ .pipeline_contains = &.{ "curl", "bash" } },
    }};
    try validate(&rules);
}

test "empty id fails validation" {
    const rules = [_]Rule{.{
        .id = "",
        .name = "Bad rule",
        .action = .warn,
        .message = "msg",
        .match = .{ .command = "foo" },
    }};
    try std.testing.expectError(ValidationError.MissingRequiredField, validate(&rules));
}

test "empty name fails validation" {
    const rules = [_]Rule{.{
        .id = "good-id",
        .name = "",
        .action = .warn,
        .message = "msg",
        .match = .{ .command = "foo" },
    }};
    try std.testing.expectError(ValidationError.MissingRequiredField, validate(&rules));
}

test "duplicate IDs fail validation" {
    const rules = [_]Rule{
        .{
            .id = "same-id",
            .name = "Rule 1",
            .action = .warn,
            .message = "msg",
            .match = .{ .command = "foo" },
        },
        .{
            .id = "same-id",
            .name = "Rule 2",
            .action = .warn,
            .message = "msg",
            .match = .{ .command = "bar" },
        },
    };
    try std.testing.expectError(ValidationError.DuplicateRuleId, validate(&rules));
}

test "rewrite without rewrite_to fails" {
    const rules = [_]Rule{.{
        .id = "bad-rewrite",
        .name = "Missing target",
        .action = .rewrite,
        .match = .{ .command = "foo" },
    }};
    try std.testing.expectError(ValidationError.RewriteRequiresTarget, validate(&rules));
}

test "warn without message fails" {
    const rules = [_]Rule{.{
        .id = "bad-warn",
        .name = "Missing message",
        .action = .warn,
        .match = .{ .command = "foo" },
    }};
    try std.testing.expectError(ValidationError.WarnDenyRequiresMessage, validate(&rules));
}

test "empty match fails" {
    const rules = [_]Rule{.{
        .id = "no-match",
        .name = "No match fields",
        .action = .warn,
        .message = "msg",
    }};
    try std.testing.expectError(ValidationError.EmptyMatch, validate(&rules));
}

test "compareByPriority sorts lower first" {
    var rules = [_]Rule{
        .{ .id = "b", .name = "B", .action = .warn, .message = "m", .priority = 100, .match = .{ .command = "b" } },
        .{ .id = "a", .name = "A", .action = .warn, .message = "m", .priority = 1, .match = .{ .command = "a" } },
        .{ .id = "c", .name = "C", .action = .warn, .message = "m", .priority = 50, .match = .{ .command = "c" } },
    };
    std.mem.sort(Rule, &rules, {}, compareByPriority);
    try std.testing.expectEqualStrings("a", rules[0].id);
    try std.testing.expectEqualStrings("c", rules[1].id);
    try std.testing.expectEqualStrings("b", rules[2].id);
}
