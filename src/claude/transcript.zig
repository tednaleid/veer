// ABOUTME: JSONL transcript parser for Claude Code session files.
// ABOUTME: Extracts Bash tool_use commands from session transcripts line-by-line.

const std = @import("std");

pub const BashCommand = struct {
    command: []const u8,
    timestamp: ?[]const u8 = null,
    session_id: ?[]const u8 = null,
};

/// Parse JSONL content and extract all Bash tool_use commands.
/// Each line is parsed independently; malformed lines are skipped.
pub fn extractCommands(allocator: std.mem.Allocator, content: []const u8) !std.ArrayListUnmanaged(BashCommand) {
    var commands = std.ArrayListUnmanaged(BashCommand).empty;
    errdefer commands.deinit(allocator);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{},
        ) catch continue; // skip malformed lines
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;

        // Only process assistant messages
        const msg_type = getStr(root, "type") orelse continue;
        if (!std.mem.eql(u8, msg_type, "assistant")) continue;

        const timestamp = getStr(root, "timestamp");
        const session_id = getStr(root, "sessionId");

        // Walk message.content[] for tool_use blocks
        const message = root.object.get("message") orelse continue;
        if (message != .object) continue;
        const content_arr = message.object.get("content") orelse continue;
        if (content_arr != .array) continue;

        for (content_arr.array.items) |block| {
            if (block != .object) continue;
            const block_type = getStr(block, "type") orelse continue;
            if (!std.mem.eql(u8, block_type, "tool_use")) continue;

            const name = getStr(block, "name") orelse continue;
            if (!std.mem.eql(u8, name, "Bash")) continue;

            const input = block.object.get("input") orelse continue;
            if (input != .object) continue;
            const command = getStr(input, "command") orelse continue;

            // Dupe strings since they're owned by the parsed JSON
            try commands.append(allocator, .{
                .command = try allocator.dupe(u8, command),
                .timestamp = if (timestamp) |ts| try allocator.dupe(u8, ts) else null,
                .session_id = if (session_id) |sid| try allocator.dupe(u8, sid) else null,
            });
        }
    }

    return commands;
}

pub fn freeCommands(allocator: std.mem.Allocator, commands: *std.ArrayListUnmanaged(BashCommand)) void {
    for (commands.items) |cmd| {
        allocator.free(cmd.command);
        if (cmd.timestamp) |ts| allocator.free(ts);
        if (cmd.session_id) |sid| allocator.free(sid);
    }
    commands.deinit(allocator);
}

fn getStr(obj: std.json.Value, key: []const u8) ?[]const u8 {
    if (obj != .object) return null;
    const val = obj.object.get(key) orelse return null;
    if (val != .string) return null;
    return val.string;
}

// -- Tests --

pub const test_jsonl =
    \\{"type":"user","message":{"role":"user","content":"run tests"},"timestamp":"2025-07-01T10:00:00Z","sessionId":"sess-001"}
    \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"pytest tests/"}}]},"timestamp":"2025-07-01T10:00:01Z","sessionId":"sess-001"}
    \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"src/main.zig"}}]},"timestamp":"2025-07-01T10:00:02Z","sessionId":"sess-001"}
    \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"just lint"}}]},"timestamp":"2025-07-01T10:00:03Z","sessionId":"sess-001"}
    \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"pytest tests/ -v"}}]},"timestamp":"2025-07-01T10:00:04Z","sessionId":"sess-001"}
    \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"python3 script.py"}}]},"timestamp":"2025-07-01T10:00:06Z","sessionId":"sess-001"}
;

test "extractCommands from simple session" {
    const content = test_jsonl;
    var commands = try extractCommands(std.testing.allocator, content);
    defer freeCommands(std.testing.allocator, &commands);

    // Should find 4 Bash commands (pytest, just lint, pytest -v, python3)
    try std.testing.expectEqual(@as(usize, 4), commands.items.len);
    try std.testing.expectEqualStrings("pytest tests/", commands.items[0].command);
    try std.testing.expectEqualStrings("just lint", commands.items[1].command);
    try std.testing.expectEqualStrings("pytest tests/ -v", commands.items[2].command);
    try std.testing.expectEqualStrings("python3 script.py", commands.items[3].command);
}

test "extractCommands skips malformed lines" {
    const content = "not json at all\n{\"type\":\"user\"}\n";
    var commands = try extractCommands(std.testing.allocator, content);
    defer freeCommands(std.testing.allocator, &commands);

    try std.testing.expectEqual(@as(usize, 0), commands.items.len);
}

test "extractCommands handles empty input" {
    var commands = try extractCommands(std.testing.allocator, "");
    defer freeCommands(std.testing.allocator, &commands);

    try std.testing.expectEqual(@as(usize, 0), commands.items.len);
}

test "extractCommands preserves timestamps" {
    const content = test_jsonl;
    var commands = try extractCommands(std.testing.allocator, content);
    defer freeCommands(std.testing.allocator, &commands);

    try std.testing.expectEqualStrings("2025-07-01T10:00:01Z", commands.items[0].timestamp.?);
    try std.testing.expectEqualStrings("sess-001", commands.items[0].session_id.?);
}
