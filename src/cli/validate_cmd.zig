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
    var result = config_mod.loadFile(allocator, opts.config_path) catch |err| {
        switch (err) {
            error.FileNotFound => {
                try writer.print("{s}: file not found\n", .{opts.config_path});
                return 1;
            },
            error.ParseFailed => {
                try writer.print("{s}: TOML parse error\n", .{opts.config_path});
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

        const action = rule.effectiveAction();
        if (action == .rewrite and rule.rewrite_to == null) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "rewrite requires rewrite_to";
                issues_len += 1;
            }
        }
        if (action == .reject and rule.message == null) {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = "reject requires message";
                issues_len += 1;
            }
        }
        if (!rule_mod.hasAnyMatchPub(rule.match)) {
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

        const action = rule.effectiveAction();
        if (action == .rewrite and rule.rewrite_to == null) count += 1;
        if (action == .reject and rule.message == null) count += 1;
        if (!rule_mod.hasAnyMatchPub(rule.match)) count += 1;
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
