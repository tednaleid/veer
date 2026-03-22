// ABOUTME: Test a command against veer rules without crafting hook JSON.
// ABOUTME: Prints which rule matched, the action, and relevant details.

const std = @import("std");
const config_mod = @import("../config/config.zig");
const engine = @import("../engine/engine.zig");
const Rule = @import("../config/rule.zig").Rule;
const Action = @import("../config/rule.zig").Action;
const color = @import("../display/color.zig");

pub const TestOptions = struct {
    command: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
};

/// Run the test command. Tests command(s) against loaded rules.
pub fn run(allocator: std.mem.Allocator, rules: []const Rule, opts: TestOptions, writer: anytype) !u8 {
    if (opts.file_path) |path| {
        return runFile(allocator, rules, path, writer);
    }

    const command = opts.command orelse {
        try writer.print("veer test: command argument or --file required\n", .{});
        try writer.print("Usage: veer test \"<command>\" [--config <path>]\n", .{});
        try writer.print("       veer test --file <path> [--config <path>]\n", .{});
        return 1;
    };

    return checkOne(allocator, rules, command, writer);
}

/// Check every non-empty, non-comment line in a file.
fn runFile(allocator: std.mem.Allocator, rules: []const Rule, path: []const u8, writer: anytype) !u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
        try writer.print("veer test: cannot read {s}\n", .{path});
        return 1;
    };
    defer allocator.free(content);

    var iter = std.mem.splitScalar(u8, content, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        if (trimmed[0] == '#') continue;
        _ = try checkOne(allocator, rules, trimmed, writer);
    }

    return 0;
}

fn checkOne(allocator: std.mem.Allocator, rules: []const Rule, command: []const u8, writer: anytype) !u8 {
    const result = engine.check(allocator, rules, "Bash", command, null);

    // TSV: result, return_code, input, id, output
    if (result.action) |action| {
        switch (action) {
            .rewrite => {
                try writer.print("REWRITE\t0\t{s}\t{s}\t{s}\n", .{
                    command,
                    result.rule_id orelse "",
                    result.rewrite_to orelse "",
                });
            },
            .reject => {
                try writer.print("REJECT\t2\t{s}\t{s}\t{s}\n", .{
                    command,
                    result.rule_id orelse "",
                    result.message orelse "",
                });
            },
        }
    } else {
        try writer.print("ALLOW\t0\t{s}\t\t\n", .{command});
    }

    return 0;
}

// -- Tests --

test "test command shows REWRITE TSV" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, .{ .command = "pytest tests/" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("REWRITE\t0\tpytest tests/\tuse-just-test\tjust test\n", stream.getWritten());
}

test "test command shows REJECT TSV" {
    const rules = [_]Rule{.{
        .id = "no-chmod",
        .message = "Avoid world-writable permissions",
        .match = .{ .command = "chmod" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, .{ .command = "chmod 777 server.py" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("REJECT\t2\tchmod 777 server.py\tno-chmod\tAvoid world-writable permissions\n", stream.getWritten());
}

test "test command shows ALLOW TSV" {
    const rules = [_]Rule{.{
        .id = "use-just-test",
        .rewrite_to = "just test",
        .match = .{ .command = "pytest" },
    }};

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, .{ .command = "ls -la" }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    try std.testing.expectEqualStrings("ALLOW\t0\tls -la\t\t\n", stream.getWritten());
}

test "test command without argument returns error" {
    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &.{}, .{}, stream.writer());

    try std.testing.expectEqual(@as(u8, 1), exit_code);
}

test "test --file checks each line" {
    const rules = [_]Rule{
        .{ .id = "use-just-test", .rewrite_to = "just test", .match = .{ .command = "pytest" } },
        .{ .id = "no-chmod", .message = "nope", .match = .{ .command = "chmod" } },
    };

    // Create a temp file with commands
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const file = try tmp.dir.createFile("commands.txt", .{});
    try file.writeAll("# comment\npytest tests/\n\nchmod 777 foo\nls -la\n");
    file.close();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "commands.txt");
    defer std.testing.allocator.free(path);

    var buf: [2048]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = try run(std.testing.allocator, &rules, .{ .file_path = path }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);
    const output = stream.getWritten();
    try std.testing.expect(std.mem.indexOf(u8, output, "REWRITE\t0\tpytest tests/\tuse-just-test\tjust test") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "REJECT\t2\tchmod 777 foo\tno-chmod\tnope") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "ALLOW\t0\tls -la\t\t") != null);
}
