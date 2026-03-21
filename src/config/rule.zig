// ABOUTME: Rule data structures for veer config.
// ABOUTME: Defines Rule, MatchConfig, Action and validation logic.

const std = @import("std");

pub const Action = enum {
    rewrite,
    reject,
};

pub const AstMatch = struct {
    has_node: ?[]const u8 = null,
    min_depth: ?i64 = null,
    min_count: ?i64 = null,
};

pub const MatchConfig = struct {
    // Command name matching (per-command, glob-aware)
    command: ?[]const u8 = null,
    command_any: ?[]const []const u8 = null,
    command_regex: ?[]const u8 = null,

    // Command presence (cross-command, glob-aware)
    command_all: ?[]const []const u8 = null,

    // Flag matching (per-command, no dash prefix, smart combined flag handling)
    flag: ?[]const u8 = null,
    flag_any: ?[]const []const u8 = null,
    flag_all: ?[]const []const u8 = null,

    // Arg matching (per-command, positional args only, glob-aware)
    arg: ?[]const u8 = null,
    arg_any: ?[]const []const u8 = null,
    arg_all: ?[]const []const u8 = null,
    arg_regex: ?[]const u8 = null,

    // Whole-input matching (before parsing)
    raw_regex: ?[]const u8 = null,

    // AST structural matching
    ast: ?AstMatch = null,
};

pub const Rule = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    action: ?Action = null,
    enabled: bool = true,
    tool: []const u8 = "Bash",
    message: ?[]const u8 = null,
    rewrite_to: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    match: MatchConfig = .{},

    /// Returns the effective action: explicit if set, otherwise inferred
    /// from rewrite_to presence.
    pub fn effectiveAction(self: Rule) Action {
        if (self.action) |a| return a;
        return if (self.rewrite_to != null) .rewrite else .reject;
    }

    /// Returns the display name: explicit name if set, otherwise id.
    pub fn displayName(self: Rule) []const u8 {
        return self.name orelse self.id;
    }
};

pub const ValidationError = error{
    MissingRequiredField,
    DuplicateRuleId,
    RewriteRequiresTarget,
    RejectRequiresMessage,
    EmptyMatch,
};

/// Validate a slice of rules. Returns the first validation error found.
pub fn validate(rules: []const Rule) ValidationError!void {
    for (rules, 0..) |rule, i| {
        if (rule.id.len == 0) {
            return ValidationError.MissingRequiredField;
        }

        // Check for duplicate IDs
        for (rules[0..i]) |prev| {
            if (std.mem.eql(u8, rule.id, prev.id)) {
                return ValidationError.DuplicateRuleId;
            }
        }

        // Validate action (explicit or inferred)
        const action = rule.effectiveAction();
        if (action == .rewrite and rule.rewrite_to == null) {
            return ValidationError.RewriteRequiresTarget;
        }

        if (action == .reject and rule.message == null) {
            return ValidationError.RejectRequiresMessage;
        }

        if (!hasAnyMatch(rule.match)) {
            return ValidationError.EmptyMatch;
        }
    }
}

/// Public wrapper for hasAnyMatch, used by validate_cmd.
pub fn hasAnyMatchPub(m: MatchConfig) bool {
    return hasAnyMatch(m);
}

fn hasAnyMatch(m: MatchConfig) bool {
    return m.command != null or
        m.command_any != null or
        m.command_all != null or
        m.command_regex != null or
        m.flag != null or
        m.flag_any != null or
        m.flag_all != null or
        m.arg != null or
        m.arg_any != null or
        m.arg_all != null or
        m.arg_regex != null or
        m.raw_regex != null or
        m.ast != null;
}

// -- Tests --

test "valid rewrite rule passes validation" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .action = .rewrite,
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};
    try validate(&rules);
}

test "valid reject rule passes validation" {
    const rules = [_]Rule{.{
        .id = "no-python3",
        .action = .reject,
        .message = "Use just run instead.",
        .match = .{ .command = "python3" },
    }};
    try validate(&rules);
}

test "valid reject rule with command_all passes validation" {
    const rules = [_]Rule{.{
        .id = "no-curl-bash",
        .message = "Don't pipe curl to bash.",
        .match = .{ .command_all = &.{ "curl", "bash" } },
    }};
    try validate(&rules);
}

test "action inferred as rewrite when rewrite_to present" {
    const rule = Rule{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    };
    try std.testing.expectEqual(Action.rewrite, rule.effectiveAction());
}

test "action inferred as reject when no rewrite_to" {
    const rule = Rule{
        .id = "no-chmod",
        .message = "nope",
        .match = .{ .command = "chmod" },
    };
    try std.testing.expectEqual(Action.reject, rule.effectiveAction());
}

test "explicit action overrides inference" {
    const rule = Rule{
        .id = "explicit",
        .action = .reject,
        .message = "msg",
        .match = .{ .command = "foo" },
    };
    try std.testing.expectEqual(Action.reject, rule.effectiveAction());
}

test "displayName returns name when set" {
    const rule = Rule{ .id = "my-id", .name = "My Name", .message = "m", .match = .{ .command = "foo" } };
    try std.testing.expectEqualStrings("My Name", rule.displayName());
}

test "displayName falls back to id" {
    const rule = Rule{ .id = "my-id", .message = "m", .match = .{ .command = "foo" } };
    try std.testing.expectEqualStrings("my-id", rule.displayName());
}

test "empty id fails validation" {
    const rules = [_]Rule{.{
        .id = "",
        .message = "msg",
        .match = .{ .command = "foo" },
    }};
    try std.testing.expectError(ValidationError.MissingRequiredField, validate(&rules));
}

test "name is optional" {
    const rules = [_]Rule{.{
        .id = "good-id",
        .message = "msg",
        .match = .{ .command = "foo" },
    }};
    try validate(&rules);
}

test "duplicate IDs fail validation" {
    const rules = [_]Rule{
        .{
            .id = "same-id",
            .message = "msg",
            .match = .{ .command = "foo" },
        },
        .{
            .id = "same-id",
            .message = "msg",
            .match = .{ .command = "bar" },
        },
    };
    try std.testing.expectError(ValidationError.DuplicateRuleId, validate(&rules));
}

test "rewrite without rewrite_to fails" {
    const rules = [_]Rule{.{
        .id = "bad-rewrite",
        .action = .rewrite,
        .match = .{ .command = "foo" },
    }};
    try std.testing.expectError(ValidationError.RewriteRequiresTarget, validate(&rules));
}

test "inferred reject without message fails" {
    const rules = [_]Rule{.{
        .id = "bad-inferred",
        .match = .{ .command = "foo" },
    }};
    try std.testing.expectError(ValidationError.RejectRequiresMessage, validate(&rules));
}

test "reject without message fails" {
    const rules = [_]Rule{.{
        .id = "bad-reject",
        .action = .reject,
        .match = .{ .command = "foo" },
    }};
    try std.testing.expectError(ValidationError.RejectRequiresMessage, validate(&rules));
}

test "empty match fails" {
    const rules = [_]Rule{.{
        .id = "no-match",
        .message = "msg",
    }};
    try std.testing.expectError(ValidationError.EmptyMatch, validate(&rules));
}

test "hasAnyMatch with each field type" {
    // Each field alone should pass hasAnyMatch
    const cases = .{
        MatchConfig{ .command = "x" },
        MatchConfig{ .command_any = &.{"x"} },
        MatchConfig{ .command_all = &.{"x"} },
        MatchConfig{ .command_regex = "x" },
        MatchConfig{ .flag = "x" },
        MatchConfig{ .flag_any = &.{"x"} },
        MatchConfig{ .flag_all = &.{"x"} },
        MatchConfig{ .arg = "x" },
        MatchConfig{ .arg_any = &.{"x"} },
        MatchConfig{ .arg_all = &.{"x"} },
        MatchConfig{ .arg_regex = "x" },
        MatchConfig{ .raw_regex = "x" },
        MatchConfig{ .ast = .{} },
    };
    inline for (cases) |m| {
        try std.testing.expect(hasAnyMatch(m));
    }
    // Empty match should fail
    try std.testing.expect(!hasAnyMatch(MatchConfig{}));
}
