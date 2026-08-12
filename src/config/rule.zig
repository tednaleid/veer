// ABOUTME: Rule data structures for veer config.
// ABOUTME: Defines Rule, MatchConfig, Action and validation logic.

const std = @import("std");

pub const Action = enum {
    rewrite,
    reject,
    /// A gate: the match block is the allowlist of what may pass. A call the
    /// gate does not match is rejected; one it matches falls through to the
    /// next rule. A gate never approves-and-stops, which is what makes gates
    /// monotonically narrowing: adding one can only reduce what passes.
    allow,
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

    // Content matching (for non-Bash tools that carry text content -- e.g.
    // ExitPlanMode plan body). Both AND together when set on the same rule.
    content_regex: ?[]const u8 = null,
    content_contains: ?[]const u8 = null,

    // Path matching (for tools that carry a target path). Patterns are
    // gitignore-shaped globs; see README for the anchoring rules.
    path: ?[]const u8 = null,
    path_any: ?[]const []const u8 = null,
    path_regex: ?[]const u8 = null,

    // AST structural matching
    ast: ?AstMatch = null,
};

/// Which ToolCall fields a rule's matchers read. A matcher whose field is
/// null on the call makes the whole rule inapplicable.
pub const FieldSet = struct {
    command: bool = false,
    content: bool = false,
    path: bool = false,
};

/// Partition a match config by the ToolCall field each matcher family reads.
pub fn fieldsUsed(m: MatchConfig) FieldSet {
    return .{
        .command = m.command != null or m.command_any != null or
            m.command_all != null or m.command_regex != null or
            m.flag != null or m.flag_any != null or m.flag_all != null or
            m.arg != null or m.arg_any != null or m.arg_all != null or
            m.arg_regex != null or m.raw_regex != null or m.ast != null,
        .content = m.content_regex != null or m.content_contains != null,
        .path = m.path != null or m.path_any != null or m.path_regex != null,
    };
}

/// Fields a known tool's input carries. Returns null for tools veer does not
/// recognize, including MCP tools, which exempts them from compatibility
/// validation rather than rejecting them. veer does not bake Claude Code's
/// tool roster into its schema.
pub fn toolFields(tool: []const u8) ?FieldSet {
    if (std.mem.eql(u8, tool, "Bash")) return .{ .command = true };
    if (std.mem.eql(u8, tool, "ExitPlanMode")) return .{ .content = true };

    const path_tools = [_][]const u8{
        "Write", "Edit", "NotebookEdit", "Read", "Grep", "Glob",
    };
    for (path_tools) |t| {
        if (std.mem.eql(u8, tool, t)) return .{ .path = true };
    }
    return null;
}

pub const Rule = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    action: ?Action = null,
    enabled: bool = true,
    tool: []const u8 = "Bash",

    /// Tools this rule applies to. Exact names, no globbing. Mutually
    /// exclusive with `tool`.
    tool_any: ?[]const []const u8 = null,
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

    /// True when this rule applies to `tool_name`. Uses `tool_any` when set,
    /// otherwise the single `tool` field.
    pub fn matchesTool(self: Rule, tool_name: []const u8) bool {
        if (self.tool_any) |tools| {
            for (tools) |t| {
                if (std.mem.eql(u8, t, tool_name)) return true;
            }
            return false;
        }
        return std.mem.eql(u8, self.tool, tool_name);
    }
};

pub const ValidationError = error{
    MissingRequiredField,
    DuplicateRuleId,
    RewriteRequiresTarget,
    RejectRequiresMessage,
    EmptyMatch,
    MatcherToolMismatch,
    AllowRequiresPathOrContent,
    ToolAndToolAny,
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

        // `tool` is non-optional with a default of "Bash", so TOML gives no
        // way to distinguish "absent" from "explicitly set to Bash". The
        // check compares against the default rather than testing presence.
        if (rule.tool_any != null and !std.mem.eql(u8, rule.tool, "Bash")) {
            return ValidationError.ToolAndToolAny;
        }

        // Validate action (explicit or inferred)
        const action = rule.effectiveAction();
        if (action == .rewrite and rule.rewrite_to == null) {
            return ValidationError.RewriteRequiresTarget;
        }

        if ((action == .reject or action == .allow) and rule.message == null) {
            return ValidationError.RejectRequiresMessage;
        }

        const used = fieldsUsed(rule.match);
        if (rule.tool_any) |tools| {
            for (tools) |t| {
                if (toolFields(t)) |carried| {
                    if ((used.command and !carried.command) or
                        (used.content and !carried.content) or
                        (used.path and !carried.path))
                    {
                        return ValidationError.MatcherToolMismatch;
                    }
                }
            }
        } else if (toolFields(rule.tool)) |carried| {
            if ((used.command and !carried.command) or
                (used.content and !carried.content) or
                (used.path and !carried.path))
            {
                return ValidationError.MatcherToolMismatch;
            }
        }

        if (action == .allow) {
            if (used.command) return ValidationError.AllowRequiresPathOrContent;
        }

        if (!hasAnyMatch(rule.match) and rule.tool_any == null) {
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
        m.content_regex != null or
        m.content_contains != null or
        m.path != null or
        m.path_any != null or
        m.path_regex != null or
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
        MatchConfig{ .content_regex = "x" },
        MatchConfig{ .content_contains = "x" },
        MatchConfig{ .path = "x" },
        MatchConfig{ .path_any = &.{"x"} },
        MatchConfig{ .path_regex = "x" },
        MatchConfig{ .ast = .{} },
    };
    inline for (cases) |m| {
        try std.testing.expect(hasAnyMatch(m));
    }
    // Empty match should fail
    try std.testing.expect(!hasAnyMatch(MatchConfig{}));
}

test "content_contains alone is a valid match" {
    const rules = [_]Rule{.{
        .id = "no-actually-in-plans",
        .tool = "ExitPlanMode",
        .message = "Plans should not contain 'actually'.",
        .match = .{ .content_contains = "actually" },
    }};
    try validate(&rules);
}

test "content_regex alone is a valid match" {
    const rules = [_]Rule{.{
        .id = "no-todo-in-plans",
        .tool = "ExitPlanMode",
        .message = "Plans should not contain TODO placeholders.",
        .match = .{ .content_regex = "TODO|FIXME" },
    }};
    try validate(&rules);
}

test "raw_regex on a Write rule fails validation" {
    const rules = [_]Rule{.{
        .id = "probe",
        .tool = "Write",
        .message = "M",
        .match = .{ .raw_regex = "x" },
    }};
    try std.testing.expectError(ValidationError.MatcherToolMismatch, validate(&rules));
}

test "content matcher on a Bash rule fails validation" {
    const rules = [_]Rule{.{
        .id = "probe",
        .tool = "Bash",
        .message = "M",
        .match = .{ .content_contains = "actually" },
    }};
    try std.testing.expectError(ValidationError.MatcherToolMismatch, validate(&rules));
}

test "unknown tool names are exempt from compatibility validation" {
    const rules = [_]Rule{.{
        .id = "mcp-rule",
        .tool = "mcp__filesystem__write_file",
        .message = "M",
        .match = .{ .raw_regex = "x" },
    }};
    try validate(&rules);
}

test "path matcher on a Bash rule fails validation" {
    const rules = [_]Rule{.{
        .id = "probe",
        .tool = "Bash",
        .message = "M",
        .match = .{ .path_any = &.{"src/**"} },
    }};
    try std.testing.expectError(ValidationError.MatcherToolMismatch, validate(&rules));
}

test "path matcher on a Write rule passes validation" {
    const rules = [_]Rule{.{
        .id = "no-gen-edits",
        .tool = "Write",
        .message = "M",
        .match = .{ .path_any = &.{"**/*.gen.ts"} },
    }};
    try validate(&rules);
}

test "allow requires a message" {
    const rules = [_]Rule{.{
        .id = "gate",
        .action = .allow,
        .tool = "Write",
        .match = .{ .path_any = &.{"src/**"} },
    }};
    try std.testing.expectError(ValidationError.RejectRequiresMessage, validate(&rules));
}

test "allow rejects a command matcher" {
    const rules = [_]Rule{.{
        .id = "gate",
        .action = .allow,
        .tool = "Bash",
        .message = "Use a just recipe.",
        .match = .{ .command_any = &.{ "just", "git" } },
    }};
    try std.testing.expectError(ValidationError.AllowRequiresPathOrContent, validate(&rules));
}

test "tool and tool_any together fail validation" {
    const rules = [_]Rule{.{
        .id = "both",
        .tool = "Write",
        .tool_any = &.{"Edit"},
        .message = "M",
        .match = .{ .path_any = &.{"src/**"} },
    }};
    try std.testing.expectError(ValidationError.ToolAndToolAny, validate(&rules));
}

test "tool_any with no matchers is a valid tool-name-only rule" {
    const rules = [_]Rule{.{
        .id = "no-notebooks",
        .tool_any = &.{"NotebookEdit"},
        .message = "M",
    }};
    try validate(&rules);
}

test "allow accepts a content matcher" {
    const rules = [_]Rule{.{
        .id = "plans-need-testing",
        .action = .allow,
        .tool = "ExitPlanMode",
        .message = "Add a Testing section.",
        .match = .{ .content_regex = "## Testing" },
    }};
    try validate(&rules);
}
