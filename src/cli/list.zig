// ABOUTME: Display current veer rules in a formatted table.
// ABOUTME: Loads merged config (local, project, and global) and renders rule summary.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const Table = @import("../display/table.zig").Table;

/// Run the list command. Outputs rules table to writer.
/// `sources` is parallel to `rules` when non-null (i.e. when the rules came
/// from `loadMerged`); the rendered table then includes a `Source` column.
/// Pass `null` for explicit single-file loads to keep the table compact.
pub fn run(
    allocator: std.mem.Allocator,
    rules: []const config_mod.Rule,
    sources: ?[]const config_mod.RuleSource,
    writer: anytype,
) !u8 {
    if (rules.len == 0) {
        try writer.print("No rules configured.\n", .{});
        return 0;
    }

    const show_source = sources != null;
    if (show_source) std.debug.assert(sources.?.len == rules.len);

    // Match strings are composed per-row; lifetime must outlive table.render.
    // An arena scoped to this function is the simplest way to do that.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var table = if (show_source)
        Table{ .headers = &.{ "ID", "Source", "Action", "Tool", "Match", "Message" } }
    else
        Table{ .headers = &.{ "ID", "Action", "Tool", "Match", "Message" } };
    defer table.deinit(allocator);

    for (rules, 0..) |rule, i| {
        const match_str = try formatMatch(arena_alloc, rule.match);
        const message = if (rule.message) |m| truncate(m, 40) else "";
        const action_str = @tagName(rule.effectiveAction());
        const tool_str = if (rule.tool_any) |tools| blk: {
            var parts: std.ArrayListUnmanaged(u8) = .empty;
            for (tools, 0..) |t, ti| {
                if (ti > 0) try parts.appendSlice(arena_alloc, ",");
                try parts.appendSlice(arena_alloc, t);
            }
            break :blk try parts.toOwnedSlice(arena_alloc);
        } else rule.tool;
        if (show_source) {
            const src_str = @tagName(sources.?[i]);
            try table.addRow(allocator, &.{ rule.id, src_str, action_str, tool_str, match_str, message });
        } else {
            try table.addRow(allocator, &.{ rule.id, action_str, tool_str, match_str, message });
        }
    }

    try table.render(writer);
    try writer.print("\n{d} rule(s)\n", .{rules.len});
    return 0;
}

/// Render a `MatchConfig` as a single readable line for the `Match` column.
/// AND-combined fields are space-separated; lists use brace expansion; regex
/// fields are wrapped in `/.../`. Memory comes from `arena`.
pub fn formatMatch(arena: std.mem.Allocator, m: config_mod.MatchConfig) ![]const u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    var aw = buf.writer(arena);

    // -- command portion --
    if (m.command_all) |cmds| {
        for (cmds, 0..) |c, i| {
            if (i > 0) try aw.writeAll(" | ");
            try aw.writeAll(c);
        }
    } else if (m.command_any) |cmds| {
        try writeBraceList(&aw, cmds);
    } else if (m.command) |c| {
        try aw.writeAll(c);
    } else if (m.command_regex) |r| {
        try aw.print("/{s}/", .{r});
    }

    // -- positional args --
    if (m.arg) |a| try writeAfterSep(&aw, &buf, a);
    if (m.arg_all) |args| for (args) |a| try writeAfterSep(&aw, &buf, a);
    if (m.arg_any) |args| {
        try ensureSep(&aw, &buf);
        try writeBraceList(&aw, args);
    }
    if (m.arg_regex) |r| {
        try ensureSep(&aw, &buf);
        try aw.print("arg /{s}/", .{r});
    }

    // -- flags --
    if (m.flag) |f| try writeFlag(&aw, &buf, f);
    if (m.flag_all) |fs| for (fs) |f| try writeFlag(&aw, &buf, f);
    if (m.flag_any) |fs| {
        try ensureSep(&aw, &buf);
        try aw.writeByte('{');
        for (fs, 0..) |f, i| {
            if (i > 0) try aw.writeByte(',');
            try writeFlagBare(&aw, f);
        }
        try aw.writeByte('}');
    }

    // -- whole-input regex --
    if (m.raw_regex) |r| {
        try ensureSep(&aw, &buf);
        try aw.print("raw /{s}/", .{r});
    }

    // -- content (non-Bash) --
    if (m.content_regex) |r| {
        try ensureSep(&aw, &buf);
        try aw.print("/{s}/", .{r});
    }
    if (m.content_contains) |s| {
        try ensureSep(&aw, &buf);
        try aw.print("\"{s}\"", .{s});
    }

    // -- path (non-Bash) --
    if (m.path) |p| {
        try ensureSep(&aw, &buf);
        try aw.writeAll(p);
    }
    if (m.path_any) |paths| {
        try ensureSep(&aw, &buf);
        try writeBraceList(&aw, paths);
    }
    if (m.path_regex) |r| {
        try ensureSep(&aw, &buf);
        try aw.print("/{s}/", .{r});
    }

    // -- ast shape --
    if (m.ast) |a| {
        try ensureSep(&aw, &buf);
        try aw.writeAll("ast(");
        var first = true;
        if (a.has_node) |n| {
            try aw.writeAll(n);
            first = false;
        }
        if (a.min_depth) |d| {
            if (!first) try aw.writeByte(',');
            try aw.print("min_depth={d}", .{d});
            first = false;
        }
        if (a.min_count) |c| {
            if (!first) try aw.writeByte(',');
            try aw.print("min_count={d}", .{c});
        }
        try aw.writeByte(')');
    }

    if (buf.items.len == 0) try aw.writeAll("(any)");
    return buf.items;
}

fn ensureSep(aw: anytype, buf: *std.ArrayListUnmanaged(u8)) !void {
    if (buf.items.len > 0) try aw.writeByte(' ');
}

fn writeAfterSep(aw: anytype, buf: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    try ensureSep(aw, buf);
    try aw.writeAll(s);
}

fn writeBraceList(aw: anytype, items: []const []const u8) !void {
    try aw.writeByte('{');
    for (items, 0..) |s, i| {
        if (i > 0) try aw.writeByte(',');
        try aw.writeAll(s);
    }
    try aw.writeByte('}');
}

fn writeFlag(aw: anytype, buf: *std.ArrayListUnmanaged(u8), name: []const u8) !void {
    try ensureSep(aw, buf);
    try writeFlagBare(aw, name);
}

/// Single-char names render as `-X`, longer names as `--XX`. Mirrors the
/// matcher's own short/long flag semantics so the rendered preview matches
/// what users will type.
fn writeFlagBare(aw: anytype, name: []const u8) !void {
    if (name.len == 1) try aw.writeAll("-") else try aw.writeAll("--");
    try aw.writeAll(name);
}

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

// -- Tests --

test "list with rules renders table" {
    const rules = [_]config_mod.Rule{
        .{ .id = "use-just-test", .rewrite_to = "just test", .message = "Use just test.", .match = .{ .command = "pytest" } },
        .{ .id = "no-curl-bash", .message = "Don't pipe curl to bash.", .match = .{ .command_all = &.{ "curl", "bash" } } },
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, null, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "use-just-test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "rewrite") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "2 rule(s)") != null);
    // Single-file load: no Source column.
    try std.testing.expect(std.mem.indexOf(u8, output, "Source") == null);
    // New columns are present.
    try std.testing.expect(std.mem.indexOf(u8, output, "Tool") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Match") != null);
    // Bash is the default tool; command_all renders as a pipeline summary.
    try std.testing.expect(std.mem.indexOf(u8, output, "Bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "curl | bash") != null);
}

test "list renders tool_any as a comma-joined list" {
    const rules = [_]config_mod.Rule{
        .{
            .id = "no-gen-edits",
            .tool_any = &.{ "Write", "Edit", "NotebookEdit" },
            .message = "Generated.",
            .match = .{ .path_any = &.{"**/*.gen.ts"} },
        },
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, null, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Write,Edit,NotebookEdit") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "**/*.gen.ts") != null);
}

test "list renders a path gate's match instead of (any)" {
    const rules = [_]config_mod.Rule{
        .{
            .id = "src-only-writes",
            .action = .allow,
            .tool_any = &.{ "Write", "Edit" },
            .message = "Writes must stay under src/.",
            .match = .{ .path_any = &.{"src/**"} },
        },
    };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, null, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "{src/**}") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(any)") == null);
}

test "list with no rules" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &.{}, null, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "No rules") != null);
}

test "list with sources renders Source column" {
    const rules = [_]config_mod.Rule{
        .{ .id = "p-rule", .message = "from project", .match = .{ .command = "foo" } },
        .{ .id = "g-rule", .message = "from global", .match = .{ .command = "bar" } },
    };
    const sources = [_]config_mod.RuleSource{ .project, .global };

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, &sources, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Source") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "project") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "global") != null);
}

test "list with local source renders local in Source column" {
    const rules = [_]config_mod.Rule{
        .{ .id = "l-rule", .message = "from local", .match = .{ .command = "baz" } },
    };
    const sources = [_]config_mod.RuleSource{.local};

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, &sources, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "Source") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "local") != null);
}

// -- formatMatch unit tests --

fn expectFormat(expected: []const u8, m: config_mod.MatchConfig) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const got = try formatMatch(arena.allocator(), m);
    try std.testing.expectEqualStrings(expected, got);
}

test "formatMatch: bare command" {
    try expectFormat("zig", .{ .command = "zig" });
}

test "formatMatch: command + arg + long flag" {
    try expectFormat("zig fmt --check", .{
        .command = "zig",
        .arg = "fmt",
        .flag = "check",
    });
}

test "formatMatch: command + arg_all + long flag (zig build test --fuzz)" {
    try expectFormat("zig build test --fuzz", .{
        .command = "zig",
        .arg_all = &.{ "build", "test" },
        .flag = "fuzz",
    });
}

test "formatMatch: short flag uses single dash" {
    try expectFormat("rm -r -f", .{
        .command = "rm",
        .flag_all = &.{ "r", "f" },
    });
}

test "formatMatch: command_all renders as pipeline" {
    try expectFormat("curl | bash", .{ .command_all = &.{ "curl", "bash" } });
}

test "formatMatch: command_any uses brace list" {
    try expectFormat("{ruff,uvx}", .{ .command_any = &.{ "ruff", "uvx" } });
}

test "formatMatch: command_regex wrapped in slashes" {
    try expectFormat("/python[23]?/", .{ .command_regex = "python[23]?" });
}

test "formatMatch: arg_regex carries an arg label" {
    try expectFormat("git arg /\\.py$/", .{
        .command = "git",
        .arg_regex = "\\.py$",
    });
}

test "formatMatch: flag_any in brace list with mixed lengths" {
    try expectFormat("git {-f,--force}", .{
        .command = "git",
        .flag_any = &.{ "f", "force" },
    });
}

test "formatMatch: content_regex (non-Bash tool)" {
    try expectFormat("/[Aa]ctually/", .{ .content_regex = "[Aa]ctually" });
}

test "formatMatch: path (non-Bash tool)" {
    try expectFormat("src/**", .{ .path = "src/**" });
}

test "formatMatch: path_any uses brace list" {
    try expectFormat("{src/**,dist/**}", .{ .path_any = &.{ "src/**", "dist/**" } });
}

test "formatMatch: path_regex wrapped in slashes" {
    try expectFormat("/\\.gen\\.[jt]s$/", .{ .path_regex = "\\.gen\\.[jt]s$" });
}

test "formatMatch: content_contains" {
    try expectFormat("\"TODO\"", .{ .content_contains = "TODO" });
}

test "formatMatch: ast block" {
    try expectFormat("ast(pipeline,min_count=4)", .{
        .ast = .{ .has_node = "pipeline", .min_count = 4 },
    });
}

test "formatMatch: empty match falls back to (any)" {
    try expectFormat("(any)", .{});
}
