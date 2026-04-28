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

/// Scan a JSONL transcript and return the path stored in the most recent
/// `attachment.type == "plan_mode"` entry's `planFilePath` field. Returns
/// null if no such entry exists. Caller owns the returned slice.
///
/// Claude Code records a `plan_mode` attachment when the agent enters plan
/// mode; the field is the absolute path the agent must write its plan to.
/// We use this rather than scanning the filesystem because it's
/// session-precise -- the most recently modified file in `~/.claude/plans/`
/// could belong to a different concurrent session.
pub fn findLatestPlanFilePath(allocator: std.mem.Allocator, content: []const u8) !?[]u8 {
    var latest: ?[]u8 = null;
    errdefer if (latest) |p| allocator.free(p);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        const parsed = std.json.parseFromSlice(
            std.json.Value,
            allocator,
            line,
            .{},
        ) catch continue;
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) continue;

        const attachment = root.object.get("attachment") orelse continue;
        if (attachment != .object) continue;

        const att_type = getStr(attachment, "type") orelse continue;
        if (!std.mem.eql(u8, att_type, "plan_mode")) continue;

        const path = getStr(attachment, "planFilePath") orelse continue;

        if (latest) |prev| allocator.free(prev);
        latest = try allocator.dupe(u8, path);
    }

    return latest;
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

test "findLatestPlanFilePath returns path from plan_mode attachment" {
    const content =
        \\{"type":"user","message":{"role":"user","content":"plan it"},"timestamp":"2026-04-28T22:00:00Z"}
        \\{"attachment":{"type":"plan_mode","planFilePath":"/Users/me/.claude/plans/foo.md","planExists":false},"type":"attachment","timestamp":"2026-04-28T22:00:01Z"}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Write","input":{"file_path":"/Users/me/.claude/plans/foo.md","content":"# Plan"}}]}}
    ;
    const path = try findLatestPlanFilePath(std.testing.allocator, content);
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/Users/me/.claude/plans/foo.md", path.?);
}

test "findLatestPlanFilePath returns most recent when multiple plan_mode entries" {
    // A session that re-enters plan mode for a different task.
    const content =
        \\{"attachment":{"type":"plan_mode","planFilePath":"/p/old.md","planExists":false},"type":"attachment","timestamp":"2026-04-28T22:00:00Z"}
        \\{"type":"assistant","message":{"role":"assistant","content":[]}}
        \\{"attachment":{"type":"plan_mode","planFilePath":"/p/current.md","planExists":false},"type":"attachment","timestamp":"2026-04-28T22:30:00Z"}
    ;
    const path = try findLatestPlanFilePath(std.testing.allocator, content);
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expect(path != null);
    try std.testing.expectEqualStrings("/p/current.md", path.?);
}

test "findLatestPlanFilePath returns null when no plan_mode entry exists" {
    const content =
        \\{"type":"user","message":{"role":"user","content":"hi"}}
        \\{"type":"assistant","message":{"role":"assistant","content":[]}}
    ;
    const path = try findLatestPlanFilePath(std.testing.allocator, content);
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expect(path == null);
}

test "findLatestPlanFilePath skips non-plan_mode attachments" {
    const content =
        \\{"attachment":{"type":"hook_success","hookName":"foo"},"type":"attachment"}
        \\{"attachment":{"type":"plan_mode","planFilePath":"/p/found.md"},"type":"attachment"}
    ;
    const path = try findLatestPlanFilePath(std.testing.allocator, content);
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expectEqualStrings("/p/found.md", path.?);
}

test "findLatestPlanFilePath ignores malformed lines" {
    const content =
        "garbage line\n" ++
        \\{"attachment":{"type":"plan_mode","planFilePath":"/p/foo.md"},"type":"attachment"}
        ;
    const path = try findLatestPlanFilePath(std.testing.allocator, content);
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expectEqualStrings("/p/foo.md", path.?);
}
