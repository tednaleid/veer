// ABOUTME: The veer check command -- the hot-path hook called by Claude Code.
// ABOUTME: Reads hook JSON from stdin (PreToolUse or Stop), evaluates rules, outputs the result.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const engine = @import("../engine/engine.zig");
const hook = @import("../claude/hook.zig");
const chars = @import("../engine/chars.zig");
const Action = @import("../config/rule.zig").Action;
const Rule = @import("../config/rule.zig").Rule;

/// Run the check command. Returns exit code.
/// Takes reader/writer interfaces for testability.
///
/// When verbose is true, allow and rewrite paths emit a `systemMessage` field
/// so the user sees each tool call in Claude Code's transcript. The LLM's
/// context is not affected either way. The reject path is unchanged.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    rules: []const Rule,
    root: ?[]const u8,
    home: ?[]const u8,
    stdin_data: []const u8,
    stdout_writer: anytype,
    stderr_writer: anytype,
    verbose: bool,
) !u8 {
    // Parse hook input
    var input = hook.parseInput(allocator, io, stdin_data) catch |err| switch (err) {
        error.UnsupportedEvent => return hook.ExitCode.allow,
        else => {
            try stderr_writer.print("veer: invalid JSON input\n", .{});
            return 1;
        },
    };
    defer hook.freeInput(allocator, &input);

    // A Stop hook fires again after Claude answers its feedback. Correct a
    // reply once; a second miss in a row allows, so a misfiring rule cannot
    // loop.
    if (input.event == .Stop and input.stop_hook_active) return hook.ExitCode.allow;

    const result = engine.check(allocator, rules, .{
        .tool_name = input.tool_name,
        .command = input.command,
        .content = input.content,
        .file_path = input.file_path,
        .cwd = input.cwd,
        .root = root,
        .home = home,
        .event = input.event,
        .content_format = input.content_format,
    });

    // Output based on action
    if (result.action) |action| {
        switch (action) {
            .rewrite => {
                if (result.rewrite_to) |target| {
                    const rewritten = spliceRewrite(allocator, input.command, target, result.match_start, result.match_end);
                    defer if (rewritten.allocated) allocator.free(rewritten.command);
                    const system_msg: ?[]u8 = if (verbose)
                        try buildToolSummary(allocator, input.command, rewritten.command)
                    else
                        null;
                    defer if (system_msg) |m| allocator.free(m);
                    try hook.formatRewrite(stdout_writer, rewritten.command, system_msg, result.rule_id);
                }
                return hook.ExitCode.rewrite;
            },
            // engine.check never returns .allow here: a gate that passes
            // falls through to the next rule, and a gate that fails is
            // reported as .reject. This arm exists only for exhaustiveness.
            .reject, .allow => {
                const rid = result.rule_id orelse "";
                const msg = result.message orelse "";
                if (input.event == .Stop) {
                    var feedback: std.Io.Writer.Allocating = .init(allocator);
                    defer feedback.deinit();
                    try feedback.writer.print("[{s}] {s}\n", .{ rid, msg });
                    try writeHitsFor(allocator, &feedback.writer, result, input);
                    try hook.formatStopFeedback(stdout_writer, rid, feedback.written());
                    return hook.ExitCode.allow;
                }
                if (result.message != null) {
                    if (result.rule_id != null) {
                        try stderr_writer.print("[{s}] {s}\n", .{ rid, msg });
                    } else {
                        try stderr_writer.print("{s}\n", .{msg});
                    }
                }
                try writeHitsFor(allocator, stderr_writer, result, input);
                // Emit a stdout marker so the transcript's hook_success
                // record carries rule_id attribution. Claude Code captures
                // stdout on exit 2 even though it doesn't act on it.
                if (result.rule_id) |r| {
                    try hook.formatRejectMarker(stdout_writer, r);
                }
                return hook.ExitCode.reject;
            },
        }
    }

    // No match: allow. In verbose mode, emit a banner IF we have content worth
    // showing. Claude Code already prefixes every systemMessage with
    // "PreToolUse:<ToolName> says: ", so a non-Bash tool (no command to show)
    // would render as just that prefix with nothing after it -- pure noise.
    // Non-verbose installs stay byte-for-byte silent as before.
    if (verbose) {
        if (try buildToolSummary(allocator, input.command, null)) |msg| {
            defer allocator.free(msg);
            try hook.formatAllow(stdout_writer, msg, null);
        }
    }
    return hook.ExitCode.allow;
}

const max_listed_hits = 5;

/// List the character-class hits behind a reject, when the matched rule
/// has content_chars.
fn writeHitsFor(allocator: std.mem.Allocator, writer: anytype, result: engine.CheckResult, input: hook.HookInput) !void {
    const names = result.content_chars orelse return;
    const content = input.content orelse return;
    try chars.writeHits(allocator, writer, content, input.content_format, names, max_listed_hits);
}

/// Build the user-visible banner text for a Bash tool call.
/// Claude Code's transcript already shows "PreToolUse:<ToolName> says: " as a
/// prefix, so the banner is just the command (and the rewrite target, if any):
///   Bash allow:    "`pytest tests/`"
///   Bash rewrite:  "`pytest tests/` -> `just test`"
///   Non-Bash:      null (caller skips the banner entirely)
/// Caller owns the returned slice when non-null.
fn buildToolSummary(
    allocator: std.mem.Allocator,
    command: ?[]const u8,
    rewrite_to: ?[]const u8,
) !?[]u8 {
    const cmd = command orelse return null;
    if (rewrite_to) |target| {
        return try std.fmt.allocPrint(allocator, "`{s}` -> `{s}`", .{ cmd, target });
    }
    return try std.fmt.allocPrint(allocator, "`{s}`", .{cmd});
}

const SpliceResult = struct {
    command: []const u8,
    allocated: bool,
};

/// Splice rewrite_to into the original command at the matched byte range.
/// If no byte range (cross-command match), returns rewrite_to as-is.
fn spliceRewrite(allocator: std.mem.Allocator, raw_command: ?[]const u8, rewrite_to: []const u8, match_start: ?u32, match_end: ?u32) SpliceResult {
    const raw = raw_command orelse return .{ .command = rewrite_to, .allocated = false };
    const start = match_start orelse return .{ .command = rewrite_to, .allocated = false };
    const end = match_end orelse return .{ .command = rewrite_to, .allocated = false };

    if (start == 0 and end >= raw.len) {
        // Matched the entire command -- no splicing needed
        return .{ .command = rewrite_to, .allocated = false };
    }

    // Surgical splice: raw[0..start] ++ rewrite_to ++ raw[end..]
    const new_len = start + rewrite_to.len + (raw.len - end);
    const buf = allocator.alloc(u8, new_len) catch return .{ .command = rewrite_to, .allocated = false };
    @memcpy(buf[0..start], raw[0..start]);
    @memcpy(buf[start..][0..rewrite_to.len], rewrite_to);
    @memcpy(buf[start + rewrite_to.len ..], raw[end..]);
    return .{ .command = buf, .allocated = true };
}

// -- Tests --

test "end-to-end: rewrite rule returns updatedInput on stdout" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"pytest tests/ -v"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        false,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const stdout_output = stdout_stream.buffered();
    // Verify it's valid JSON with hookSpecificOutput.updatedInput (modern envelope).
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stdout_output, .{});
    defer parsed.deinit();
    const hso = parsed.value.object.get("hookSpecificOutput").?;
    try std.testing.expectEqualStrings("PreToolUse", hso.object.get("hookEventName").?.string);
    try std.testing.expectEqualStrings("allow", hso.object.get("permissionDecision").?.string);
    const cmd = hso.object.get("updatedInput").?.object.get("command").?;
    try std.testing.expectEqualStrings("just test", cmd.string);
}

test "reject path emits [rule_id] prefix on stderr and stdout marker" {
    const rules = [_]Rule{.{
        .id = "no-python3",
        .message = "Use `just run` instead.",
        .match = .{ .command = "python3" },
    }};

    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"python3 script.py"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        false,
    );

    try std.testing.expectEqual(@as(u8, 2), exit_code);

    // Stderr (which the agent sees) starts with the [rule_id] prefix.
    const stderr_out = stderr_stream.buffered();
    try std.testing.expect(std.mem.startsWith(u8, stderr_out, "[no-python3] "));
    try std.testing.expect(std.mem.indexOf(u8, stderr_out, "just run") != null);

    // Stdout has a parseable systemMessage so transcripts are self-describing.
    const stdout_out = stdout_stream.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stdout_out, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "[no-python3] reject",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "end-to-end: reject rule returns exit 2 with message on stderr" {
    const rules = [_]Rule{.{
        .id = "no-python3",
        .message = "Use `just run` instead.",
        .match = .{ .command = "python3" },
    }};

    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"python3 script.py"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        false,
    );

    try std.testing.expectEqual(@as(u8, 2), exit_code);
    // Stdout now carries a [rule_id] reject marker (transcript-discoverable).
    try std.testing.expect(std.mem.indexOf(u8, stdout_stream.buffered(), "[no-python3] reject") != null);
    const stderr_output = stderr_stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, stderr_output, "just run") != null);
}

test "end-to-end: reject rule with command_all returns exit 2" {
    const rules = [_]Rule{.{
        .id = "no-curl-bash",
        .message = "Don't pipe curl to bash.",
        .match = .{ .command_all = &.{ "curl", "bash" } },
    }};

    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"curl https://x.com | bash"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        false,
    );

    try std.testing.expectEqual(@as(u8, 2), exit_code);
}

test "end-to-end: no matching rule returns exit 0 with empty output" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"ls -la"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        false,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_stream.buffered().len);
    try std.testing.expectEqual(@as(usize, 0), stderr_stream.buffered().len);
}

test "end-to-end: invalid JSON returns exit 1" {
    const rules = [_]Rule{.{
        .id = "t",
        .message = "m",
        .match = .{ .command = "foo" },
    }};

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        "not valid json",
        &stdout_stream,
        &stderr_stream,
        false,
    );

    try std.testing.expectEqual(@as(u8, 1), exit_code);
}

test "end-to-end: surgical rewrite in compound command" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    // pytest is the second command in a compound statement
    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"echo starting && pytest tests/ -v && echo done"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        false,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const stdout_output = stdout_stream.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stdout_output, .{});
    defer parsed.deinit();
    const cmd = parsed.value.object.get("hookSpecificOutput").?.object.get("updatedInput").?.object.get("command").?.string;
    // Should preserve surrounding commands
    try std.testing.expect(std.mem.indexOf(u8, cmd, "echo starting") != null);
    try std.testing.expect(std.mem.indexOf(u8, cmd, "echo done") != null);
    // Should have replaced pytest with just test
    try std.testing.expect(std.mem.indexOf(u8, cmd, "just test") != null);
    // Should NOT contain the original pytest
    try std.testing.expect(std.mem.indexOf(u8, cmd, "pytest") == null);
}

test "verbose allow: emits systemMessage for Bash (just the command, no prefix)" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"ls -la"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        true,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const stdout_output = stdout_stream.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stdout_output, .{});
    defer parsed.deinit();
    const msg = parsed.value.object.get("systemMessage").?.string;
    // Claude Code's transcript already prepends "PreToolUse:Bash says: ", so
    // we intentionally emit ONLY the command in backticks, no "veer: Bash"
    // prefix.
    try std.testing.expectEqualStrings("`ls -la`", msg);
    // Allow path: no decision fields, just the banner. Claude Code falls through
    // to its default "allow" behavior when no hookSpecificOutput is present.
    try std.testing.expect(parsed.value.object.get("hookSpecificOutput") == null);
    try std.testing.expect(parsed.value.object.get("updatedInput") == null);
}

test "verbose allow: non-Bash tool emits no banner (empty stdout)" {
    const rules = [_]Rule{};

    const input =
        \\{"tool_name":"Read","tool_input":{"file_path":"/etc/hosts"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        true,
    );

    // Non-Bash tools have no interesting content to show beyond the tool name,
    // which Claude Code's transcript already includes. Skip the banner entirely.
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_stream.buffered().len);
}

test "verbose rewrite: emits systemMessage alongside updatedInput" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"pytest tests/ -v"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        true,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stdout_stream.buffered(), .{});
    defer parsed.deinit();

    const msg = parsed.value.object.get("systemMessage").?.string;
    // Banner is "[<rule_id>] `<original>` -> `<rewritten>`" -- the rule_id
    // prefix makes the transcript self-describing for `veer stats`.
    try std.testing.expectEqualStrings("[use-just-test] `pytest tests/ -v` -> `just test`", msg);

    const hso = parsed.value.object.get("hookSpecificOutput").?;
    try std.testing.expectEqualStrings("PreToolUse", hso.object.get("hookEventName").?.string);
    try std.testing.expectEqualStrings("allow", hso.object.get("permissionDecision").?.string);
    const cmd = hso.object.get("updatedInput").?.object.get("command").?.string;
    try std.testing.expectEqualStrings("just test", cmd);
}

test "end-to-end: ExitPlanMode rejected when plan contains 'actually'" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);

    const plan_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plan.md", .{tmp_root});
    defer std.testing.allocator.free(plan_path);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, plan_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "# Plan\n\nFirst we do X. Actually, let's do Y instead.\n");
    }

    const transcript_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/session.jsonl", .{tmp_root});
    defer std.testing.allocator.free(transcript_path);
    const transcript_line = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"attachment\":{{\"type\":\"plan_mode\",\"planFilePath\":\"{s}\"}},\"type\":\"attachment\"}}\n",
        .{plan_path},
    );
    defer std.testing.allocator.free(transcript_line);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, transcript_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, transcript_line);
    }

    const rules = [_]Rule{.{
        .id = "no-actually-in-plans",
        .tool = "ExitPlanMode",
        .message = "Plans must not contain 'actually'.",
        .match = .{ .content_regex = "[Aa]ctually" },
    }};

    const input = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"tool_name\":\"ExitPlanMode\",\"tool_input\":{{}},\"transcript_path\":\"{s}\"}}",
        .{transcript_path},
    );
    defer std.testing.allocator.free(input);

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        false,
    );

    try std.testing.expectEqual(@as(u8, 2), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stderr_stream.buffered(), "actually") != null);
}

test "end-to-end: ExitPlanMode allowed when plan is clean" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);

    const plan_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plan.md", .{tmp_root});
    defer std.testing.allocator.free(plan_path);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, plan_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "# Plan\n\nStep 1: do X. Step 2: do Y.\n");
    }

    const transcript_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/session.jsonl", .{tmp_root});
    defer std.testing.allocator.free(transcript_path);
    const transcript_line = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"attachment\":{{\"type\":\"plan_mode\",\"planFilePath\":\"{s}\"}},\"type\":\"attachment\"}}\n",
        .{plan_path},
    );
    defer std.testing.allocator.free(transcript_line);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, transcript_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, transcript_line);
    }

    const rules = [_]Rule{.{
        .id = "no-actually-in-plans",
        .tool = "ExitPlanMode",
        .message = "Plans must not contain 'actually'.",
        .match = .{ .content_regex = "[Aa]ctually" },
    }};

    const input = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"tool_name\":\"ExitPlanMode\",\"tool_input\":{{}},\"transcript_path\":\"{s}\"}}",
        .{transcript_path},
    );
    defer std.testing.allocator.free(input);

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        false,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stderr_stream.buffered().len);
}

test "verbose reject: same shape as non-verbose (exit 2, stderr msg, stdout marker)" {
    const rules = [_]Rule{.{
        .id = "no-python3",
        .message = "Use `just run` instead.",
        .match = .{ .command = "python3" },
    }};

    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"python3 script.py"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        std.testing.io,
        &rules,
        null,
        null,
        input,
        &stdout_stream,
        &stderr_stream,
        true,
    );

    // Reject emits the [rule_id] marker on stdout regardless of verbose.
    // The marker makes the transcript self-describing for `veer stats`.
    try std.testing.expectEqual(@as(u8, 2), exit_code);
    try std.testing.expect(std.mem.indexOf(u8, stdout_stream.buffered(), "[no-python3] reject") != null);
    try std.testing.expect(std.mem.indexOf(u8, stderr_stream.buffered(), "just run") != null);
    try std.testing.expect(std.mem.startsWith(u8, stderr_stream.buffered(), "[no-python3] "));
}

const RunOutput = struct {
    code: u8,
    stdout_buf: [2048]u8 = undefined,
    stderr_buf: [2048]u8 = undefined,
    stdout_len: usize = 0,
    stderr_len: usize = 0,

    fn stdout(self: *const RunOutput) []const u8 {
        return self.stdout_buf[0..self.stdout_len];
    }
    fn stderr(self: *const RunOutput) []const u8 {
        return self.stderr_buf[0..self.stderr_len];
    }
};

fn runForTest(rules: []const Rule, input: []const u8) !RunOutput {
    var out = RunOutput{ .code = 0 };
    var stdout_stream = std.Io.Writer.fixed(&out.stdout_buf);
    var stderr_stream = std.Io.Writer.fixed(&out.stderr_buf);
    out.code = try run(std.testing.allocator, std.testing.io, rules, null, null, input, &stdout_stream, &stderr_stream, false);
    out.stdout_len = stdout_stream.buffered().len;
    out.stderr_len = stderr_stream.buffered().len;
    return out;
}

const emoji_classes: []const []const u8 = &.{ "emoji", "status_markers" };

test "Stop reject returns additionalContext with hits and exit 0" {
    const rules = [_]Rule{.{
        .id = "no-emoji-in-replies",
        .event = .Stop,
        .message = "Restate without emoji.",
        .match = .{ .content_chars = emoji_classes },
    }};
    const out = try runForTest(&rules,
        \\{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ok\n\u2705 done"}
    );
    try std.testing.expectEqual(@as(u8, 0), out.code);
    try std.testing.expectEqual(@as(usize, 0), out.stderr().len);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.stdout(), .{});
    defer parsed.deinit();
    const ctx = parsed.value.object.get("hookSpecificOutput").?.object.get("additionalContext").?.string;
    try std.testing.expect(std.mem.startsWith(u8, ctx, "[no-emoji-in-replies] Restate without emoji.\n"));
    try std.testing.expect(std.mem.indexOf(u8, ctx, "line 2: U+2705") != null);
}

test "Stop with stop_hook_active allows without evaluating" {
    const rules = [_]Rule{.{ .id = "r", .event = .Stop, .message = "m", .match = .{ .content_chars = emoji_classes } }};
    const out = try runForTest(&rules,
        \\{"hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"\u2705"}
    );
    try std.testing.expectEqual(@as(u8, 0), out.code);
    try std.testing.expectEqual(@as(usize, 0), out.stdout().len);
}

test "Stop with no Stop rules and unsupported events allow silently" {
    const rules = [_]Rule{.{ .id = "r", .tool = "*", .message = "m", .match = .{ .content_chars = emoji_classes } }};
    const inputs = .{
        \\{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"\u2705"}
        ,
        \\{"hook_event_name":"MessageDisplay","delta":"\u2705","index":0,"final":true}
        ,
    };
    inline for (inputs) |input| {
        const out = try runForTest(&rules, input);
        try std.testing.expectEqual(@as(u8, 0), out.code);
        try std.testing.expectEqual(@as(usize, 0), out.stdout().len);
        try std.testing.expectEqual(@as(usize, 0), out.stderr().len);
    }
}

test "PreToolUse content_chars reject lists hits on stderr" {
    const rules = [_]Rule{.{ .id = "no-emoji", .tool = "*", .message = "No emoji.", .match = .{ .content_chars = emoji_classes } }};
    const out = try runForTest(&rules,
        \\{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.md","content":"a\n\u2713 b"}}
    );
    try std.testing.expectEqual(@as(u8, 2), out.code);
    try std.testing.expect(std.mem.startsWith(u8, out.stderr(), "[no-emoji] No emoji.\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.stderr(), "line 2: U+2713") != null);
}
