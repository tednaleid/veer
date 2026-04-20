// ABOUTME: The veer check command -- the hot-path hook called by Claude Code.
// ABOUTME: Reads JSON from stdin, evaluates against rules, outputs result.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const engine = @import("../engine/engine.zig");
const hook = @import("../claude/hook.zig");
const Action = @import("../config/rule.zig").Action;
const Rule = @import("../config/rule.zig").Rule;
const Store = @import("../store/store.zig").Store;

/// Run the check command. Returns exit code.
/// Takes reader/writer interfaces for testability.
///
/// When verbose is true, allow and rewrite paths emit a `systemMessage` field
/// so the user sees each tool call in Claude Code's transcript. The LLM's
/// context is not affected either way. The reject path is unchanged.
pub fn run(
    allocator: std.mem.Allocator,
    rules: []const Rule,
    stdin_data: []const u8,
    store: ?Store,
    stdout_writer: anytype,
    stderr_writer: anytype,
    verbose: bool,
) !u8 {
    // Parse hook input
    var input = hook.parseInput(allocator, stdin_data) catch {
        try stderr_writer.print("veer: invalid JSON input\n", .{});
        return 1;
    };
    defer hook.freeInput(allocator, &input);

    const result = engine.check(allocator, rules, input.tool_name, input.command, store);

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
                    try hook.formatRewrite(stdout_writer, rewritten.command, system_msg);
                }
                return hook.ExitCode.rewrite;
            },
            .reject => {
                if (result.message) |msg| {
                    try stderr_writer.print("{s}\n", .{msg});
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
            try hook.formatAllow(stdout_writer, msg);
        }
    }
    return hook.ExitCode.allow;
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
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        input,
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
        false,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);

    const stdout_output = stdout_stream.getWritten();
    // Verify it's valid JSON with hookSpecificOutput.updatedInput (modern envelope).
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stdout_output, .{});
    defer parsed.deinit();
    const hso = parsed.value.object.get("hookSpecificOutput").?;
    try std.testing.expectEqualStrings("PreToolUse", hso.object.get("hookEventName").?.string);
    try std.testing.expectEqualStrings("allow", hso.object.get("permissionDecision").?.string);
    const cmd = hso.object.get("updatedInput").?.object.get("command").?;
    try std.testing.expectEqualStrings("just test", cmd.string);
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
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        input,
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
        false,
    );

    try std.testing.expectEqual(@as(u8, 2), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_stream.getWritten().len);
    const stderr_output = stderr_stream.getWritten();
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
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        input,
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
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
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        input,
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
        false,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_stream.getWritten().len);
    try std.testing.expectEqual(@as(usize, 0), stderr_stream.getWritten().len);
}

test "end-to-end: invalid JSON returns exit 1" {
    const rules = [_]Rule{.{
        .id = "t",
        .message = "m",
        .match = .{ .command = "foo" },
    }};

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        "not valid json",
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
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
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        input,
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
        false,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const stdout_output = stdout_stream.getWritten();
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
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        input,
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
        true,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const stdout_output = stdout_stream.getWritten();
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
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        input,
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
        true,
    );

    // Non-Bash tools have no interesting content to show beyond the tool name,
    // which Claude Code's transcript already includes. Skip the banner entirely.
    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_stream.getWritten().len);
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
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        input,
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
        true,
    );

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, stdout_stream.getWritten(), .{});
    defer parsed.deinit();

    const msg = parsed.value.object.get("systemMessage").?.string;
    // Banner is "`<original>` -> `<rewritten>`" with no "veer: Bash" prefix
    // (Claude Code's transcript prepends the tool identifier).
    try std.testing.expectEqualStrings("`pytest tests/ -v` -> `just test`", msg);

    const hso = parsed.value.object.get("hookSpecificOutput").?;
    try std.testing.expectEqualStrings("PreToolUse", hso.object.get("hookEventName").?.string);
    try std.testing.expectEqualStrings("allow", hso.object.get("permissionDecision").?.string);
    const cmd = hso.object.get("updatedInput").?.object.get("command").?.string;
    try std.testing.expectEqualStrings("just test", cmd);
}

test "verbose reject: unchanged (exit 2, stderr message, no stdout)" {
    const rules = [_]Rule{.{
        .id = "no-python3",
        .message = "Use `just run` instead.",
        .match = .{ .command = "python3" },
    }};

    const input =
        \\{"tool_name":"Bash","tool_input":{"command":"python3 script.py"}}
    ;

    var stdout_buf: [512]u8 = undefined;
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [512]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = try run(
        std.testing.allocator,
        &rules,
        input,
        null,
        stdout_stream.writer(),
        stderr_stream.writer(),
        true,
    );

    // Reject path does not emit a systemMessage (would be ignored on exit 2 anyway).
    try std.testing.expectEqual(@as(u8, 2), exit_code);
    try std.testing.expectEqual(@as(usize, 0), stdout_stream.getWritten().len);
    try std.testing.expect(std.mem.indexOf(u8, stderr_stream.getWritten(), "just run") != null);
}
