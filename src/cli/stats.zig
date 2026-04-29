// ABOUTME: Display usage statistics by mining Claude Code JSONL transcripts.
// ABOUTME: Aggregates hook fires across all sessions; no separate database.

const std = @import("std");
const transcript = @import("../claude/transcript.zig");
const Table = @import("../display/table.zig").Table;

pub const Action = transcript.Action;
pub const HookEvent = transcript.HookEvent;

pub const RuleHit = struct {
    rule_id: []const u8, // owned
    count: u64,
    last_seen_ms: i64,
    last_action: Action,
};

pub const CommandFreq = struct {
    command: []const u8, // owned (base command, first word)
    count: u64,
};

pub const ToolCount = struct {
    tool_name: []const u8, // owned
    count: u64,
};

pub const Aggregate = struct {
    total: u64,
    allow: u64,
    rewrite: u64,
    reject: u64,
    distinct_sessions: u64,
    rule_hits: []RuleHit,
    top_commands: []CommandFreq,
    tool_distribution: []ToolCount,
    latency_p50_ms: u64,
    latency_p99_ms: u64,
    latency_sample_count: u64,
};

/// Aggregate a slice of HookEvents into a single Aggregate. Strings inside
/// the returned struct are heap-owned (caller frees via `freeAggregate`)
/// so the events array can be freed independently.
///
/// `since_ms` filters out events older than the given unix-millis threshold.
/// Pass null to include all events.
pub fn aggregate(
    allocator: std.mem.Allocator,
    events: []const HookEvent,
    since_ms: ?i64,
) !Aggregate {
    var rules = std.StringHashMapUnmanaged(RuleHit){};
    defer rules.deinit(allocator);
    var commands = std.StringHashMapUnmanaged(u64){};
    defer commands.deinit(allocator);
    var tools = std.StringHashMapUnmanaged(u64){};
    defer tools.deinit(allocator);
    var sessions = std.StringHashMapUnmanaged(void){};
    defer sessions.deinit(allocator);
    var latencies = std.ArrayListUnmanaged(u64).empty;
    defer latencies.deinit(allocator);

    var allow: u64 = 0;
    var rewrite: u64 = 0;
    var reject: u64 = 0;

    for (events) |ev| {
        if (since_ms) |cutoff| {
            if (ev.timestamp_ms < cutoff) continue;
        }

        switch (ev.action) {
            .allow => allow += 1,
            .rewrite => rewrite += 1,
            .reject => reject += 1,
        }

        if (ev.session_id) |sid| {
            _ = try sessions.getOrPut(allocator, sid);
        }

        if (ev.tool_name) |tn| {
            const gop = try tools.getOrPut(allocator, tn);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }

        if (ev.command) |cmd| {
            // Base command is the first whitespace-delimited token.
            var iter = std.mem.tokenizeAny(u8, cmd, " \t");
            const base = iter.next() orelse cmd;
            const gop = try commands.getOrPut(allocator, base);
            if (!gop.found_existing) gop.value_ptr.* = 0;
            gop.value_ptr.* += 1;
        }

        if (ev.rule_id) |rid| {
            const gop = try rules.getOrPut(allocator, rid);
            if (gop.found_existing) {
                gop.value_ptr.count += 1;
                if (ev.timestamp_ms > gop.value_ptr.last_seen_ms) {
                    gop.value_ptr.last_seen_ms = ev.timestamp_ms;
                    gop.value_ptr.last_action = ev.action;
                }
            } else {
                gop.value_ptr.* = .{
                    .rule_id = rid, // shared ref into events; we'll dupe later
                    .count = 1,
                    .last_seen_ms = ev.timestamp_ms,
                    .last_action = ev.action,
                };
            }
        }

        if (ev.duration_ms > 0) {
            try latencies.append(allocator, ev.duration_ms);
        }
    }

    // Materialize and sort each table (descending by count).
    var rule_list = try allocator.alloc(RuleHit, rules.count());
    errdefer allocator.free(rule_list);
    {
        var it = rules.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            rule_list[i] = .{
                .rule_id = try allocator.dupe(u8, kv.value_ptr.rule_id),
                .count = kv.value_ptr.count,
                .last_seen_ms = kv.value_ptr.last_seen_ms,
                .last_action = kv.value_ptr.last_action,
            };
        }
    }
    std.mem.sort(RuleHit, rule_list, {}, struct {
        fn cmp(_: void, a: RuleHit, b: RuleHit) bool {
            return a.count > b.count;
        }
    }.cmp);

    var cmd_list = try allocator.alloc(CommandFreq, commands.count());
    errdefer allocator.free(cmd_list);
    {
        var it = commands.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            cmd_list[i] = .{
                .command = try allocator.dupe(u8, kv.key_ptr.*),
                .count = kv.value_ptr.*,
            };
        }
    }
    std.mem.sort(CommandFreq, cmd_list, {}, struct {
        fn cmp(_: void, a: CommandFreq, b: CommandFreq) bool {
            return a.count > b.count;
        }
    }.cmp);

    var tool_list = try allocator.alloc(ToolCount, tools.count());
    errdefer allocator.free(tool_list);
    {
        var it = tools.iterator();
        var i: usize = 0;
        while (it.next()) |kv| : (i += 1) {
            tool_list[i] = .{
                .tool_name = try allocator.dupe(u8, kv.key_ptr.*),
                .count = kv.value_ptr.*,
            };
        }
    }
    std.mem.sort(ToolCount, tool_list, {}, struct {
        fn cmp(_: void, a: ToolCount, b: ToolCount) bool {
            return a.count > b.count;
        }
    }.cmp);

    // Latency percentiles (only over events that had a measured duration).
    var p50: u64 = 0;
    var p99: u64 = 0;
    if (latencies.items.len > 0) {
        std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));
        p50 = latencies.items[latencies.items.len / 2];
        const p99_idx = (latencies.items.len * 99) / 100;
        p99 = latencies.items[@min(p99_idx, latencies.items.len - 1)];
    }

    return .{
        .total = allow + rewrite + reject,
        .allow = allow,
        .rewrite = rewrite,
        .reject = reject,
        .distinct_sessions = sessions.count(),
        .rule_hits = rule_list,
        .top_commands = cmd_list,
        .tool_distribution = tool_list,
        .latency_p50_ms = p50,
        .latency_p99_ms = p99,
        .latency_sample_count = latencies.items.len,
    };
}

pub fn freeAggregate(allocator: std.mem.Allocator, agg: *Aggregate) void {
    for (agg.rule_hits) |r| allocator.free(r.rule_id);
    allocator.free(agg.rule_hits);
    for (agg.top_commands) |c| allocator.free(c.command);
    allocator.free(agg.top_commands);
    for (agg.tool_distribution) |t| allocator.free(t.tool_name);
    allocator.free(agg.tool_distribution);
}

/// Parse a `--since` argument like "24h", "7d", "30m" into a millisecond
/// duration (NOT an absolute time). Caller subtracts from `now` to get the
/// cutoff. Returns null if unparseable.
pub fn parseSince(s: []const u8) ?u64 {
    if (s.len < 2) return null;
    const unit_char = s[s.len - 1];
    const num_str = s[0 .. s.len - 1];
    const num = std.fmt.parseInt(u64, num_str, 10) catch return null;
    return switch (unit_char) {
        's' => num * 1000,
        'm' => num * 60 * 1000,
        'h' => num * 60 * 60 * 1000,
        'd' => num * 24 * 60 * 60 * 1000,
        else => null,
    };
}

/// Format an Aggregate for human display.
pub fn formatStats(
    allocator: std.mem.Allocator,
    writer: anytype,
    agg: Aggregate,
    since_label: []const u8,
    transcripts_count: usize,
) !void {
    if (agg.total == 0) {
        try writer.print("No hook fires found ({s}).\n", .{since_label});
        return;
    }

    try writer.print("Stats ({s}, {d} hook fires across {d} sessions in {d} transcripts):\n\n", .{
        since_label, agg.total, agg.distinct_sessions, transcripts_count,
    });
    try writer.print("  Outcome: {d} allow | {d} rewrite | {d} reject\n\n", .{
        agg.allow, agg.rewrite, agg.reject,
    });

    if (agg.rule_hits.len > 0) {
        try writer.print("  Top rules:\n", .{});
        const limit = @min(agg.rule_hits.len, 10);
        for (agg.rule_hits[0..limit]) |r| {
            try writer.print("    {s: <30} {d: >5}  {s}\n", .{
                r.rule_id, r.count, @tagName(r.last_action),
            });
        }
        try writer.print("\n", .{});
    }

    if (agg.top_commands.len > 0) {
        try writer.print("  Top commands (Bash):\n", .{});
        const limit = @min(agg.top_commands.len, 10);
        for (agg.top_commands[0..limit]) |c| {
            try writer.print("    {s: <30} {d: >5}\n", .{ c.command, c.count });
        }
        try writer.print("\n", .{});
    }

    if (agg.tool_distribution.len > 0) {
        try writer.print("  Tool distribution:\n", .{});
        for (agg.tool_distribution) |t| {
            try writer.print("    {s: <20} {d: >5}\n", .{ t.tool_name, t.count });
        }
        try writer.print("\n", .{});
    }

    if (agg.latency_sample_count > 0) {
        try writer.print("  Hook latency: p50 {d}ms, p99 {d}ms (over {d} samples)\n", .{
            agg.latency_p50_ms, agg.latency_p99_ms, agg.latency_sample_count,
        });
    }

    _ = allocator;
}

/// Run the stats command. Walks `projects_root` for transcripts, extracts
/// hook events, aggregates, and formats output. `since_ms_duration` of null
/// means all-time.
pub fn run(
    allocator: std.mem.Allocator,
    projects_root: []const u8,
    since_ms_duration: ?u64,
    writer: anytype,
) !u8 {
    const now_ms = std.time.milliTimestamp();
    const cutoff: ?i64 = if (since_ms_duration) |d|
        now_ms - @as(i64, @intCast(d))
    else
        null;

    var transcripts = transcript.discoverProjectTranscripts(allocator, projects_root) catch
        std.ArrayListUnmanaged([]u8).empty;
    defer transcript.freeTranscriptPaths(allocator, &transcripts);

    if (transcripts.items.len == 0) {
        try writer.print("No transcripts found at {s}.\n", .{projects_root});
        return 0;
    }

    var all_events = std.ArrayListUnmanaged(HookEvent).empty;
    defer transcript.freeHookEvents(allocator, &all_events);

    for (transcripts.items) |path| {
        const f = std.fs.cwd().openFile(path, .{}) catch continue;
        defer f.close();
        const content = f.readToEndAlloc(allocator, 64 * 1024 * 1024) catch continue;
        defer allocator.free(content);

        var events = transcript.extractHookEvents(allocator, content) catch continue;
        // Move ownership: append items to all_events, clear the source list
        // without freeing strings.
        try all_events.appendSlice(allocator, events.items);
        events.deinit(allocator);
    }

    const since_label = if (since_ms_duration) |d| blk: {
        // Format the duration back into a human label.
        if (d % (24 * 60 * 60 * 1000) == 0) {
            break :blk try std.fmt.allocPrint(allocator, "since {d}d", .{d / (24 * 60 * 60 * 1000)});
        } else if (d % (60 * 60 * 1000) == 0) {
            break :blk try std.fmt.allocPrint(allocator, "since {d}h", .{d / (60 * 60 * 1000)});
        } else if (d % (60 * 1000) == 0) {
            break :blk try std.fmt.allocPrint(allocator, "since {d}m", .{d / (60 * 1000)});
        } else {
            break :blk try std.fmt.allocPrint(allocator, "since {d}s", .{d / 1000});
        }
    } else try allocator.dupe(u8, "all time");
    defer allocator.free(since_label);

    var agg = try aggregate(allocator, all_events.items, cutoff);
    defer freeAggregate(allocator, &agg);

    try formatStats(allocator, writer, agg, since_label, transcripts.items.len);
    return 0;
}

// -- Tests --

const test_events_jsonl =
    \\{"type":"assistant","sessionId":"sess-1","timestamp":"2026-04-28T22:00:00Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu1","name":"Bash","input":{"command":"pytest tests/"}}]}}
    \\{"type":"assistant","sessionId":"sess-1","timestamp":"2026-04-28T22:00:01Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{"command":"ls -la"}}]}}
    \\{"type":"assistant","sessionId":"sess-2","timestamp":"2026-04-28T22:00:02Z","message":{"role":"assistant","content":[{"type":"tool_use","id":"tu3","name":"Bash","input":{"command":"pytest other/"}}]}}
    \\{"type":"attachment","sessionId":"sess-1","timestamp":"2026-04-28T22:00:00.500Z","attachment":{"type":"hook_success","hookName":"PreToolUse:Bash","toolUseID":"tu1","hookEvent":"PreToolUse","stdout":"{\"systemMessage\":\"[use-just-test] `pytest tests/` -> `just test`\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"just test\"}}}","stderr":"","exitCode":0,"durationMs":12}}
    \\{"type":"attachment","sessionId":"sess-1","timestamp":"2026-04-28T22:00:01.500Z","attachment":{"type":"hook_success","hookName":"PreToolUse:Bash","toolUseID":"tu2","hookEvent":"PreToolUse","stdout":"","stderr":"","exitCode":0,"durationMs":3}}
    \\{"type":"attachment","sessionId":"sess-2","timestamp":"2026-04-28T22:00:02.500Z","attachment":{"type":"hook_success","hookName":"PreToolUse:Bash","toolUseID":"tu3","hookEvent":"PreToolUse","stdout":"{\"systemMessage\":\"[use-just-test] `pytest other/` -> `just test`\",\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"allow\",\"updatedInput\":{\"command\":\"just test\"}}}","stderr":"","exitCode":0,"durationMs":15}}
;

test "aggregate produces correct outcome counts and distinct sessions" {
    var events = try transcript.extractHookEvents(std.testing.allocator, test_events_jsonl);
    defer transcript.freeHookEvents(std.testing.allocator, &events);

    var agg = try aggregate(std.testing.allocator, events.items, null);
    defer freeAggregate(std.testing.allocator, &agg);

    try std.testing.expectEqual(@as(u64, 3), agg.total);
    try std.testing.expectEqual(@as(u64, 1), agg.allow);
    try std.testing.expectEqual(@as(u64, 2), agg.rewrite);
    try std.testing.expectEqual(@as(u64, 0), agg.reject);
    try std.testing.expectEqual(@as(u64, 2), agg.distinct_sessions);
}

test "aggregate ranks rules by count" {
    var events = try transcript.extractHookEvents(std.testing.allocator, test_events_jsonl);
    defer transcript.freeHookEvents(std.testing.allocator, &events);

    var agg = try aggregate(std.testing.allocator, events.items, null);
    defer freeAggregate(std.testing.allocator, &agg);

    try std.testing.expectEqual(@as(usize, 1), agg.rule_hits.len);
    try std.testing.expectEqualStrings("use-just-test", agg.rule_hits[0].rule_id);
    try std.testing.expectEqual(@as(u64, 2), agg.rule_hits[0].count);
}

test "aggregate ranks commands by base command" {
    var events = try transcript.extractHookEvents(std.testing.allocator, test_events_jsonl);
    defer transcript.freeHookEvents(std.testing.allocator, &events);

    var agg = try aggregate(std.testing.allocator, events.items, null);
    defer freeAggregate(std.testing.allocator, &agg);

    // pytest fires twice (tu1, tu3), ls once (tu2).
    try std.testing.expect(agg.top_commands.len >= 2);
    try std.testing.expectEqualStrings("pytest", agg.top_commands[0].command);
    try std.testing.expectEqual(@as(u64, 2), agg.top_commands[0].count);
}

test "aggregate computes latency percentiles over measured durations" {
    var events = try transcript.extractHookEvents(std.testing.allocator, test_events_jsonl);
    defer transcript.freeHookEvents(std.testing.allocator, &events);

    var agg = try aggregate(std.testing.allocator, events.items, null);
    defer freeAggregate(std.testing.allocator, &agg);

    // Durations 12, 3, 15 -> p50 is the middle (12), p99 is max (15).
    try std.testing.expectEqual(@as(u64, 3), agg.latency_sample_count);
    try std.testing.expectEqual(@as(u64, 12), agg.latency_p50_ms);
    try std.testing.expectEqual(@as(u64, 15), agg.latency_p99_ms);
}

test "aggregate with since_ms filters older events" {
    var events = try transcript.extractHookEvents(std.testing.allocator, test_events_jsonl);
    defer transcript.freeHookEvents(std.testing.allocator, &events);

    // Cutoff after the second hook event -- only the third should remain.
    // Fixture timestamps: 22:00:00.5, 22:00:01.5, 22:00:02.5
    // Pick a cutoff at 22:00:02.0 (2026-04-28).
    const ts = transcript.parseIso8601Millis("2026-04-28T22:00:02Z");
    var agg = try aggregate(std.testing.allocator, events.items, ts);
    defer freeAggregate(std.testing.allocator, &agg);

    try std.testing.expectEqual(@as(u64, 1), agg.total);
}

test "parseSince parses common units" {
    try std.testing.expectEqual(@as(u64, 30 * 1000), parseSince("30s").?);
    try std.testing.expectEqual(@as(u64, 5 * 60 * 1000), parseSince("5m").?);
    try std.testing.expectEqual(@as(u64, 24 * 60 * 60 * 1000), parseSince("24h").?);
    try std.testing.expectEqual(@as(u64, 7 * 24 * 60 * 60 * 1000), parseSince("7d").?);
}

test "parseSince rejects garbage" {
    try std.testing.expect(parseSince("abc") == null);
    try std.testing.expect(parseSince("12") == null);
    try std.testing.expect(parseSince("12x") == null);
    try std.testing.expect(parseSince("") == null);
}

test "formatStats renders headline + sections for a populated aggregate" {
    var events = try transcript.extractHookEvents(std.testing.allocator, test_events_jsonl);
    defer transcript.freeHookEvents(std.testing.allocator, &events);

    var agg = try aggregate(std.testing.allocator, events.items, null);
    defer freeAggregate(std.testing.allocator, &agg);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatStats(std.testing.allocator, stream.writer(), agg, "all time", 1);

    const out = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, out, "Stats (all time") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "use-just-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Top commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pytest") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Tool distribution") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Hook latency") != null);
}

test "formatStats prints no-data message on empty aggregate" {
    const empty = Aggregate{
        .total = 0,
        .allow = 0,
        .rewrite = 0,
        .reject = 0,
        .distinct_sessions = 0,
        .rule_hits = &.{},
        .top_commands = &.{},
        .tool_distribution = &.{},
        .latency_p50_ms = 0,
        .latency_p99_ms = 0,
        .latency_sample_count = 0,
    };
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try formatStats(std.testing.allocator, stream.writer(), empty, "all time", 0);
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "No hook fires") != null);
}

test "run on missing projects root prints friendly message and exits 0" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const code = try run(std.testing.allocator, "/tmp/veer-stats-missing-xyz", null, stream.writer());
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, stream.getWritten(), "No transcripts") != null);
}
