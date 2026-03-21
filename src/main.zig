// ABOUTME: Entry point for veer, a Claude Code PreToolUse hook that redirects
// ABOUTME: agent tool calls toward safer, project-appropriate alternatives.

const std = @import("std");
const config_mod = @import("config/config.zig");
const check_cmd = @import("cli/check.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var args = std.process.args();
    _ = args.skip(); // skip program name

    const command = args.next() orelse {
        printUsage();
        std.process.exit(1);
    };

    if (std.mem.eql(u8, command, "check")) {
        try runCheck(allocator, &args);
    } else {
        printUsage();
        std.process.exit(1);
    }
}

fn runCheck(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    // Check for --config flag
    var config_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next();
        }
    }

    // Load config
    var rules: []const config_mod.Rule = &.{};
    var parsed_config: ?@import("toml").Parsed(config_mod.Config) = null;
    defer if (parsed_config) |*pc| pc.deinit();

    if (config_path) |path| {
        if (config_mod.loadFile(allocator, path)) |result| {
            parsed_config = result;
            rules = result.value.rule;
        } else |_| {
            std.debug.print("veer: failed to load config: {s}\n", .{path});
            std.process.exit(1);
        }
    }
    // TODO: loadMerged for default config discovery (Stage 5)

    // Read stdin
    const stdin_data = std.fs.File.stdin().readToEndAlloc(allocator, 1024 * 1024) catch {
        std.debug.print("veer: failed to read stdin\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(stdin_data);

    // Run check
    var stdout_buf: [4096]u8 = undefined;
    var stdout_stream = std.io.fixedBufferStream(&stdout_buf);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_stream = std.io.fixedBufferStream(&stderr_buf);

    const exit_code = check_cmd.run(
        allocator,
        rules,
        stdin_data,
        stdout_stream.writer(),
        stderr_stream.writer(),
    ) catch {
        std.debug.print("veer: internal error during check\n", .{});
        std.process.exit(1);
    };

    // Write buffered output to real stdout/stderr
    const stdout_output = stdout_stream.getWritten();
    const stderr_output = stderr_stream.getWritten();

    if (stdout_output.len > 0) {
        const stdout = std.fs.File.stdout();
        _ = stdout.write(stdout_output) catch {};
    }
    if (stderr_output.len > 0) {
        const stderr_file = std.fs.File.stderr();
        _ = stderr_file.write(stderr_output) catch {};
    }

    std.process.exit(exit_code);
}

fn printUsage() void {
    std.debug.print(
        \\Usage: veer <command>
        \\
        \\Commands:
        \\  check    Evaluate a tool call against rules (PreToolUse hook)
        \\
        \\Options:
        \\  check --config <path>  Use a specific config file
        \\
    , .{});
}
