// ABOUTME: Rule matching functions for each match type.
// ABOUTME: Pure functions that test rules against parsed CommandInfo.

const std = @import("std");
const Rule = @import("../config/rule.zig").Rule;
const MatchConfig = @import("../config/rule.zig").MatchConfig;
const AstMatch = @import("../config/rule.zig").AstMatch;
const CommandInfo = @import("command_info.zig").CommandInfo;
const SingleCommand = @import("command_info.zig").SingleCommand;

/// Returns the index of the matched command, or null if no match.
/// For cross-command-only matches (no per-command fields), returns
/// a sentinel (no specific command matched).
pub const CROSS_COMMAND_MATCH: usize = std.math.maxInt(usize);

pub fn matchRule(rule: Rule, info: CommandInfo) ?usize {
    const m = rule.match;

    // Level 1: Raw input check (before parsing)
    if (m.raw_regex) |pattern| {
        if (!regexMatch(pattern, info.raw)) return null;
        if (isOnlyCrossField(m)) return CROSS_COMMAND_MATCH;
    }

    // Level 2: Cross-command checks
    if (m.command_all) |required| {
        if (!matchCommandAll(required, info)) return null;
        if (isOnlyCrossField(m)) return CROSS_COMMAND_MATCH;
    }

    if (m.ast) |ast_match| {
        if (!matchAst(ast_match, info)) return null;
        if (isOnlyCrossField(m)) return CROSS_COMMAND_MATCH;
    }

    // Level 3: Per-command checks (iterate commands, all must match on ONE command)
    if (hasPerCommandFields(m)) {
        for (info.commands.items, 0..) |cmd, i| {
            if (matchSingleCommand(m, cmd)) return i;
        }
        return null;
    }

    return CROSS_COMMAND_MATCH;
}

/// Check if all per-command match fields match a single command.
fn matchSingleCommand(m: MatchConfig, cmd: SingleCommand) bool {
    var any_field = false;

    // Command name matching (glob-aware)
    if (m.command) |pattern| {
        any_field = true;
        if (!globMatch(pattern, cmd.name)) return false;
    }

    if (m.command_any) |patterns| {
        any_field = true;
        var found = false;
        for (patterns) |pattern| {
            if (globMatch(pattern, cmd.name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    if (m.command_regex) |pattern| {
        any_field = true;
        if (!regexMatch(pattern, cmd.name)) return false;
    }

    // Flag matching (smart: no dash prefix, combined short flag handling)
    if (m.flag) |flag_name| {
        any_field = true;
        if (!matchFlag(cmd, flag_name)) return false;
    }

    if (m.flag_any) |flags| {
        any_field = true;
        var found = false;
        for (flags) |flag_name| {
            if (matchFlag(cmd, flag_name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    if (m.flag_all) |flags| {
        any_field = true;
        for (flags) |flag_name| {
            if (!matchFlag(cmd, flag_name)) return false;
        }
    }

    // Arg matching (positional only, glob-aware)
    if (m.arg) |pattern| {
        any_field = true;
        if (!matchAnyPositional(cmd, pattern, globMatch)) return false;
    }

    if (m.arg_any) |patterns| {
        any_field = true;
        var found = false;
        for (patterns) |pattern| {
            if (matchAnyPositional(cmd, pattern, globMatch)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    if (m.arg_all) |patterns| {
        any_field = true;
        for (patterns) |pattern| {
            if (!matchAnyPositional(cmd, pattern, globMatch)) return false;
        }
    }

    if (m.arg_regex) |pattern| {
        any_field = true;
        if (!matchAnyPositional(cmd, pattern, regexMatch)) return false;
    }

    return any_field;
}

/// Smart flag matching. No dash prefix in the pattern.
/// Single char: matches combined short flags (-f in -rf).
/// Multi char: glob match on long flags (--force, --no-*).
fn matchFlag(cmd: SingleCommand, flag_name: []const u8) bool {
    if (flag_name.len == 1) {
        // Short flag: check if char appears in any combined short flag
        for (cmd.flags.items) |f| {
            if (f.len >= 2 and f[0] == '-' and f[1] != '-') {
                // Short flag(s): strip leading dash and check for char
                if (std.mem.indexOfScalar(u8, f[1..], flag_name[0]) != null) return true;
            }
        }
    } else {
        // Long flag: glob match against --{name}
        for (cmd.flags.items) |f| {
            if (f.len > 2 and f[0] == '-' and f[1] == '-') {
                if (globMatch(flag_name, f[2..])) return true;
            }
        }
    }
    return false;
}

/// Check if any positional arg matches using the given match function.
fn matchAnyPositional(cmd: SingleCommand, pattern: []const u8, matchFn: fn ([]const u8, []const u8) bool) bool {
    for (cmd.positional.items) |pos_arg| {
        if (matchFn(pattern, pos_arg)) return true;
    }
    return false;
}

/// Check if all required commands exist somewhere in the AST (glob-aware).
fn matchCommandAll(required: []const []const u8, info: CommandInfo) bool {
    for (required) |req| {
        var found = false;
        for (info.commands.items) |cmd| {
            if (globMatch(req, cmd.name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

/// Check AST structural properties.
fn matchAst(ast_match: AstMatch, info: CommandInfo) bool {
    if (ast_match.has_node) |node_type| {
        if (std.mem.eql(u8, node_type, "pipeline") and info.pipeline_length == 0) return false;
        if (std.mem.eql(u8, node_type, "command_substitution") and !info.has_command_subst) return false;
        if (std.mem.eql(u8, node_type, "subshell") and !info.has_subshell) return false;
        if (std.mem.eql(u8, node_type, "process_substitution") and !info.has_process_subst) return false;
    }

    if (ast_match.min_depth) |min_depth| {
        if (info.max_nesting_depth < @as(u32, @intCast(min_depth))) return false;
    }

    if (ast_match.min_count) |min_count| {
        if (info.commands.items.len < @as(usize, @intCast(min_count))) return false;
    }

    return true;
}

/// Check if the match config has any per-command fields set.
fn hasPerCommandFields(m: MatchConfig) bool {
    return m.command != null or m.command_any != null or m.command_regex != null or
        m.flag != null or m.flag_any != null or m.flag_all != null or
        m.arg != null or m.arg_any != null or m.arg_all != null or m.arg_regex != null;
}

/// Check if only cross-command/raw fields are set (no per-command fields).
fn isOnlyCrossField(m: MatchConfig) bool {
    return !hasPerCommandFields(m);
}

/// Simple glob matching supporting *, ?, and {a,b,c} brace expansion.
pub fn globMatch(pattern: []const u8, text: []const u8) bool {
    // Handle brace expansion first
    if (std.mem.indexOfScalar(u8, pattern, '{')) |brace_start| {
        if (std.mem.indexOfScalarPos(u8, pattern, brace_start, '}')) |brace_end| {
            const prefix = pattern[0..brace_start];
            const suffix = pattern[brace_end + 1 ..];
            const alternatives = pattern[brace_start + 1 .. brace_end];

            var iter = std.mem.splitScalar(u8, alternatives, ',');
            while (iter.next()) |alt| {
                // Build expanded pattern: prefix + alt + suffix
                var buf: [512]u8 = undefined;
                const expanded_len = prefix.len + alt.len + suffix.len;
                if (expanded_len > buf.len) continue;
                @memcpy(buf[0..prefix.len], prefix);
                @memcpy(buf[prefix.len..][0..alt.len], alt);
                @memcpy(buf[prefix.len + alt.len ..][0..suffix.len], suffix);
                if (globMatchSimple(buf[0..expanded_len], text)) return true;
            }
            return false;
        }
    }
    return globMatchSimple(pattern, text);
}

/// Glob matching without brace expansion (just * and ?).
fn globMatchSimple(pattern: []const u8, text: []const u8) bool {
    var pi: usize = 0;
    var ti: usize = 0;
    var star_pi: ?usize = null;
    var star_ti: usize = 0;

    while (ti < text.len or pi < pattern.len) {
        if (pi < pattern.len) {
            if (pattern[pi] == '*') {
                star_pi = pi;
                star_ti = ti;
                pi += 1;
                continue;
            }
            if (ti < text.len) {
                if (pattern[pi] == '?' or pattern[pi] == text[ti]) {
                    pi += 1;
                    ti += 1;
                    continue;
                }
            }
        }
        if (star_pi) |sp| {
            pi = sp + 1;
            star_ti += 1;
            ti = star_ti;
            if (ti > text.len) return false;
            continue;
        }
        return false;
    }
    return true;
}

const c = @cImport({
    @cInclude("veer_regex.h");
});

/// POSIX extended regex matching via vendored C wrapper.
/// The C wrapper handles regex_t allocation, which is opaque in glibc's @cImport.
fn regexMatch(pattern: []const u8, text: []const u8) bool {
    var pat_buf: [256]u8 = undefined;
    var txt_buf: [1024]u8 = undefined;
    if (pattern.len >= pat_buf.len or text.len >= txt_buf.len) return false;

    @memcpy(pat_buf[0..pattern.len], pattern);
    pat_buf[pattern.len] = 0;
    @memcpy(txt_buf[0..text.len], text);
    txt_buf[text.len] = 0;

    return c.veer_regex_match(&pat_buf, &txt_buf) == 1;
}

// -- Tests --

const shell = @import("shell.zig");

fn parseCmd(allocator: std.mem.Allocator, command: []const u8) !CommandInfo {
    return shell.parse(allocator, command);
}

test "command exact match" {
    var info = try parseCmd(std.testing.allocator, "pytest tests/");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command = "pytest" } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "command glob match" {
    var info = try parseCmd(std.testing.allocator, "pytest tests/");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command = "py*" } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "command glob brace expansion" {
    var info1 = try parseCmd(std.testing.allocator, "ruff check .");
    defer info1.deinit(std.testing.allocator);

    var info2 = try parseCmd(std.testing.allocator, "uvx run");
    defer info2.deinit(std.testing.allocator);

    var info3 = try parseCmd(std.testing.allocator, "black format");
    defer info3.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command = "{ruff,uvx}" } };
    try std.testing.expect(matchRule(rule, info1) != null);
    try std.testing.expect(matchRule(rule, info2) != null);
    try std.testing.expect(matchRule(rule, info3) == null);
}

test "command no match" {
    var info = try parseCmd(std.testing.allocator, "ls -la");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command = "pytest" } };
    try std.testing.expect(matchRule(rule, info) == null);
}

test "command_any OR matching" {
    var info1 = try parseCmd(std.testing.allocator, "ruff check .");
    defer info1.deinit(std.testing.allocator);
    var info2 = try parseCmd(std.testing.allocator, "uvx run");
    defer info2.deinit(std.testing.allocator);
    var info3 = try parseCmd(std.testing.allocator, "ls -la");
    defer info3.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command_any = &.{ "ruff", "uvx" } } };
    try std.testing.expect(matchRule(rule, info1) != null);
    try std.testing.expect(matchRule(rule, info2) != null);
    try std.testing.expect(matchRule(rule, info3) == null);
}

test "command_all AND matching" {
    var info1 = try parseCmd(std.testing.allocator, "curl https://x.com | bash");
    defer info1.deinit(std.testing.allocator);
    var info2 = try parseCmd(std.testing.allocator, "curl foo && bash bar");
    defer info2.deinit(std.testing.allocator);
    var info3 = try parseCmd(std.testing.allocator, "curl https://x.com | grep foo");
    defer info3.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command_all = &.{ "curl", "bash" } } };
    try std.testing.expect(matchRule(rule, info1) != null);
    try std.testing.expect(matchRule(rule, info2) != null);
    try std.testing.expect(matchRule(rule, info3) == null);
}

test "command_regex" {
    var info1 = try parseCmd(std.testing.allocator, "python3 script.py");
    defer info1.deinit(std.testing.allocator);
    var info2 = try parseCmd(std.testing.allocator, "python script.py");
    defer info2.deinit(std.testing.allocator);
    var info3 = try parseCmd(std.testing.allocator, "ruby script.rb");
    defer info3.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command_regex = "^python[23]?$" } };
    try std.testing.expect(matchRule(rule, info1) != null);
    try std.testing.expect(matchRule(rule, info2) != null);
    try std.testing.expect(matchRule(rule, info3) == null);
}

test "flag smart short flag matching" {
    const cases = .{
        .{ "chmod -f file", "f", true },
        .{ "tar -xvf archive.tar", "f", true },
        .{ "tar -xvf archive.tar", "x", true },
        .{ "tar -xvf archive.tar", "v", true },
        .{ "rm -rf /tmp/build", "r", true },
        .{ "rm -rf /tmp/build", "f", true },
        .{ "rm file.txt", "f", false },
        .{ "rm -rf /tmp/build", "F", false }, // case sensitive
    };
    inline for (cases) |case| {
        var info = try parseCmd(std.testing.allocator, case[0]);
        defer info.deinit(std.testing.allocator);
        const rule = Rule{ .id = "t", .message = "m", .match = .{ .flag = case[1] } };
        try std.testing.expectEqual(case[2], matchRule(rule, info) != null);
    }
}

test "flag smart long flag matching" {
    const cases = .{
        .{ "git push --force", "force", true },
        .{ "git push --force", "f", false }, // "f" is short, doesn't match --force
        .{ "git commit --no-verify", "no-verify", true },
        .{ "git commit --no-verify", "no-*", true }, // glob on long flags
        .{ "ls --color=auto", "color", false }, // --color=auto won't match "color" because = is part of the flag
    };
    inline for (cases) |case| {
        var info = try parseCmd(std.testing.allocator, case[0]);
        defer info.deinit(std.testing.allocator);
        const rule = Rule{ .id = "t", .message = "m", .match = .{ .flag = case[1] } };
        try std.testing.expectEqual(case[2], matchRule(rule, info) != null);
    }
}

test "flag_any OR matching" {
    var info = try parseCmd(std.testing.allocator, "git push --force");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .flag_any = &.{ "f", "force" } } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "flag_all AND matching" {
    var info1 = try parseCmd(std.testing.allocator, "rm -rf /tmp/build");
    defer info1.deinit(std.testing.allocator);
    var info2 = try parseCmd(std.testing.allocator, "rm -r /tmp/build");
    defer info2.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .flag_all = &.{ "r", "f" } } };
    try std.testing.expect(matchRule(rule, info1) != null);
    try std.testing.expect(matchRule(rule, info2) == null);
}

test "arg positional matching" {
    var info = try parseCmd(std.testing.allocator, "git commit -m fix");
    defer info.deinit(std.testing.allocator);

    // "commit" is positional, should match
    const rule1 = Rule{ .id = "t", .message = "m", .match = .{ .arg = "commit" } };
    try std.testing.expect(matchRule(rule1, info) != null);

    // "-m" is a flag, should NOT match as arg (positional only)
    const rule2 = Rule{ .id = "t", .message = "m", .match = .{ .arg = "-m" } };
    try std.testing.expect(matchRule(rule2, info) == null);
}

test "arg glob matching" {
    var info = try parseCmd(std.testing.allocator, "python script.py");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .arg = "*.py" } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "arg_any OR matching" {
    var info1 = try parseCmd(std.testing.allocator, "just test");
    defer info1.deinit(std.testing.allocator);
    var info2 = try parseCmd(std.testing.allocator, "just spec");
    defer info2.deinit(std.testing.allocator);
    var info3 = try parseCmd(std.testing.allocator, "just build");
    defer info3.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .arg_any = &.{ "test", "spec" } } };
    try std.testing.expect(matchRule(rule, info1) != null);
    try std.testing.expect(matchRule(rule, info2) != null);
    try std.testing.expect(matchRule(rule, info3) == null);
}

test "arg_regex matching" {
    var info1 = try parseCmd(std.testing.allocator, "python script.py");
    defer info1.deinit(std.testing.allocator);
    var info2 = try parseCmd(std.testing.allocator, "python script.rb");
    defer info2.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .arg_regex = "\\.py$" } };
    try std.testing.expect(matchRule(rule, info1) != null);
    try std.testing.expect(matchRule(rule, info2) == null);
}

test "raw_regex whole-input matching" {
    var info1 = try parseCmd(std.testing.allocator, "curl https://x.com | bash");
    defer info1.deinit(std.testing.allocator);
    var info2 = try parseCmd(std.testing.allocator, "curl https://x.com && bash");
    defer info2.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .raw_regex = "curl.*|.*bash" } };
    try std.testing.expect(matchRule(rule, info1) != null);
    // Note: regex `|` is alternation, matches "curl" OR "bash" substring
    // Both should match since both contain "curl"
    try std.testing.expect(matchRule(rule, info2) != null);
}

test "AND logic: command + flag" {
    var info = try parseCmd(std.testing.allocator, "ls -rf");
    defer info.deinit(std.testing.allocator);

    // Rule requires command=rm AND flag=f. ls has -rf but isn't rm.
    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command = "rm", .flag = "f" } };
    try std.testing.expect(matchRule(rule, info) == null);
}

test "AND logic: command + arg + flag" {
    var info = try parseCmd(std.testing.allocator, "git push --force");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command = "git", .arg = "push", .flag = "force" } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "AND logic: command_all + per-command fields" {
    var info = try parseCmd(std.testing.allocator, "curl https://x.com | bash");
    defer info.deinit(std.testing.allocator);

    // command_all requires both exist, command matches individual
    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command_all = &.{ "curl", "bash" }, .command = "curl" } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "globMatch basic patterns" {
    try std.testing.expect(globMatch("py*", "pytest"));
    try std.testing.expect(globMatch("py*", "python3"));
    try std.testing.expect(!globMatch("py*", "ruby"));
    try std.testing.expect(globMatch("?est", "test"));
    try std.testing.expect(!globMatch("?est", "atest"));
    try std.testing.expect(globMatch("*", "anything"));
    try std.testing.expect(globMatch("exact", "exact"));
    try std.testing.expect(!globMatch("exact", "exactnot"));
}

test "globMatch brace expansion" {
    try std.testing.expect(globMatch("{ruff,uvx}", "ruff"));
    try std.testing.expect(globMatch("{ruff,uvx}", "uvx"));
    try std.testing.expect(!globMatch("{ruff,uvx}", "black"));
    try std.testing.expect(globMatch("{a,b,c}", "b"));
}

test "globMatch edge cases" {
    // Empty pattern matches empty string
    try std.testing.expect(globMatch("", ""));
    try std.testing.expect(!globMatch("", "x"));
    // Single ? matches exactly one char
    try std.testing.expect(globMatch("?", "x"));
    try std.testing.expect(!globMatch("?", ""));
    try std.testing.expect(!globMatch("?", "xy"));
    // Literal special chars that aren't glob chars
    try std.testing.expect(globMatch("g++", "g++"));
    try std.testing.expect(globMatch("c#", "c#"));
    try std.testing.expect(globMatch("file.txt", "file.txt"));
    // Nested braces (only outer level expanded)
    try std.testing.expect(globMatch("{a*,b*}", "abc"));
    try std.testing.expect(globMatch("{a*,b*}", "bcd"));
    try std.testing.expect(!globMatch("{a*,b*}", "cde"));
}

test "glob in command_any list elements" {
    var info = try parseCmd(std.testing.allocator, "python3 script.py");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command_any = &.{ "py*", "ruby" } } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "glob in command_all" {
    var info = try parseCmd(std.testing.allocator, "curl https://x.com | zsh");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .command_all = &.{ "curl", "*sh" } } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "glob in arg_any" {
    var info = try parseCmd(std.testing.allocator, "python script.py");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .arg_any = &.{ "*.py", "*.rb" } } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "glob in arg_all" {
    var info = try parseCmd(std.testing.allocator, "cp src/main.zig README.md");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .arg_all = &.{ "src/*", "*.md" } } };
    try std.testing.expect(matchRule(rule, info) != null);
}

test "flag long glob matching" {
    var info1 = try parseCmd(std.testing.allocator, "git commit --no-verify");
    defer info1.deinit(std.testing.allocator);
    var info2 = try parseCmd(std.testing.allocator, "git commit --no-edit");
    defer info2.deinit(std.testing.allocator);
    var info3 = try parseCmd(std.testing.allocator, "git commit --amend");
    defer info3.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .message = "m", .match = .{ .flag = "no-*" } };
    try std.testing.expect(matchRule(rule, info1) != null);
    try std.testing.expect(matchRule(rule, info2) != null);
    try std.testing.expect(matchRule(rule, info3) == null);
}

// -- Fuzz tests --

test "fuzz globMatch never panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            // Split input into pattern and text at midpoint
            if (input.len < 2) return;
            const mid = input.len / 2;
            _ = globMatch(input[0..mid], input[mid..]);
        }
    }.run, .{});
}

test "fuzz regexMatch never panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            if (input.len < 2) return;
            const mid = input.len / 2;
            // Ensure no null bytes in the inputs (C strings)
            for (input[0..mid]) |b| if (b == 0) return;
            for (input[mid..]) |b| if (b == 0) return;
            _ = regexMatch(input[0..mid], input[mid..]);
        }
    }.run, .{});
}
