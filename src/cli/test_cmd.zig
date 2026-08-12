// ABOUTME: Test a command against veer rules without crafting hook JSON.
// ABOUTME: Prints which rule matched, the action, and relevant details.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const engine = @import("../engine/engine.zig");
const Rule = @import("../config/rule.zig").Rule;
const Action = @import("../config/rule.zig").Action;
const color = @import("../display/color.zig");

pub const TestOptions = struct {
    command: ?[]const u8 = null,
    /// File of commands to test, one per line. Bash only.
    file_path: ?[]const u8 = null,
    /// Tool name to evaluate against. Defaults to Bash so every existing
    /// invocation is unchanged.
    tool: []const u8 = "Bash",
    /// Target path, for rules on tools that carry one.
    path: ?[]const u8 = null,
    /// File whose body stands in for the tool's content, e.g. a plan body.
    content_file: ?[]const u8 = null,
};

/// Run the test command. Tests command(s) against loaded rules.
/// `sources` is parallel to `rules` when non-null (i.e. when the rules came
/// from `loadMerged`); the TSV output then includes a 6th `source` column
/// showing `project`/`global` for matches and empty for `ALLOW` lines.
pub fn run(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    sources: ?[]const config_mod.RuleSource,
    opts: TestOptions,
    writer: anytype,
) !u8 {
    if (sources) |s| std.debug.assert(s.len == rules.len);

    if (opts.file_path) |path| {
        return runFile(allocator, rules, sources, path, writer);
    }

    const is_bash = std.mem.eql(u8, opts.tool, "Bash");

    if (is_bash and opts.path == null and opts.content_file == null) {
        const command = opts.command orelse {
            try writer.print("veer test: command argument or --file required\n", .{});
            try writer.print("Usage: veer test \"<command>\" [--config <path>]\n", .{});
            try writer.print("       veer test --file <path> [--config <path>]\n", .{});
            try writer.print("       veer test --tool <Tool> --path <path>\n", .{});
            return 1;
        };
        return checkOne(allocator, rules, sources, command, writer);
    }

    const content: ?[]u8 = if (opts.content_file) |cf|
        std.fs.cwd().readFileAlloc(allocator, cf, 4 * 1024 * 1024) catch {
            try writer.print("veer test: cannot read {s}\n", .{cf});
            return 1;
        }
    else
        null;
    defer if (content) |c| allocator.free(c);

    const cwd_abs = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
    defer if (cwd_abs) |c| allocator.free(c);

    return checkCall(allocator, rules, sources, .{
        .tool_name = opts.tool,
        .command = opts.command,
        .content = content,
        .file_path = opts.path,
        .cwd = cwd_abs,
        .root = cwd_abs,
    }, opts.path orelse opts.content_file orelse opts.command orelse "", writer);
}

/// Check every non-empty, non-comment line in a file.
fn runFile(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    sources: ?[]const config_mod.RuleSource,
    path: []const u8,
    writer: anytype,
) !u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
        try writer.print("veer test: cannot read {s}\n", .{path});
        return 1;
    };
    defer allocator.free(content);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        _ = try checkOne(allocator, rules, sources, trimmed, writer);
    }

    return 0;
}

fn checkOne(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    sources: ?[]const config_mod.RuleSource,
    command: []const u8,
    writer: anytype,
) !u8 {
    return checkCall(allocator, rules, sources, .{
        .tool_name = "Bash",
        .command = command,
    }, command, writer);
}

fn checkCall(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    sources: ?[]const config_mod.RuleSource,
    call: engine.ToolCall,
    label: []const u8,
    writer: anytype,
) !u8 {
    const result = engine.check(allocator, rules, call);

    // TSV: result, return_code, input, id, output [, source]
    // The `source` column is appended only when `sources` is non-null
    // (i.e. when running against a merged config). It is empty for ALLOW
    // lines because no rule matched.
    const src_suffix = if (sources) |srcs| sourceSuffixFor(rules, srcs, result.rule_id) else "";

    if (result.action) |action| {
        switch (action) {
            .rewrite => {
                const rewritten = if (result.rewrite_to) |target|
                    spliceRewrite(allocator, call.command orelse label, target, result.match_start, result.match_end)
                else
                    SpliceResult{ .command = call.command orelse label, .allocated = false };
                defer if (rewritten.allocated) allocator.free(rewritten.command);
                try writer.print("REWRITE\t0\t{s}\t{s}\t{s}{s}\n", .{
                    label,
                    result.rule_id orelse "",
                    rewritten.command,
                    src_suffix,
                });
            },
            .reject => {
                try writer.print("REJECT\t2\t{s}\t{s}\t{s}{s}\n", .{
                    label,
                    result.rule_id orelse "",
                    result.message orelse "",
                    src_suffix,
                });
            },
        }
    } else {
        try writer.print("ALLOW\t0\t{s}\t\t{s}\n", .{ label, src_suffix });
    }

    return 0;
}

/// Returns "\t<source>" for the matched rule, or "\t" when no rule matched
/// (so the column is still present but empty). Caller has already checked
/// that `sources` is non-null.
fn sourceSuffixFor(rules: []const Rule, sources: []const config_mod.RuleSource, matched_rule_id: ?[]const u8) []const u8 {
    const id = matched_rule_id orelse return "\t";
    for (rules, sources) |rule, src| {
        if (std.mem.eql(u8, rule.id, id)) return switch (src) {
            .local => "\tlocal",
            .project => "\tproject",
            .global => "\tglobal",
        };
    }
    return "\t";
}

const SpliceResult = struct {
    command: []const u8,
    allocated: bool,
};

/// Splice rewrite_to into the original command at the matched byte range.
fn spliceRewrite(allocator: std.mem.Allocator, raw: []const u8, rewrite_to: []const u8, match_start: ?u32, match_end: ?u32) SpliceResult {
    const start = match_start orelse return .{ .command = rewrite_to, .allocated = false };
    const end = match_end orelse return .{ .command = rewrite_to, .allocated = false };

    if (start == 0 and end >= raw.len) {
        return .{ .command = rewrite_to, .allocated = false };
    }

    const new_len = start + rewrite_to.len + (raw.len - end);
    const buf = allocator.alloc(u8, new_len) catch return .{ .command = rewrite_to, .allocated = false };
    @memcpy(buf[0..start], raw[0..start]);
    @memcpy(buf[start..][0..rewrite_to.len], rewrite_to);
    @memcpy(buf[start + rewrite_to.len ..], raw[end..]);
    return .{ .command = buf, .allocated = true };
}

// -- Tests --

test "test command shows REWRITE TSV" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, null, .{ .command = "pytest tests/" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("REWRITE\t0\tpytest tests/\tuse-just-test\tjust test\n", stream.getWritten());
}

test "test command shows REJECT TSV" {
    const rules = [_]Rule{.{
        .id = "no-chmod",
        .message = "Avoid world-writable permissions",
        .match = .{ .command = "chmod" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, null, .{ .command = "chmod 777 server.py" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("REJECT\t2\tchmod 777 server.py\tno-chmod\tAvoid world-writable permissions\n", stream.getWritten());
}

test "test command shows ALLOW TSV" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, null, .{ .command = "ls -la" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("ALLOW\t0\tls -la\t\t\n", stream.getWritten());
}

test "test command without argument returns error" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &.{}, null, .{}, stream.writer());

    try std.testing.expectEqual(@as(u8, 1), exit_code);
}

test "test surgical rewrite in compound command" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, null, .{ .command = "echo start && pytest tests/ && echo done" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    // TSV output column should show the full spliced command
    try std.testing.expect(std.mem.indexOf(u8, output, "echo start && just test && echo done") != null);
}

test "test --file checks each line" {
    const rules = [_]Rule{
        .{ .id = "use-just-test", .rewrite_to = "just test", .match = .{ .command = "pytest" } },
        .{ .id = "no-chmod", .message = "nope", .match = .{ .command = "chmod" } },
    };

    // Create a temp file with commands
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("commands.txt", .{});
    try file.writeAll("# comment\npytest tests/\n\nchmod 777 foo\nls -la\n");
    file.close();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "commands.txt");
    defer std.testing.allocator.free(path);

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, null, .{ .file_path = path }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "REWRITE\t0\tpytest tests/\tuse-just-test\tjust test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "REJECT\t2\tchmod 777 foo\tno-chmod\tnope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ALLOW\t0\tls -la\t\t") != null);
}

test "run with --tool and --path evaluates a non-Bash rule" {
    const rules = [_]Rule{.{
        .id = "no-plan-todos",
        .tool = "ExitPlanMode",
        .message = "Plans must not contain TODO.",
        .match = .{ .content_contains = "TODO" },
    }};

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    // A Write call must not trip an ExitPlanMode rule.
    _ = try run(std.testing.allocator, &rules, null, .{
        .tool = "Write",
        .path = "src/App.vue",
    }, stream.writer());

    const out = stream.getWritten();
    try std.testing.expect(std.mem.startsWith(u8, out, "ALLOW\t"));
    try std.testing.expect(std.mem.indexOf(u8, out, "src/App.vue") != null);
}

test "test appends source column when sources are provided" {
    const rules = [_]Rule{
        .{ .id = "p-rewrite", .rewrite_to = "just test", .match = .{ .command = "pytest" } },
        .{ .id = "g-reject", .message = "nope", .match = .{ .command = "chmod" } },
    };
    const sources = [_]config_mod.RuleSource{ .project, .global };

    {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const exit_code = try run(std.testing.allocator, &rules, &sources, .{ .command = "pytest tests/" }, stream.writer());
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expectEqualStrings("REWRITE\t0\tpytest tests/\tp-rewrite\tjust test\tproject\n", stream.getWritten());
    }

    {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const exit_code = try run(std.testing.allocator, &rules, &sources, .{ .command = "chmod 777 foo" }, stream.writer());
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        try std.testing.expectEqualStrings("REJECT\t2\tchmod 777 foo\tg-reject\tnope\tglobal\n", stream.getWritten());
    }

    {
        var buf: [512]u8 = undefined;
        var stream = std.io.fixedBufferStream(&buf);
        const exit_code = try run(std.testing.allocator, &rules, &sources, .{ .command = "ls -la" }, stream.writer());
        try std.testing.expectEqual(@as(u8, 0), exit_code);
        // ALLOW: 6 columns total when sources are provided; the 6th is empty
        // because no rule matched. That's 5 tabs.
        try std.testing.expectEqualStrings("ALLOW\t0\tls -la\t\t\t\n", stream.getWritten());
    }
}
