// ABOUTME: Entry point for veer, a Claude Code PreToolUse hook that redirects
// ABOUTME: agent tool calls toward safer, project-appropriate alternatives.

const std = @import("std");
const config_mod = @import("config/config.zig");
const check_cmd = @import("cli/check.zig");
const install_cmd = @import("cli/install.zig");
const list_cmd = @import("cli/list.zig");
const add_cmd = @import("cli/add.zig");
const remove_cmd = @import("cli/remove.zig");
const stats_cmd = @import("cli/stats.zig");

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
    } else if (std.mem.eql(u8, command, "install")) {
        try runInstall(allocator, &args);
    } else if (std.mem.eql(u8, command, "list")) {
        try runList(allocator, &args);
    } else if (std.mem.eql(u8, command, "add")) {
        try runAdd(allocator, &args);
    } else if (std.mem.eql(u8, command, "remove")) {
        try runRemove(allocator, &args);
    } else if (std.mem.eql(u8, command, "stats")) {
        try runStats(allocator);
    } else {
        printUsage();
        std.process.exit(1);
    }
}

fn runCheck(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var config_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next();
        }
    }

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

    const stdin_data = std.fs.File.stdin().readToEndAlloc(allocator, 1024 * 1024) catch {
        std.debug.print("veer: failed to read stdin\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(stdin_data);

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

    const stdout_output = stdout_stream.getWritten();
    const stderr_output = stderr_stream.getWritten();
    if (stdout_output.len > 0) _ = std.fs.File.stdout().write(stdout_output) catch {};
    if (stderr_output.len > 0) _ = std.fs.File.stderr().write(stderr_output) catch {};

    std.process.exit(exit_code);
}

fn runInstall(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var opts = install_cmd.InstallOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--global")) opts.global = true;
        if (std.mem.eql(u8, arg, "--force")) opts.force = true;
        if (std.mem.eql(u8, arg, "--uninstall")) opts.uninstall = true;
    }

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = install_cmd.run(allocator, opts, stream.writer()) catch {
        std.debug.print("veer install: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
}

fn runList(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var config_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) config_path = args.next();
    }

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

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = list_cmd.run(allocator, rules, stream.writer()) catch {
        std.debug.print("veer list: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
}

fn runAdd(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var opts = add_cmd.AddOptions{};
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--action")) opts.action = args.next();
        if (std.mem.eql(u8, arg, "--command")) opts.command = args.next();
        if (std.mem.eql(u8, arg, "--id")) opts.id = args.next();
        if (std.mem.eql(u8, arg, "--name")) opts.name = args.next();
        if (std.mem.eql(u8, arg, "--message")) opts.message = args.next();
        if (std.mem.eql(u8, arg, "--rewrite-to")) opts.rewrite_to = args.next();
        if (std.mem.eql(u8, arg, "--priority")) opts.priority = args.next();
        if (std.mem.eql(u8, arg, "--config")) opts.config_path = args.next() orelse ".veer/config.toml";
    }

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = add_cmd.run(allocator, opts, stream.writer()) catch {
        std.debug.print("veer add: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
}

fn runRemove(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    const rule_id = args.next() orelse {
        std.debug.print("veer remove: rule ID required\n", .{});
        std.process.exit(1);
    };

    var config_path: []const u8 = ".veer/config.toml";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) config_path = args.next() orelse ".veer/config.toml";
    }

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = remove_cmd.run(allocator, rule_id, config_path, stream.writer()) catch {
        std.debug.print("veer remove: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
}

fn runStats(_: std.mem.Allocator) !void {
    // Stats requires a store, which requires a database path.
    // For now, print a message. Full wiring happens when loadMerged is implemented.
    std.debug.print("veer stats: not yet wired to database. Use --config with other commands.\n", .{});
    std.process.exit(0);
}

fn printUsage() void {
    std.debug.print(
        \\Usage: veer <command>
        \\
        \\Commands:
        \\  check      Evaluate a tool call against rules (PreToolUse hook)
        \\  install    Register veer as a Claude Code hook
        \\  list       Display current rules
        \\  add        Add a rule to config
        \\  remove     Remove a rule by ID
        \\  stats      Display usage statistics
        \\
        \\Options:
        \\  check   --config <path>     Use a specific config file
        \\  install --global --force --uninstall
        \\  list    --config <path>
        \\  add     --action <action> --command <cmd> [--message <msg>] [--rewrite-to <cmd>]
        \\  remove  <rule-id> [--config <path>]
        \\
    , .{});
}
