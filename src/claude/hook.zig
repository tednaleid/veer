// ABOUTME: Claude Code PreToolUse hook protocol implementation.
// ABOUTME: Parses stdin JSON and formats output per the hook contract.

const std = @import("std");
const transcript = @import("transcript.zig");

pub const HookInput = struct {
    tool_name: []const u8,
    command: ?[]const u8, // Extracted from tool_input.command for Bash tools
    session_id: ?[]const u8,
    transcript_path: ?[]const u8,
    /// Tool-specific text content for content_regex / content_contains
    /// matching. For ExitPlanMode, this is the resolved plan file body. Null
    /// for tools where no content extractor is wired up (or where extraction
    /// failed -- callers must treat null as "no match" rather than "match").
    content: ?[]const u8,
};

pub const ExitCode = struct {
    pub const allow: u8 = 0;
    pub const rewrite: u8 = 0;
    pub const reject: u8 = 2;
};

/// Parse hook input from a JSON string (read from stdin).
/// Extracts tool_name and command (for Bash tools) from the JSON.
/// For ExitPlanMode, also resolves the plan file content via the transcript.
pub fn parseInput(allocator: std.mem.Allocator, json_str: []const u8) !HookInput {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidInput;

    const tool_name = blk: {
        const val = root.object.get("tool_name") orelse return error.InvalidInput;
        if (val != .string) return error.InvalidInput;
        break :blk try allocator.dupe(u8, val.string);
    };
    errdefer allocator.free(tool_name);

    const command: ?[]const u8 = blk: {
        const tool_input = root.object.get("tool_input") orelse break :blk null;
        if (tool_input != .object) break :blk null;
        const cmd_val = tool_input.object.get("command") orelse break :blk null;
        if (cmd_val != .string) break :blk null;
        break :blk try allocator.dupe(u8, cmd_val.string);
    };
    errdefer if (command) |cmd| allocator.free(cmd);

    const session_id: ?[]const u8 = blk: {
        const val = root.object.get("session_id") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk try allocator.dupe(u8, val.string);
    };
    errdefer if (session_id) |sid| allocator.free(sid);

    const transcript_path: ?[]const u8 = blk: {
        const val = root.object.get("transcript_path") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk try allocator.dupe(u8, val.string);
    };
    errdefer if (transcript_path) |tp| allocator.free(tp);

    // Tool-specific content extraction. Fail-open: any error producing
    // content yields null, which the engine treats as "rule does not match"
    // for content rules. We don't want a transient FS or parse glitch to
    // block the agent from making progress.
    const content: ?[]const u8 = if (std.mem.eql(u8, tool_name, "ExitPlanMode")) blk: {
        const tp = transcript_path orelse break :blk null;
        break :blk resolveExitPlanModeContent(allocator, tp) catch null;
    } else null;

    return .{
        .tool_name = tool_name,
        .command = command,
        .session_id = session_id,
        .transcript_path = transcript_path,
        .content = content,
    };
}

/// Read the transcript at `transcript_path`, locate the most recent
/// plan_mode attachment, then read and return that plan file's contents.
/// Returns null on any I/O or parse failure.
fn resolveExitPlanModeContent(allocator: std.mem.Allocator, transcript_path: []const u8) !?[]u8 {
    const transcript_content = readFileBounded(allocator, transcript_path, 64 * 1024 * 1024) catch return null;
    defer allocator.free(transcript_content);

    const plan_path_opt = transcript.findLatestPlanFilePath(allocator, transcript_content) catch null;
    const plan_path = plan_path_opt orelse return null;
    defer allocator.free(plan_path);

    return readFileBounded(allocator, plan_path, 4 * 1024 * 1024) catch null;
}

fn readFileBounded(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, max_bytes);
}

/// Free a HookInput's owned strings.
pub fn freeInput(allocator: std.mem.Allocator, input: *HookInput) void {
    allocator.free(input.tool_name);
    if (input.command) |cmd| allocator.free(cmd);
    if (input.session_id) |sid| allocator.free(sid);
    if (input.transcript_path) |tp| allocator.free(tp);
    if (input.content) |c| allocator.free(c);
}

/// Format a rewrite result for stdout using the modern hook response envelope.
/// Claude Code expects `updatedInput` under `hookSpecificOutput` with an
/// explicit `permissionDecision: "allow"` to actually apply the rewrite; the
/// legacy top-level `updatedInput` is NOT honored (the decision path ignores
/// it, even though the display path still reads the banner). See
/// https://code.claude.com/docs/en/hooks for the schema.
///
/// Base output:
///   {"hookSpecificOutput":{"hookEventName":"PreToolUse",
///    "permissionDecision":"allow","updatedInput":{"command":"<rewrite_to>"}}}
///
/// When system_message is non-null, a top-level `systemMessage` is prepended
/// so the user sees the transformation in the transcript (the LLM does not):
///   {"systemMessage":"...","hookSpecificOutput":{...}}
///
/// When rule_id is non-null, the systemMessage is prefixed with `[<rule_id>] `
/// so the transcript is self-describing -- downstream tools (`veer stats`)
/// parse this prefix to attribute hook fires to specific rules. If
/// system_message is null, rule_id is ignored (no banner to prefix).
pub fn formatRewrite(writer: anytype, rewrite_to: []const u8, system_message: ?[]const u8, rule_id: ?[]const u8) !void {
    try writer.writeAll("{");
    if (system_message) |msg| {
        try writer.writeAll("\"systemMessage\":");
        try writePrefixedJsonString(writer, msg, rule_id);
        try writer.writeAll(",");
    }
    try writer.writeAll("\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",");
    try writer.writeAll("\"permissionDecision\":\"allow\",");
    try writer.writeAll("\"updatedInput\":{\"command\":");
    try writeJsonString(writer, rewrite_to);
    try writer.writeAll("}}}");
}

/// Format an allow result for stdout. Only emitted when verbose mode is on;
/// non-verbose allow writes nothing.
/// Output: {"systemMessage":"[<rule_id>] <message>"} if rule_id set,
///         {"systemMessage":"<message>"} otherwise.
pub fn formatAllow(writer: anytype, system_message: []const u8, rule_id: ?[]const u8) !void {
    try writer.writeAll("{\"systemMessage\":");
    try writePrefixedJsonString(writer, system_message, rule_id);
    try writer.writeAll("}");
}

/// Format a reject systemMessage for stdout (paired with stderr message).
/// Even on exit 2, Claude Code captures stdout into the transcript's
/// hook_success record, so emitting a marker line keeps rejects discoverable
/// via the same `[<rule_id>] ` prefix grammar as allows/rewrites.
/// Output: {"systemMessage":"[<rule_id>] reject"}
pub fn formatRejectMarker(writer: anytype, rule_id: []const u8) !void {
    try writer.writeAll("{\"systemMessage\":\"[");
    try writeJsonEscaped(writer, rule_id);
    try writer.writeAll("] reject\"}");
}

/// Write a JSON string (with surrounding quotes), optionally prefixed by
/// `[<rule_id>] `. Used so the prefix lands inside the JSON-quoted form.
fn writePrefixedJsonString(writer: anytype, str: []const u8, rule_id: ?[]const u8) !void {
    if (rule_id) |id| {
        try writer.writeByte('"');
        try writer.writeByte('[');
        try writeJsonEscaped(writer, id);
        try writer.writeAll("] ");
        try writeJsonEscaped(writer, str);
        try writer.writeByte('"');
    } else {
        try writeJsonString(writer, str);
    }
}

/// Write a JSON-encoded string (including surrounding quotes).
/// Escapes the characters JSON requires: `"`, `\`, and control chars < 0x20.
fn writeJsonString(writer: anytype, str: []const u8) !void {
    try writer.writeByte('"');
    try writeJsonEscaped(writer, str);
    try writer.writeByte('"');
}

/// Write JSON-escaped chars only (no surrounding quotes). Lets callers
/// concatenate multiple escaped fragments inside a single quoted string.
fn writeJsonEscaped(writer: anytype, str: []const u8) !void {
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            8 => try writer.writeAll("\\b"),
            12 => try writer.writeAll("\\f"),
            0...7, 11, 14...31 => try writer.print("\\u{x:0>4}", .{@as(u16, c)}),
            else => try writer.writeByte(c),
        }
    }
}

// -- Tests --

test "parseInput Bash tool with command" {
    const json =
        \\{"tool_name":"Bash","tool_input":{"command":"pytest tests/"},"session_id":"abc-123"}
    ;
    var input = try parseInput(std.testing.allocator, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("Bash", input.tool_name);
    try std.testing.expectEqualStrings("pytest tests/", input.command.?);
    try std.testing.expectEqualStrings("abc-123", input.session_id.?);
}

test "parseInput non-Bash tool" {
    const json =
        \\{"tool_name":"Write","tool_input":{"file_path":"/etc/passwd","content":"..."}}
    ;
    var input = try parseInput(std.testing.allocator, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("Write", input.tool_name);
    try std.testing.expect(input.command == null);
    try std.testing.expect(input.content == null);
}

test "parseInput extracts transcript_path" {
    const json =
        \\{"tool_name":"Bash","tool_input":{"command":"ls"},"transcript_path":"/tmp/session.jsonl"}
    ;
    var input = try parseInput(std.testing.allocator, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("/tmp/session.jsonl", input.transcript_path.?);
    // Bash tool: content is not extracted regardless of transcript_path
    try std.testing.expect(input.content == null);
}

test "parseInput resolves ExitPlanMode plan content from transcript" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);

    // Write a fake plan file
    const plan_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plan.md", .{tmp_root});
    defer std.testing.allocator.free(plan_path);
    {
        const f = try std.fs.cwd().createFile(plan_path, .{});
        defer f.close();
        try f.writeAll("# Plan\n\nWe will do X but actually let's do Y.\n");
    }

    // Write a transcript that references that plan path
    const transcript_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/session.jsonl", .{tmp_root});
    defer std.testing.allocator.free(transcript_path);
    const transcript_line = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"attachment\":{{\"type\":\"plan_mode\",\"planFilePath\":\"{s}\"}},\"type\":\"attachment\"}}\n",
        .{plan_path},
    );
    defer std.testing.allocator.free(transcript_line);
    {
        const f = try std.fs.cwd().createFile(transcript_path, .{});
        defer f.close();
        try f.writeAll(transcript_line);
    }

    // Build the hook input pointing at our fake transcript
    const json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"tool_name\":\"ExitPlanMode\",\"tool_input\":{{}},\"transcript_path\":\"{s}\"}}",
        .{transcript_path},
    );
    defer std.testing.allocator.free(json);

    var input = try parseInput(std.testing.allocator, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("ExitPlanMode", input.tool_name);
    try std.testing.expect(input.content != null);
    try std.testing.expect(std.mem.indexOf(u8, input.content.?, "actually") != null);
}

test "parseInput ExitPlanMode with missing transcript_path leaves content null" {
    const json =
        \\{"tool_name":"ExitPlanMode","tool_input":{}}
    ;
    var input = try parseInput(std.testing.allocator, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("ExitPlanMode", input.tool_name);
    try std.testing.expect(input.content == null);
}

test "parseInput ExitPlanMode with non-existent transcript path leaves content null" {
    const json =
        \\{"tool_name":"ExitPlanMode","tool_input":{},"transcript_path":"/nonexistent/transcript.jsonl"}
    ;
    var input = try parseInput(std.testing.allocator, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expect(input.content == null);
    try std.testing.expectEqualStrings("/nonexistent/transcript.jsonl", input.transcript_path.?);
}

test "parseInput missing tool_name fails" {
    const json =
        \\{"tool_input":{"command":"ls"}}
    ;
    try std.testing.expectError(error.InvalidInput, parseInput(std.testing.allocator, json));
}

test "parseInput invalid JSON fails" {
    try std.testing.expectError(error.SyntaxError, parseInput(std.testing.allocator, "not json{{{"));
}

test "formatRewrite produces modern hookSpecificOutput envelope" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatRewrite(stream.writer(), "just test", null, null);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings(
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\"," ++
            "\"permissionDecision\":\"allow\"," ++
            "\"updatedInput\":{\"command\":\"just test\"}}}",
        output,
    );
}

test "formatRewrite with systemMessage prepends top-level field" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatRewrite(stream.writer(), "just test", "`pytest` -> `just test`", null);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings(
        "{\"systemMessage\":\"`pytest` -> `just test`\"," ++
            "\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\"," ++
            "\"permissionDecision\":\"allow\"," ++
            "\"updatedInput\":{\"command\":\"just test\"}}}",
        output,
    );
}

test "formatRewrite escapes quotes and backslashes in both fields" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    // Both fields must be escaped; otherwise a command containing `"` or `\`
    // would produce invalid JSON.
    try formatRewrite(stream.writer(), "echo \"hi\"", "`x\\y`", null);
    const output = stream.getWritten();
    // Output must be valid JSON, and updatedInput.command must round-trip.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "echo \"hi\"",
        parsed.value.object.get("hookSpecificOutput").?.object.get("updatedInput").?.object.get("command").?.string,
    );
    try std.testing.expectEqualStrings(
        "`x\\y`",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "formatAllow produces systemMessage-only JSON" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatAllow(stream.writer(), "veer: Read", null);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings("{\"systemMessage\":\"veer: Read\"}", output);
}

test "formatAllow escapes control characters" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatAllow(stream.writer(), "veer: Bash `echo\nhi`", null);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings("{\"systemMessage\":\"veer: Bash `echo\\nhi`\"}", output);
    // Parse round-trip.
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "veer: Bash `echo\nhi`",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "formatRewrite with rule_id prefixes systemMessage" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatRewrite(stream.writer(), "just test", "`pytest` -> `just test`", "use-just-test");
    const output = stream.getWritten();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "[use-just-test] `pytest` -> `just test`",
        parsed.value.object.get("systemMessage").?.string,
    );
    // Rewrite envelope unchanged.
    const cmd = parsed.value.object.get("hookSpecificOutput").?.object.get("updatedInput").?.object.get("command").?.string;
    try std.testing.expectEqualStrings("just test", cmd);
}

test "formatRewrite with null rule_id leaves systemMessage unprefixed" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatRewrite(stream.writer(), "just test", "`pytest` -> `just test`", null);
    const output = stream.getWritten();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "`pytest` -> `just test`",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "formatAllow with rule_id prefixes message" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatAllow(stream.writer(), "`ls -la`", "use-just-test");
    const output = stream.getWritten();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "[use-just-test] `ls -la`",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "formatAllow with null rule_id leaves message unprefixed" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatAllow(stream.writer(), "`ls -la`", null);
    const output = stream.getWritten();
    try std.testing.expectEqualStrings("{\"systemMessage\":\"`ls -la`\"}", output);
}

test "formatRejectMarker emits parseable systemMessage with rule_id prefix" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatRejectMarker(stream.writer(), "no-curl-pipe-shell");
    const output = stream.getWritten();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "[no-curl-pipe-shell] reject",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "formatRejectMarker escapes special characters in rule_id" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    // Pathological but legal-ish rule id with a quote (validation should catch
    // this earlier, but the writer must still produce valid JSON).
    try formatRejectMarker(stream.writer(), "weird\"id");
    const output = stream.getWritten();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "[weird\"id] reject",
        parsed.value.object.get("systemMessage").?.string,
    );
}
