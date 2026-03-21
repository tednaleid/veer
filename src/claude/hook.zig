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

/// Format a rewrite result for stdout.
/// Output: {"updatedInput":{"command":"<rewrite_to>"}}
pub fn formatRewrite(writer: anytype, rewrite_to: []const u8) !void {
    try writer.print("{{\"updatedInput\":{{\"command\":\"{s}\"}}}}", .{rewrite_to});
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

test "formatRewrite produces correct JSON" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatRewrite(stream.writer(), "just test");
    const output = stream.getWritten();
    try std.testing.expectEqualStrings("{\"updatedInput\":{\"command\":\"just test\"}}", output);
}
