// ABOUTME: Claude Code PreToolUse hook protocol implementation.
// ABOUTME: Parses stdin JSON and formats output per the hook contract.

const std = @import("std");

pub const HookInput = struct {
    tool_name: []const u8,
    command: ?[]const u8, // Extracted from tool_input.command for Bash tools
    session_id: ?[]const u8,
};

pub const ExitCode = struct {
    pub const allow: u8 = 0;
    pub const rewrite: u8 = 0;
    pub const reject: u8 = 2;
};

/// Parse hook input from a JSON string (read from stdin).
/// Extracts tool_name and command (for Bash tools) from the JSON.
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
        const val = root.object.get("sessionId") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk try allocator.dupe(u8, val.string);
    };

    return .{
        .tool_name = tool_name,
        .command = command,
        .session_id = session_id,
    };
}

/// Free a HookInput's owned strings.
pub fn freeInput(allocator: std.mem.Allocator, input: *HookInput) void {
    allocator.free(input.tool_name);
    if (input.command) |cmd| allocator.free(cmd);
    if (input.session_id) |sid| allocator.free(sid);
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
pub fn formatRewrite(writer: anytype, rewrite_to: []const u8, system_message: ?[]const u8) !void {
    try writer.writeAll("{");
    if (system_message) |msg| {
        try writer.writeAll("\"systemMessage\":");
        try writeJsonString(writer, msg);
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
/// Output: {"systemMessage":"<message>"}
pub fn formatAllow(writer: anytype, system_message: []const u8) !void {
    try writer.writeAll("{\"systemMessage\":");
    try writeJsonString(writer, system_message);
    try writer.writeAll("}");
}

/// Write a JSON-encoded string (including surrounding quotes).
/// Escapes the characters JSON requires: `"`, `\`, and control chars < 0x20.
fn writeJsonString(writer: anytype, str: []const u8) !void {
    try writer.writeByte('"');
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
    try writer.writeByte('"');
}

// -- Tests --

test "parseInput Bash tool with command" {
    const json =
        \\{"tool_name":"Bash","tool_input":{"command":"pytest tests/"},"sessionId":"abc-123"}
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
    try formatRewrite(stream.writer(), "just test", null);
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
    try formatRewrite(stream.writer(), "just test", "`pytest` -> `just test`");
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
    try formatRewrite(stream.writer(), "echo \"hi\"", "`x\\y`");
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
    try formatAllow(stream.writer(), "veer: Read");
    const output = stream.getWritten();
    try std.testing.expectEqualStrings("{\"systemMessage\":\"veer: Read\"}", output);
}

test "formatAllow escapes control characters" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatAllow(stream.writer(), "veer: Bash `echo\nhi`");
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
