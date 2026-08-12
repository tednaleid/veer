// ABOUTME: Validate a veer config file and report all errors.
// ABOUTME: Reports every issue found, not just the first.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const rule_mod = @import("../config/rule.zig");

pub const ValidateOptions = struct {
    config_path: []const u8 = ".veer/config.toml",
};

/// Run the validate command. Reports all validation errors.
pub fn run(allocator: std.mem.Allocator, opts: ValidateOptions, writer: anytype) !u8 {
    var detail: ?config_mod.ParseDetail = null;
    defer if (detail) |*d| d.deinit(allocator);

    var result = config_mod.parseFileOnly(allocator, opts.config_path, &detail) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try writer.print("{s}: file not found\n", .{opts.config_path});
                return 1;
            },
            error.ParseFailed => {
                if (detail) |d| switch (d) {
                    .position => |pos| try writer.print(
                        "{s}:{d}:{d}: TOML syntax error\n",
                        .{ opts.config_path, pos.line, pos.column },
                    ),
                    .field_path => |fp| {
                        try writer.print("{s}: invalid value for ", .{opts.config_path});
                        for (fp, 0..) |seg, i| {
                            if (i > 0) try writer.print(".", .{});
                            try writer.print("{s}", .{seg});
                        }
                        try writer.print("\n", .{});
                    },
                } else {
                    try writer.print("{s}: TOML parse error\n", .{opts.config_path});
                }
                return 1;
            },
            else => {
                try writer.print("{s}: {}\n", .{ opts.config_path, err });
                return 1;
            },
        }
    };
    defer result.deinit();

    // Run detailed validation that reports all errors
    const errors = validateAll(result.value.rule);
    if (errors == 0) {
        try writer.print("{s}: OK ({d} rule{s})\n", .{
            opts.config_path,
            result.value.rule.len,
            if (result.value.rule.len == 1) "" else "s",
        });
        return 0;
    }

    try writer.print("{s}:\n", .{opts.config_path});
    for (result.value.rule, 0..) |rule, i| {
        var issues_buf: [8][]const u8 = undefined;
        var issues_len: usize = 0;

        if (rule.id.len == 0) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "missing id";
                issues_len += 1;
            }
        }

        // Check for duplicate IDs
        for (result.value.rule[0..i]) |prev| {
            if (std.mem.eql(u8, rule.id, prev.id)) {
                if (issues_len < issues_buf.len) {
                    issues_buf[issues_len] = "duplicate id";
                    issues_len += 1;
                }
                break;
            }
        }

        if (rule.tool_any != null and !std.mem.eql(u8, rule.tool, "Bash")) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "tool and tool_any are mutually exclusive";
                issues_len += 1;
            }
        }

        const action = rule.effectiveAction();
        if (action == .rewrite and rule.rewrite_to == null) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "rewrite requires rewrite_to";
                issues_len += 1;
            }
        }
        if ((action == .reject or action == .allow) and rule.message == null) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "reject requires message";
                issues_len += 1;
            }
        }
        const used = rule_mod.fieldsUsed(rule.match);
        const bad: ?[]const u8 = blk: {
            if (rule.tool_any) |tools| {
                for (tools) |t| {
                    if (rule_mod.toolFields(t)) |carried| {
                        if (used.command and !carried.command) break :blk "command matchers";
                        if (used.content and !carried.content) break :blk "content matchers";
                        if (used.path and !carried.path) break :blk "path matchers";
                    }
                }
                break :blk null;
            }
            const carried = rule_mod.toolFields(rule.tool) orelse break :blk null;
            if (used.command and !carried.command) break :blk "command matchers";
            if (used.content and !carried.content) break :blk "content matchers";
            if (used.path and !carried.path) break :blk "path matchers";
            break :blk null;
        };
        if (bad) |what| {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = what;
                issues_len += 1;
            }
        }
        if (action == .allow and used.command) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "allow does not accept command matchers";
                issues_len += 1;
            }
        }
        if (!rule_mod.hasAnyMatchPub(rule.match) and rule.tool_any == null) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "empty match";
                issues_len += 1;
            }
        }

        for (issues_buf[0..issues_len]) |issue| {
            const display_id = if (rule.id.len > 0) rule.id else "(no id)";
            try writer.print("  rule \"{s}\": {s}\n", .{ display_id, issue });
        }
    }

    return 1;
}

/// Count all validation errors without stopping at the first one.
fn validateAll(rules: []const rule_mod.Rule) usize {
    var count: usize = 0;
    for (rules, 0..) |rule, i| {
        if (rule.id.len == 0) count += 1;

        for (rules[0..i]) |prev| {
            if (std.mem.eql(u8, rule.id, prev.id)) {
                count += 1;
                break;
            }
        }

        if (rule.tool_any != null and !std.mem.eql(u8, rule.tool, "Bash")) count += 1;

        const action = rule.effectiveAction();
        if (action == .rewrite and rule.rewrite_to == null) count += 1;
        if ((action == .reject or action == .allow) and rule.message == null) count += 1;
        const used = rule_mod.fieldsUsed(rule.match);
        const mismatch = blk: {
            if (rule.tool_any) |tools| {
                for (tools) |t| {
                    if (rule_mod.toolFields(t)) |carried| {
                        if ((used.command and !carried.command) or
                            (used.content and !carried.content) or
                            (used.path and !carried.path))
                        {
                            break :blk true;
                        }
                    }
                }
                break :blk false;
            }
            const carried = rule_mod.toolFields(rule.tool) orelse break :blk false;
            break :blk (used.command and !carried.command) or
                (used.content and !carried.content) or
                (used.path and !carried.path);
        };
        if (mismatch) count += 1;
        if (action == .allow and used.command) count += 1;
        if (!rule_mod.hasAnyMatchPub(rule.match) and rule.tool_any == null) count += 1;
    }
    return count;
}

// -- Tests --

test "validate valid config reports OK" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{path});
    defer std.testing.allocator.free(config_path);

    // Write a valid config
    const file = try std.fs.cwd().createFile(config_path, .{});
    try file.writeAll(
        \\[[rule]]
        \\id = "use-just-test"
        \\action = "rewrite"
        \\rewrite_to = "just test"
        \\[rule.match]
        \\command = "pytest"
    );
    file.close();

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, .{ .config_path = config_path }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "1 rule") != null);
}

test "validate missing file reports error" {
    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, .{ .config_path = "/nonexistent/config.toml" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "not found") != null);
}

test "validate reports every invalid rule, not just the first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/c.toml", .{dir});
    defer std.testing.allocator.free(path);
    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(
            \\[[rule]]
            \\id = "first-bad"
            \\tool = "Write"
            \\message = "m"
            \\[rule.match]
            \\raw_regex = "x"
            \\
            \\[[rule]]
            \\id = "second-bad"
            \\tool = "Bash"
            \\[rule.match]
            \\command = "foo"
        );
    }

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const code = try run(std.testing.allocator, .{ .config_path = path }, stream.writer());

    const out = stream.getWritten();
    try std.testing.expectEqual(@as(u8, 1), code);
    // Both rules must appear, not just the first.
    try std.testing.expect(std.mem.indexOf(u8, out, "first-bad") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "second-bad") != null);
}

test "validate reports a rule whose only issue is a matcher/tool mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/c.toml", .{dir});
    defer std.testing.allocator.free(path);
    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(
            \\[[rule]]
            \\id = "probe"
            \\tool = "Write"
            \\message = "M"
            \\[rule.match]
            \\raw_regex = "x"
        );
    }

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const code = try run(std.testing.allocator, .{ .config_path = path }, stream.writer());

    const out = stream.getWritten();
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, out, "probe") != null);
}

test "validate accepts a tool_any rule whose matcher fits every listed tool" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/c.toml", .{dir});
    defer std.testing.allocator.free(path);
    {
        const f = try std.fs.cwd().createFile(path, .{});
        defer f.close();
        try f.writeAll(
            \\[[rule]]
            \\id = "no-gen-edits"
            \\tool_any = ["Write", "Edit"]
            \\message = "Generated."
            \\[rule.match]
            \\path_any = ["**/*.gen.ts"]
        );
    }

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const code = try run(std.testing.allocator, .{ .config_path = path }, stream.writer());

    const out = stream.getWritten();
    try std.testing.expectEqual(@as(u8, 0), code);
    try std.testing.expect(std.mem.indexOf(u8, out, "OK") != null);
}
