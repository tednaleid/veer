// ABOUTME: Claude Code hook protocol implementation (PreToolUse and Stop).
// ABOUTME: Parses stdin JSON and formats output per the hook contract.

const std = @import("std");
const transcript = @import("transcript.zig");
const rule_mod = @import("../config/rule.zig");

pub const HookInput = struct {
    tool_name: []const u8,
    command: ?[]const u8, // Extracted from tool_input.command for Bash tools
    session_id: ?[]const u8,
    transcript_path: ?[]const u8,
    /// Text the content matchers read: the tool's written text (see
    /// `extractToolContent`), the resolved plan body for ExitPlanMode, or the
    /// finished reply for a Stop event. Null when the tool carries none or
    /// extraction failed; callers treat null as no match.
    content: ?[]const u8,
    /// Target path, from tool_input.file_path, notebook_path, or path,
    /// whichever appears first. Tool-name agnostic, so an MCP tool carrying
    /// file_path works without a veer release.
    file_path: ?[]const u8,
    /// Session working directory, from the envelope root. Used to resolve a
    /// relative file_path.
    cwd: ?[]const u8,
    event: rule_mod.Event,
    /// Stop only: true when Claude is already continuing because of a Stop hook.
    stop_hook_active: bool,
    content_format: rule_mod.ContentFormat,
};

pub const ExitCode = struct {
    pub const allow: u8 = 0;
    pub const rewrite: u8 = 0;
    pub const reject: u8 = 2;
};

/// Parse hook input from a JSON string (read from stdin).
/// Extracts tool_name and command (for Bash tools) from the JSON.
/// For ExitPlanMode, also resolves the plan file content via the transcript.
pub fn parseInput(allocator: std.mem.Allocator, io: std.Io, json_str: []const u8) !HookInput {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidInput;

    const event: rule_mod.Event = blk: {
        const val = root.object.get("hook_event_name") orelse break :blk .PreToolUse;
        if (val != .string) return error.InvalidInput;
        break :blk std.meta.stringToEnum(rule_mod.Event, val.string) orelse return error.UnsupportedEvent;
    };

    if (event == .Stop) return parseStopInput(allocator, root);

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

    const file_path: ?[]const u8 = blk: {
        const tool_input = root.object.get("tool_input") orelse break :blk null;
        if (tool_input != .object) break :blk null;
        const keys = [_][]const u8{ "file_path", "notebook_path", "path" };
        for (keys) |key| {
            const val = tool_input.object.get(key) orelse continue;
            if (val != .string) continue;
            break :blk try allocator.dupe(u8, val.string);
        }
        break :blk null;
    };
    errdefer if (file_path) |fp| allocator.free(fp);

    const cwd: ?[]const u8 = blk: {
        const val = root.object.get("cwd") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk try allocator.dupe(u8, val.string);
    };
    errdefer if (cwd) |c| allocator.free(c);

    // Tool-specific content extraction. Fail-open: any error producing
    // content yields null, which the engine treats as "rule does not match"
    // for content rules. A transient FS or parse glitch must not block the
    // agent from making progress.
    const content: ?[]const u8 = if (std.mem.eql(u8, tool_name, "ExitPlanMode")) blk: {
        const tp = transcript_path orelse break :blk null;
        break :blk resolveExitPlanModeContent(allocator, io, tp) catch null;
    } else blk: {
        const tool_input = root.object.get("tool_input") orelse break :blk null;
        break :blk extractToolContent(allocator, tool_name, tool_input) catch null;
    };

    return .{
        .tool_name = tool_name,
        .command = command,
        .session_id = session_id,
        .transcript_path = transcript_path,
        .content = content,
        .file_path = file_path,
        .cwd = cwd,
        .event = .PreToolUse,
        .stop_hook_active = false,
        .content_format = rule_mod.contentFormatFor(tool_name),
    };
}

fn parseStopInput(allocator: std.mem.Allocator, root: std.json.Value) !HookInput {
    const tool_name = try allocator.dupe(u8, "");
    errdefer allocator.free(tool_name);

    const content: ?[]const u8 = blk: {
        const val = root.object.get("last_assistant_message") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk try allocator.dupe(u8, val.string);
    };
    errdefer if (content) |c| allocator.free(c);

    const session_id: ?[]const u8 = blk: {
        const val = root.object.get("session_id") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk try allocator.dupe(u8, val.string);
    };

    const active = if (root.object.get("stop_hook_active")) |v| v == .bool and v.bool else false;

    return .{
        .tool_name = tool_name,
        .command = null,
        .session_id = session_id,
        .transcript_path = null,
        .content = content,
        .file_path = null,
        .cwd = null,
        .event = .Stop,
        .stop_hook_active = active,
        .content_format = .markdown,
    };
}

/// The text a tool call writes, for content matchers. Known tools use one
/// field; read-only tools carry none, so searching for a character is never
/// rejected; any other tool (AskUserQuestion, MCP tools) contributes every
/// string in its input except paths, joined by newlines.
fn extractToolContent(allocator: std.mem.Allocator, tool_name: []const u8, tool_input: std.json.Value) !?[]u8 {
    if (tool_input != .object) return null;

    const Single = struct { tool: []const u8, field: []const u8 };
    const single_field = [_]Single{
        .{ .tool = "Bash", .field = "command" },
        .{ .tool = "Write", .field = "content" },
        .{ .tool = "Edit", .field = "new_string" },
        .{ .tool = "NotebookEdit", .field = "new_source" },
        .{ .tool = "Agent", .field = "prompt" },
        .{ .tool = "SubagentHandback", .field = "message" },
    };
    for (single_field) |sf| {
        if (!std.mem.eql(u8, tool_name, sf.tool)) continue;
        const val = tool_input.object.get(sf.field) orelse return null;
        if (val != .string) return null;
        return try allocator.dupe(u8, val.string);
    }

    const read_only = [_][]const u8{ "Read", "Grep", "Glob", "WebFetch", "WebSearch" };
    for (read_only) |t| {
        if (std.mem.eql(u8, tool_name, t)) return null;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendStrings(allocator, &buf, tool_input);
    if (buf.items.len == 0) {
        buf.deinit(allocator);
        return null;
    }
    return try buf.toOwnedSlice(allocator);
}

fn appendStrings(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    switch (value) {
        .string => |str| {
            if (buf.items.len > 0) try buf.append(allocator, '\n');
            try buf.appendSlice(allocator, str);
        },
        .array => |a| for (a.items) |item| try appendStrings(allocator, buf, item),
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const is_path = std.mem.eql(u8, key, "file_path") or
                    std.mem.eql(u8, key, "notebook_path") or
                    std.mem.eql(u8, key, "path");
                if (is_path) continue;
                try appendStrings(allocator, buf, entry.value_ptr.*);
            }
        },
        else => {},
    }
}

/// True when a config load failure should block the call: PreToolUse input,
/// including input with no `hook_event_name` or input that does not parse.
/// A blocking exit on any other event would not stop a tool call; on Stop it
/// would force Claude to keep continuing.
pub fn blocksOnConfigError(allocator: std.mem.Allocator, json_str: []const u8) bool {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return true;
    defer parsed.deinit();
    if (parsed.value != .object) return true;
    const val = parsed.value.object.get("hook_event_name") orelse return true;
    if (val != .string) return true;
    return std.mem.eql(u8, val.string, "PreToolUse");
}

/// Read the transcript at `transcript_path`, locate the most recent
/// plan_mode attachment, then read and return that plan file's contents.
/// Returns null on any I/O or parse failure.
fn resolveExitPlanModeContent(allocator: std.mem.Allocator, io: std.Io, transcript_path: []const u8) !?[]u8 {
    const transcript_content = readFileBounded(allocator, io, transcript_path, 64 * 1024 * 1024) catch return null;
    defer allocator.free(transcript_content);

    const plan_path_opt = transcript.findLatestPlanFilePath(allocator, transcript_content) catch null;
    const plan_path = plan_path_opt orelse return null;
    defer allocator.free(plan_path);

    return readFileBounded(allocator, io, plan_path, 4 * 1024 * 1024) catch null;
}

fn readFileBounded(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: usize) ![]u8 {
    const f = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer f.close(io);

    var read_buf: [4096]u8 = undefined;
    var file_reader = f.reader(io, &read_buf);
    return try file_reader.interface.allocRemaining(allocator, .limited(max_bytes));
}

/// Free a HookInput's owned strings.
pub fn freeInput(allocator: std.mem.Allocator, input: *HookInput) void {
    allocator.free(input.tool_name);
    if (input.command) |cmd| allocator.free(cmd);
    if (input.session_id) |sid| allocator.free(sid);
    if (input.transcript_path) |tp| allocator.free(tp);
    if (input.content) |c| allocator.free(c);
    if (input.file_path) |fp| allocator.free(fp);
    if (input.cwd) |c| allocator.free(c);
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

/// Format a Stop rejection for stdout. Claude continues the turn with
/// `feedback` labeled as Stop hook feedback, not as an error. The
/// systemMessage keeps rejects discoverable with the same `[<rule_id>] `
/// prefix grammar as PreToolUse rejects.
pub fn formatStopFeedback(writer: anytype, rule_id: []const u8, feedback: []const u8) !void {
    try writer.writeAll("{\"systemMessage\":\"[");
    try writeJsonEscaped(writer, rule_id);
    try writer.writeAll("] reject\",\"hookSpecificOutput\":{\"hookEventName\":\"Stop\",\"additionalContext\":");
    try writeJsonString(writer, feedback);
    try writer.writeAll("}}");
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
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("Bash", input.tool_name);
    try std.testing.expectEqualStrings("pytest tests/", input.command.?);
    try std.testing.expectEqualStrings("abc-123", input.session_id.?);
}

test "parseInput extracts file_path for a Write" {
    const json =
        \\{"tool_name":"Write","tool_input":{"file_path":"/etc/passwd","content":"..."},"cwd":"/home/me/proj"}
    ;
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("Write", input.tool_name);
    try std.testing.expect(input.command == null);
    try std.testing.expectEqualStrings("...", input.content.?);
    try std.testing.expectEqualStrings("/etc/passwd", input.file_path.?);
    try std.testing.expectEqualStrings("/home/me/proj", input.cwd.?);
}

test "parseInput falls back to notebook_path then path" {
    const notebook =
        \\{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/a/nb.ipynb"}}
    ;
    var nb = try parseInput(std.testing.allocator, std.testing.io, notebook);
    defer freeInput(std.testing.allocator, &nb);
    try std.testing.expectEqualStrings("/a/nb.ipynb", nb.file_path.?);

    const grep =
        \\{"tool_name":"Grep","tool_input":{"pattern":"foo","path":"/a/src"}}
    ;
    var g = try parseInput(std.testing.allocator, std.testing.io, grep);
    defer freeInput(std.testing.allocator, &g);
    try std.testing.expectEqualStrings("/a/src", g.file_path.?);
}

test "parseInput leaves file_path null when no path key is present" {
    const json =
        \\{"tool_name":"Bash","tool_input":{"command":"ls"}}
    ;
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);
    try std.testing.expect(input.file_path == null);
}

test "parseInput extracts transcript_path" {
    const json =
        \\{"tool_name":"Bash","tool_input":{"command":"ls"},"transcript_path":"/tmp/session.jsonl"}
    ;
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("/tmp/session.jsonl", input.transcript_path.?);
    // Bash tool content is its command, independent of transcript_path.
    try std.testing.expectEqualStrings("ls", input.content.?);
}

test "parseInput resolves ExitPlanMode plan content from transcript" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(tmp_root);

    // Write a fake plan file
    const plan_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/plan.md", .{tmp_root});
    defer std.testing.allocator.free(plan_path);
    {
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, plan_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, "# Plan\n\nWe will do X but actually let's do Y.\n");
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
        const f = try std.Io.Dir.cwd().createFile(std.testing.io, transcript_path, .{});
        defer f.close(std.testing.io);
        try f.writeStreamingAll(std.testing.io, transcript_line);
    }

    // Build the hook input pointing at our fake transcript
    const json = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"tool_name\":\"ExitPlanMode\",\"tool_input\":{{}},\"transcript_path\":\"{s}\"}}",
        .{transcript_path},
    );
    defer std.testing.allocator.free(json);

    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("ExitPlanMode", input.tool_name);
    try std.testing.expect(input.content != null);
    try std.testing.expect(std.mem.indexOf(u8, input.content.?, "actually") != null);
}

test "parseInput ExitPlanMode with missing transcript_path leaves content null" {
    const json =
        \\{"tool_name":"ExitPlanMode","tool_input":{}}
    ;
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expectEqualStrings("ExitPlanMode", input.tool_name);
    try std.testing.expect(input.content == null);
}

test "parseInput ExitPlanMode with non-existent transcript path leaves content null" {
    const json =
        \\{"tool_name":"ExitPlanMode","tool_input":{},"transcript_path":"/nonexistent/transcript.jsonl"}
    ;
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);

    try std.testing.expect(input.content == null);
    try std.testing.expectEqualStrings("/nonexistent/transcript.jsonl", input.transcript_path.?);
}

test "parseInput missing tool_name fails" {
    const json =
        \\{"tool_input":{"command":"ls"}}
    ;
    try std.testing.expectError(error.InvalidInput, parseInput(std.testing.allocator, std.testing.io, json));
}

test "parseInput invalid JSON fails" {
    try std.testing.expectError(error.SyntaxError, parseInput(std.testing.allocator, std.testing.io, "not json{{{"));
}

test "formatRewrite produces modern hookSpecificOutput envelope" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try formatRewrite(&stream, "just test", null, null);
    const output = stream.buffered();
    try std.testing.expectEqualStrings(
        "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\"," ++
            "\"permissionDecision\":\"allow\"," ++
            "\"updatedInput\":{\"command\":\"just test\"}}}",
        output,
    );
}

test "formatRewrite with systemMessage prepends top-level field" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try formatRewrite(&stream, "just test", "`pytest` -> `just test`", null);
    const output = stream.buffered();
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
    var stream = std.Io.Writer.fixed(&buf);
    // Both fields must be escaped; otherwise a command containing `"` or `\`
    // would produce invalid JSON.
    try formatRewrite(&stream, "echo \"hi\"", "`x\\y`", null);
    const output = stream.buffered();
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
    var stream = std.Io.Writer.fixed(&buf);
    try formatAllow(&stream, "veer: Read", null);
    const output = stream.buffered();
    try std.testing.expectEqualStrings("{\"systemMessage\":\"veer: Read\"}", output);
}

test "formatAllow escapes control characters" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try formatAllow(&stream, "veer: Bash `echo\nhi`", null);
    const output = stream.buffered();
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
    var stream = std.Io.Writer.fixed(&buf);
    try formatRewrite(&stream, "just test", "`pytest` -> `just test`", "use-just-test");
    const output = stream.buffered();
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
    var stream = std.Io.Writer.fixed(&buf);
    try formatRewrite(&stream, "just test", "`pytest` -> `just test`", null);
    const output = stream.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "`pytest` -> `just test`",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "formatAllow with rule_id prefixes message" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try formatAllow(&stream, "`ls -la`", "use-just-test");
    const output = stream.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "[use-just-test] `ls -la`",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "formatAllow with null rule_id leaves message unprefixed" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try formatAllow(&stream, "`ls -la`", null);
    const output = stream.buffered();
    try std.testing.expectEqualStrings("{\"systemMessage\":\"`ls -la`\"}", output);
}

test "formatRejectMarker emits parseable systemMessage with rule_id prefix" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    try formatRejectMarker(&stream, "no-curl-pipe-shell");
    const output = stream.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "[no-curl-pipe-shell] reject",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "formatRejectMarker escapes special characters in rule_id" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    // Pathological but legal-ish rule id with a quote (validation should catch
    // this earlier, but the writer must still produce valid JSON).
    try formatRejectMarker(&stream, "weird\"id");
    const output = stream.buffered();
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, output, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "[weird\"id] reject",
        parsed.value.object.get("systemMessage").?.string,
    );
}

test "parseInput reads a Stop event" {
    const json =
        \\{"hook_event_name":"Stop","session_id":"s","stop_hook_active":false,"last_assistant_message":"Done \u2705"}
    ;
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);
    try std.testing.expectEqual(rule_mod.Event.Stop, input.event);
    try std.testing.expectEqual(rule_mod.ContentFormat.markdown, input.content_format);
    try std.testing.expectEqualStrings("Done \u{2705}", input.content.?);
    try std.testing.expect(!input.stop_hook_active);
}

test "parseInput reads stop_hook_active" {
    const json =
        \\{"hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"x"}
    ;
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);
    try std.testing.expect(input.stop_hook_active);
}

test "parseInput rejects unsupported events" {
    const cases = .{
        \\{"hook_event_name":"MessageDisplay","delta":"x"}
        ,
        \\{"hook_event_name":"SubagentStop","last_assistant_message":"x"}
        ,
    };
    inline for (cases) |json| {
        try std.testing.expectError(error.UnsupportedEvent, parseInput(std.testing.allocator, std.testing.io, json));
    }
}

test "parseInput extracts content per tool" {
    const cases = .{
        .{
            \\{"tool_name":"Write","tool_input":{"file_path":"/a/b.md","content":"body"}}
            ,
            @as(?[]const u8, "body"),
            rule_mod.ContentFormat.raw,
        },
        .{
            \\{"tool_name":"Edit","tool_input":{"file_path":"/a","old_string":"old","new_string":"new"}}
            ,
            @as(?[]const u8, "new"),
            rule_mod.ContentFormat.raw,
        },
        .{
            \\{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/a.ipynb","new_source":"src"}}
            ,
            @as(?[]const u8, "src"),
            rule_mod.ContentFormat.raw,
        },
        .{
            \\{"tool_name":"Bash","tool_input":{"command":"ls -la"}}
            ,
            @as(?[]const u8, "ls -la"),
            rule_mod.ContentFormat.raw,
        },
        .{
            \\{"tool_name":"Agent","tool_input":{"description":"d","prompt":"do it"}}
            ,
            @as(?[]const u8, "do it"),
            rule_mod.ContentFormat.markdown,
        },
        .{
            \\{"tool_name":"SubagentHandback","tool_input":{"message":"report"}}
            ,
            @as(?[]const u8, "report"),
            rule_mod.ContentFormat.markdown,
        },
        .{
            \\{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[{"label":"A","description":"a"}]}]}}
            ,
            @as(?[]const u8, "Q?\nA\na"),
            rule_mod.ContentFormat.markdown,
        },
        .{
            \\{"tool_name":"mcp__gh__create_pr","tool_input":{"title":"T","body":"B","path":"/x","draft":true}}
            ,
            @as(?[]const u8, "T\nB"),
            rule_mod.ContentFormat.raw,
        },
        .{
            \\{"tool_name":"Grep","tool_input":{"pattern":"\u2705","path":"src"}}
            ,
            @as(?[]const u8, null),
            rule_mod.ContentFormat.raw,
        },
        .{
            \\{"tool_name":"Read","tool_input":{"file_path":"/a"}}
            ,
            @as(?[]const u8, null),
            rule_mod.ContentFormat.raw,
        },
        .{
            \\{"tool_name":"WebSearch","tool_input":{"query":"q"}}
            ,
            @as(?[]const u8, null),
            rule_mod.ContentFormat.raw,
        },
    };
    inline for (cases) |c| {
        var input = try parseInput(std.testing.allocator, std.testing.io, c[0]);
        defer freeInput(std.testing.allocator, &input);
        try std.testing.expectEqual(rule_mod.Event.PreToolUse, input.event);
        try std.testing.expectEqual(c[2], input.content_format);
        if (c[1]) |expected| {
            try std.testing.expectEqualStrings(expected, input.content.?);
        } else {
            try std.testing.expect(input.content == null);
        }
    }
}

test "formatStopFeedback emits additionalContext and a reject marker" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatStopFeedback(&w, "no-emoji", "line one\nline two");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("[no-emoji] reject", parsed.value.object.get("systemMessage").?.string);
    const hso = parsed.value.object.get("hookSpecificOutput").?.object;
    try std.testing.expectEqualStrings("Stop", hso.get("hookEventName").?.string);
    try std.testing.expectEqualStrings("line one\nline two", hso.get("additionalContext").?.string);
}

test "blocksOnConfigError is true only for PreToolUse input" {
    const cases = .{
        .{ "{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}", true },
        .{ "{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\"}", true },
        .{ "{\"hook_event_name\":\"Stop\",\"stop_hook_active\":true}", false },
        .{ "{\"hook_event_name\":\"MessageDisplay\",\"delta\":\"x\"}", false },
        .{ "not json", true },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[1], blocksOnConfigError(std.testing.allocator, c[0]));
    }
}
