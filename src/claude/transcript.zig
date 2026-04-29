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

/// Action veer took on a hook fire. Derived from exit_code + stdout shape.
pub const Action = enum { allow, rewrite, reject };

/// One PreToolUse hook fire, joined to the tool_use block it was checking.
pub const HookEvent = struct {
    timestamp_ms: i64,
    session_id: ?[]const u8,
    tool_use_id: ?[]const u8,
    tool_name: ?[]const u8,
    command: ?[]const u8,
    exit_code: i32,
    duration_ms: u64,
    rule_id: ?[]const u8,
    action: Action,
};

const ToolUseInfo = struct {
    name: ?[]const u8,
    command: ?[]const u8,
};

/// Parse a JSONL transcript and return all PreToolUse hook events with their
/// linked tool_use blocks resolved (for tool_name and Bash command).
///
/// Two passes: first builds a map[toolUseID] -> ToolUseInfo, second walks
/// hook_success attachments and joins. Rule attribution comes from parsing
/// the `[<rule_id>] ` prefix in the stdout systemMessage; older transcripts
/// without the prefix yield rule_id = null. Action is derived from exit_code
/// (2 = reject) and stdout shape (presence of `hookSpecificOutput.updatedInput`
/// distinguishes rewrite from allow).
///
/// Caller frees via `freeHookEvents`.
///
/// Performance: three layers of pre-filtering avoid the dominant cost
/// (full JSON parse of every line in every transcript) for files that
/// contain little or no veer activity.
///   1. File-level: if the content lacks the literal "PreToolUse" hookEvent
///      marker, return empty without parsing anything. Most ~/.claude/projects
///      transcripts pre-date veer install and fall into this bucket.
///   2. Line-level: only parse JSON for lines containing "tool_use" or
///      "hook_success". User/assistant prose lines are skipped for free.
///   3. Single-pass: build the toolUseID index AND collect raw hook records
///      in one walk, resolving commands at the end via cheap hash lookups.
pub fn extractHookEvents(allocator: std.mem.Allocator, content: []const u8) !std.ArrayListUnmanaged(HookEvent) {
    var events = std.ArrayListUnmanaged(HookEvent).empty;
    errdefer freeHookEvents(allocator, &events);

    // File-level fast-skip: no PreToolUse marker means no relevant events.
    if (std.mem.indexOf(u8, content, "\"hookEvent\":\"PreToolUse\"") == null) {
        return events;
    }

    var tool_uses = std.StringHashMapUnmanaged(ToolUseInfo){};
    defer {
        var it = tool_uses.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            if (kv.value_ptr.name) |n| allocator.free(n);
            if (kv.value_ptr.command) |c| allocator.free(c);
        }
        tool_uses.deinit(allocator);
    }

    // Pending hook events: collected with their toolUseID, command resolved
    // at the end against the now-complete tool_uses index. This handles the
    // (rare) case of out-of-order writes where a hook_success line appears
    // before its referenced tool_use line.
    const PendingEvent = struct {
        timestamp_ms: i64,
        session_id: ?[]u8,
        tool_use_id: ?[]u8,
        tool_name: ?[]u8,
        exit_code: i32,
        duration_ms: u64,
        rule_id: ?[]u8,
        action: Action,
    };
    var pending = std.ArrayListUnmanaged(PendingEvent).empty;
    defer {
        for (pending.items) |p| {
            if (p.session_id) |s| allocator.free(s);
            if (p.tool_use_id) |t| allocator.free(t);
            if (p.tool_name) |n| allocator.free(n);
            if (p.rule_id) |r| allocator.free(r);
        }
        pending.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;

        // Line-level fast-skip: only parse JSON for lines that could carry
        // a tool_use block or a hook_success attachment. Prose lines (user
        // messages, assistant text) miss both substrings and are free.
        const has_tool_use = std.mem.indexOf(u8, line, "\"tool_use\"") != null;
        const has_hook = std.mem.indexOf(u8, line, "\"hook_success\"") != null;
        if (!has_tool_use and !has_hook) continue;

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{}) catch continue;
        defer parsed.deinit();
        const root = parsed.value;
        if (root != .object) continue;

        if (has_tool_use) try indexToolUses(allocator, root, &tool_uses);
        if (has_hook) try collectHookEvent(allocator, root, &pending, PendingEvent);
    }

    // Resolution pass: hash-lookup commands and finalize HookEvents.
    for (pending.items) |p| {
        const command: ?[]const u8 = blk: {
            const tu_id = p.tool_use_id orelse break :blk null;
            const info = tool_uses.get(tu_id) orelse break :blk null;
            break :blk info.command;
        };
        try events.append(allocator, .{
            .timestamp_ms = p.timestamp_ms,
            .session_id = if (p.session_id) |s| try allocator.dupe(u8, s) else null,
            .tool_use_id = if (p.tool_use_id) |t| try allocator.dupe(u8, t) else null,
            .tool_name = if (p.tool_name) |n| try allocator.dupe(u8, n) else null,
            .command = if (command) |c| try allocator.dupe(u8, c) else null,
            .exit_code = p.exit_code,
            .duration_ms = p.duration_ms,
            .rule_id = if (p.rule_id) |r| try allocator.dupe(u8, r) else null,
            .action = p.action,
        });
    }

    return events;
}

/// Walk a parsed JSON line's `message.content[]` array and add any tool_use
/// blocks to the index. Idempotent on duplicate ids.
fn indexToolUses(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    tool_uses: *std.StringHashMapUnmanaged(ToolUseInfo),
) !void {
    const message = root.object.get("message") orelse return;
    if (message != .object) return;
    const content_arr = message.object.get("content") orelse return;
    if (content_arr != .array) return;

    for (content_arr.array.items) |block| {
        if (block != .object) continue;
        const block_type = getStr(block, "type") orelse continue;
        if (!std.mem.eql(u8, block_type, "tool_use")) continue;

        const id = getStr(block, "id") orelse continue;
        const name = getStr(block, "name");
        var cmd: ?[]const u8 = null;
        if (block.object.get("input")) |input_val| {
            if (input_val == .object) cmd = getStr(input_val, "command");
        }

        const id_owned = try allocator.dupe(u8, id);
        const info = ToolUseInfo{
            .name = if (name) |n| try allocator.dupe(u8, n) else null,
            .command = if (cmd) |c| try allocator.dupe(u8, c) else null,
        };
        const gop = try tool_uses.getOrPut(allocator, id_owned);
        if (gop.found_existing) {
            allocator.free(id_owned);
            if (info.name) |n| allocator.free(n);
            if (info.command) |c| allocator.free(c);
        } else {
            gop.value_ptr.* = info;
        }
    }
}

/// If the parsed line is a PreToolUse hook_success attachment, append a
/// pending event (command resolved later via toolUseID lookup).
fn collectHookEvent(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    pending: anytype,
    comptime PendingEvent: type,
) !void {
    const attachment = root.object.get("attachment") orelse return;
    if (attachment != .object) return;
    const att_type = getStr(attachment, "type") orelse return;
    if (!std.mem.eql(u8, att_type, "hook_success")) return;
    const hook_event_name = getStr(attachment, "hookEvent") orelse return;
    if (!std.mem.eql(u8, hook_event_name, "PreToolUse")) return;

    const exit_code: i32 = blk: {
        const v = attachment.object.get("exitCode") orelse break :blk 0;
        if (v != .integer) break :blk 0;
        break :blk @intCast(v.integer);
    };
    const duration_ms: u64 = blk: {
        const v = attachment.object.get("durationMs") orelse break :blk 0;
        if (v != .integer) break :blk 0;
        const i = v.integer;
        break :blk if (i < 0) 0 else @intCast(i);
    };

    const stdout_str = getStr(attachment, "stdout") orelse "";
    const tool_use_id = getStr(attachment, "toolUseID");
    const hook_name = getStr(attachment, "hookName");
    const tool_name: ?[]const u8 = blk: {
        const hn = hook_name orelse break :blk null;
        const colon = std.mem.indexOfScalar(u8, hn, ':') orelse break :blk hn;
        break :blk hn[colon + 1 ..];
    };

    const action: Action = if (exit_code == 2)
        .reject
    else blk: {
        if (stdoutHasUpdatedInput(allocator, stdout_str)) break :blk .rewrite;
        break :blk .allow;
    };

    const rule_id = parseRuleIdFromStdout(allocator, stdout_str);
    const session_id = getStr(root, "sessionId");
    const timestamp_ms: i64 = blk: {
        const ts = getStr(root, "timestamp") orelse break :blk 0;
        break :blk parseIso8601Millis(ts);
    };

    try pending.append(allocator, PendingEvent{
        .timestamp_ms = timestamp_ms,
        .session_id = if (session_id) |s| try allocator.dupe(u8, s) else null,
        .tool_use_id = if (tool_use_id) |t| try allocator.dupe(u8, t) else null,
        .tool_name = if (tool_name) |n| try allocator.dupe(u8, n) else null,
        .exit_code = exit_code,
        .duration_ms = duration_ms,
        .rule_id = rule_id,
        .action = action,
    });
}

pub fn freeHookEvents(allocator: std.mem.Allocator, events: *std.ArrayListUnmanaged(HookEvent)) void {
    for (events.items) |ev| {
        if (ev.session_id) |s| allocator.free(s);
        if (ev.tool_use_id) |t| allocator.free(t);
        if (ev.tool_name) |n| allocator.free(n);
        if (ev.command) |c| allocator.free(c);
        if (ev.rule_id) |r| allocator.free(r);
    }
    events.deinit(allocator);
}

/// Return true if the hook stdout JSON contains
/// `hookSpecificOutput.updatedInput` (i.e., the hook performed a rewrite).
fn stdoutHasUpdatedInput(allocator: std.mem.Allocator, stdout_str: []const u8) bool {
    if (stdout_str.len == 0) return false;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout_str, .{}) catch return false;
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const hso = parsed.value.object.get("hookSpecificOutput") orelse return false;
    if (hso != .object) return false;
    return hso.object.get("updatedInput") != null;
}

/// Parse the leading `[<rule_id>] ` token from the systemMessage in the
/// hook stdout, if present. Returns an owned slice (caller frees) or null.
fn parseRuleIdFromStdout(allocator: std.mem.Allocator, stdout_str: []const u8) ?[]u8 {
    if (stdout_str.len == 0) return null;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, stdout_str, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const msg = getStr(parsed.value, "systemMessage") orelse return null;
    if (msg.len == 0 or msg[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, msg, ']') orelse return null;
    if (close <= 1) return null;
    // Require the standard "] " delimiter so we don't false-match arbitrary
    // bracketed text.
    if (close + 1 >= msg.len or msg[close + 1] != ' ') return null;
    return allocator.dupe(u8, msg[1..close]) catch null;
}

/// Best-effort parse of an ISO 8601 timestamp into unix milliseconds.
/// Used for time-window filtering in stats; precision beyond seconds is
/// preserved if present, but a malformed input yields 0 (sorted oldest).
pub fn parseIso8601Millis(ts: []const u8) i64 {
    // Format: 2026-04-28T22:00:00.500Z or 2026-04-28T22:00:00Z
    if (ts.len < 19) return 0;
    const year = std.fmt.parseInt(i64, ts[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(i64, ts[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(i64, ts[8..10], 10) catch return 0;
    if (ts[10] != 'T') return 0;
    const hour = std.fmt.parseInt(i64, ts[11..13], 10) catch return 0;
    const minute = std.fmt.parseInt(i64, ts[14..16], 10) catch return 0;
    const second = std.fmt.parseInt(i64, ts[17..19], 10) catch return 0;
    var millis: i64 = 0;
    if (ts.len > 19 and ts[19] == '.') {
        // Take up to 3 fractional digits.
        const frac_end = @min(ts.len, 23);
        if (frac_end > 20) {
            const frac = ts[20..frac_end];
            const m = std.fmt.parseInt(i64, frac, 10) catch 0;
            // pad to milliseconds
            millis = switch (frac.len) {
                1 => m * 100,
                2 => m * 10,
                else => m,
            };
        }
    }

    // Convert to unix epoch days using Howard Hinnant's algorithm
    // (handles negative dates; we won't see them, but cheap to keep general).
    const y = if (month <= 2) year - 1 else year;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400;
    const m = month;
    const doy = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + day - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    const days = era * 146097 + doe - 719468;

    return ((days * 24 + hour) * 60 + minute) * 60 * 1000 + second * 1000 + millis;
}

/// Walk a Claude Code projects root (typically ~/.claude/projects/) and
/// return absolute paths to all `*.jsonl` files one level deep. Caller
/// frees via `freeTranscriptPaths`. Missing root returns empty (fail open).
pub fn discoverProjectTranscripts(allocator: std.mem.Allocator, projects_root: []const u8) !std.ArrayListUnmanaged([]u8) {
    var result = std.ArrayListUnmanaged([]u8).empty;
    errdefer freeTranscriptPaths(allocator, &result);

    var root_dir = std.fs.cwd().openDir(projects_root, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return result,
        else => return err,
    };
    defer root_dir.close();

    var root_iter = root_dir.iterate();
    while (try root_iter.next()) |entry| {
        if (entry.kind != .directory) continue;
        var sub = root_dir.openDir(entry.name, .{ .iterate = true }) catch continue;
        defer sub.close();

        var sub_iter = sub.iterate();
        while (try sub_iter.next()) |sub_entry| {
            if (sub_entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, sub_entry.name, ".jsonl")) continue;
            const abs = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ projects_root, entry.name, sub_entry.name });
            try result.append(allocator, abs);
        }
    }
    return result;
}

pub fn freeTranscriptPaths(allocator: std.mem.Allocator, paths: *std.ArrayListUnmanaged([]u8)) void {
    for (paths.items) |p| allocator.free(p);
    paths.deinit(allocator);
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

// -- Hook event extraction tests --

const hook_events_jsonl =
    \\{"type":"assistant","sessionId":"sess-1","timestamp":"2026-04-28T22:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"pytest tests/"}}]}}
    \\{"type":"assistant","sessionId":"sess-1","timestamp":"2026-04-28T22:00:01Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"ls -la"}}]}}
    \\{"type":"assistant","sessionId":"sess-1","timestamp":"2026-04-28T22:00:02Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu3","name":"ExitPlanMode","input":{}}]}}
    \\{"type":"attachment","sessionId":"sess-1","timestamp":"2026-04-28T22:00:00.500Z","attachment":{"type":"hook_success","hookName":"PreToolUse:Bash","toolUseID":"tu1","hookEvent":"PreToolUse","stdout":"{\"systemMessage\":\"[use-just-test] `pytest tests/` -> `just test`\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"just test\"}}}","stderr":"","exitCode":0,"durationMs":12}}
    \\{"type":"attachment","sessionId":"sess-1","timestamp":"2026-04-28T22:00:01.500Z","attachment":{"type":"hook_success","hookName":"PreToolUse:Bash","toolUseID":"tu2","hookEvent":"PreToolUse","stdout":"","stderr":"","exitCode":0,"durationMs":3}}
    \\{"type":"attachment","sessionId":"sess-1","timestamp":"2026-04-28T22:00:02.500Z","attachment":{"type":"hook_success","hookName":"PreToolUse:ExitPlanMode","toolUseID":"tu3","hookEvent":"PreToolUse","stdout":"{\"systemMessage\":\"[no-actually-in-plans] reject\"}","stderr":"[no-actually-in-plans] Plans must not contain 'actually'.\n","exitCode":2,"durationMs":7}}
;

test "extractHookEvents joins hook_success with linked tool_use block" {
    var events = try extractHookEvents(std.testing.allocator, hook_events_jsonl);
    defer freeHookEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 3), events.items.len);

    // Rewrite event: rule_id parsed, command joined from tool_use block.
    const rewrite_e = events.items[0];
    try std.testing.expectEqual(Action.rewrite, rewrite_e.action);
    try std.testing.expectEqualStrings("use-just-test", rewrite_e.rule_id.?);
    try std.testing.expectEqualStrings("Bash", rewrite_e.tool_name.?);
    try std.testing.expectEqualStrings("pytest tests/", rewrite_e.command.?);
    try std.testing.expectEqual(@as(u64, 12), rewrite_e.duration_ms);
    try std.testing.expectEqual(@as(i32, 0), rewrite_e.exit_code);
    try std.testing.expectEqualStrings("sess-1", rewrite_e.session_id.?);
    try std.testing.expectEqualStrings("tu1", rewrite_e.tool_use_id.?);

    // Allow event with no rule match: empty stdout means rule_id null.
    const allow_e = events.items[1];
    try std.testing.expectEqual(Action.allow, allow_e.action);
    try std.testing.expect(allow_e.rule_id == null);
    try std.testing.expectEqualStrings("Bash", allow_e.tool_name.?);
    try std.testing.expectEqualStrings("ls -la", allow_e.command.?);

    // Reject event: rule_id parsed from stdout marker, command null
    // (ExitPlanMode has no command in tool_input).
    const reject_e = events.items[2];
    try std.testing.expectEqual(Action.reject, reject_e.action);
    try std.testing.expectEqualStrings("no-actually-in-plans", reject_e.rule_id.?);
    try std.testing.expectEqualStrings("ExitPlanMode", reject_e.tool_name.?);
    try std.testing.expect(reject_e.command == null);
    try std.testing.expectEqual(@as(i32, 2), reject_e.exit_code);
}

test "extractHookEvents fast-skips files lacking the PreToolUse marker" {
    // Files predating veer install (no hook_success entries at all) should
    // return empty without paying the cost of full JSON parsing.
    const content =
        \\{"type":"user","message":{"role":"user","content":"hi"}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"ok"}]}}
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Read","input":{"file_path":"/tmp/x"}}]}}
    ;
    var events = try extractHookEvents(std.testing.allocator, content);
    defer freeHookEvents(std.testing.allocator, &events);
    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "extractHookEvents returns empty when no PreToolUse entries" {
    const content =
        \\{"type":"user","message":{"role":"user","content":"hi"}}
        \\{"attachment":{"type":"hook_success","hookEvent":"SessionStart","stdout":"","stderr":"","exitCode":0,"durationMs":1},"type":"attachment"}
    ;
    var events = try extractHookEvents(std.testing.allocator, content);
    defer freeHookEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 0), events.items.len);
}

test "extractHookEvents skips malformed lines without erroring" {
    const content =
        "garbage line\n" ++
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"ls"}}]}}
        ++ "\nnot json either\n" ++
        \\{"attachment":{"type":"hook_success","hookName":"PreToolUse:Bash","toolUseID":"tu1","hookEvent":"PreToolUse","stdout":"","stderr":"","exitCode":0,"durationMs":1},"type":"attachment"}
        ;
    var events = try extractHookEvents(std.testing.allocator, content);
    defer freeHookEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expectEqual(Action.allow, events.items[0].action);
    try std.testing.expectEqualStrings("ls", events.items[0].command.?);
}

test "extractHookEvents stdout without rule_id prefix yields rule_id null" {
    // An older transcript or an allow with rule_id intentionally null.
    const content =
        \\{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"echo hi"}}]}}
    ++ "\n" ++
        \\{"attachment":{"type":"hook_success","hookName":"PreToolUse:Bash","toolUseID":"tu1","hookEvent":"PreToolUse","stdout":"{\"systemMessage\":\"`echo hi`\"}","stderr":"","exitCode":0,"durationMs":2},"type":"attachment"}
    ;
    var events = try extractHookEvents(std.testing.allocator, content);
    defer freeHookEvents(std.testing.allocator, &events);

    try std.testing.expectEqual(@as(usize, 1), events.items.len);
    try std.testing.expect(events.items[0].rule_id == null);
    try std.testing.expectEqual(Action.allow, events.items[0].action);
}

test "discoverProjectTranscripts finds .jsonl files one level deep" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_root);

    try tmp.dir.makePath("proj-a");
    try tmp.dir.makePath("proj-b");
    {
        const f = try tmp.dir.createFile("proj-a/sess1.jsonl", .{});
        f.close();
    }
    {
        const f = try tmp.dir.createFile("proj-a/sess2.jsonl", .{});
        f.close();
    }
    {
        const f = try tmp.dir.createFile("proj-a/foo.txt", .{});
        f.close();
    }
    {
        const f = try tmp.dir.createFile("proj-b/sess3.jsonl", .{});
        f.close();
    }

    var paths = try discoverProjectTranscripts(std.testing.allocator, tmp_root);
    defer freeTranscriptPaths(std.testing.allocator, &paths);

    try std.testing.expectEqual(@as(usize, 3), paths.items.len);
    var found_s1 = false;
    var found_s2 = false;
    var found_s3 = false;
    for (paths.items) |p| {
        if (std.mem.endsWith(u8, p, "sess1.jsonl")) found_s1 = true;
        if (std.mem.endsWith(u8, p, "sess2.jsonl")) found_s2 = true;
        if (std.mem.endsWith(u8, p, "sess3.jsonl")) found_s3 = true;
    }
    try std.testing.expect(found_s1);
    try std.testing.expect(found_s2);
    try std.testing.expect(found_s3);
}

test "discoverProjectTranscripts on missing root returns empty (fail open)" {
    var paths = try discoverProjectTranscripts(std.testing.allocator, "/tmp/veer-does-not-exist-xyz123");
    defer freeTranscriptPaths(std.testing.allocator, &paths);
    try std.testing.expectEqual(@as(usize, 0), paths.items.len);
}
