// ABOUTME: Entry point for veer, a Claude Code PreToolUse hook that redirects
// ABOUTME: agent tool calls toward safer, project-appropriate alternatives.

const std = @import("std");
const config_mod = @import("config/config.zig");

// Keep in sync with build.zig.zon
const version = "0.1.0";
const check_cmd = @import("cli/check.zig");
const install_cmd = @import("cli/install.zig");
const list_cmd = @import("cli/list.zig");
const add_cmd = @import("cli/add.zig");
const remove_cmd = @import("cli/remove.zig");
const stats_cmd = @import("cli/stats.zig");
const scan_cmd = @import("cli/scan.zig");
const test_cmd = @import("cli/test_cmd.zig");
const validate_cmd = @import("cli/validate_cmd.zig");
const settings_mod = @import("claude/settings.zig");
const SqliteStore = @import("store/sqlite_store.zig").SqliteStore;

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

    if (std.mem.eql(u8, command, "--version") or std.mem.eql(u8, command, "-v")) {
        std.debug.print("veer {s}\n", .{version});
        std.process.exit(0);
    } else if (std.mem.eql(u8, command, "check")) {
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
    } else if (std.mem.eql(u8, command, "scan")) {
        try runScan(allocator, &args);
    } else if (std.mem.eql(u8, command, "test")) {
        try runTest(allocator, &args);
    } else if (std.mem.eql(u8, command, "validate")) {
        try runValidate(allocator, &args);
    } else {
        printUsage();
        std.process.exit(1);
    }
}

const LoadedConfig = struct {
    rules: []const config_mod.Rule,
    settings: config_mod.Settings,
    parsed_file: ?@import("toml").Parsed(config_mod.Config),
    merged: ?config_mod.MergedConfig,
};

/// Load config from explicit path or auto-discover. Exits on failure.
fn loadConfig(allocator: std.mem.Allocator, config_path: ?[]const u8) LoadedConfig {
    if (config_path) |path| {
        if (config_mod.loadFile(allocator, path)) |result| {
            return .{
                .rules = result.value.rule,
                .settings = result.value.settings,
                .parsed_file = result,
                .merged = null,
            };
        } else |_| {
            std.debug.print("veer: failed to load config: {s}\n", .{path});
            std.process.exit(1);
        }
    }

    if (config_mod.loadMerged(allocator)) |result| {
        return .{
            .rules = result.config.rule,
            .settings = result.config.settings,
            .parsed_file = null,
            .merged = result,
        };
    } else |err| {
        if (err == error.NoConfigFound) {
            std.debug.print("veer: no config found. Create .veer/config.toml or run `veer install`.\n", .{});
        } else {
            std.debug.print("veer: failed to load config: {}\n", .{err});
        }
        std.process.exit(1);
    }
}

/// Create a heap-allocated SqliteStore. Returns null on any failure.
fn initStore(allocator: std.mem.Allocator) ?*SqliteStore {
    const s = allocator.create(SqliteStore) catch return null;
    s.* = SqliteStore.init(".veer/veer.db") catch {
        allocator.destroy(s);
        return null;
    };
    s.start() catch {
        s.close();
        allocator.destroy(s);
        return null;
    };
    return s;
}

fn runCheck(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var config_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next();
        }
    }

    var loaded = loadConfig(allocator, config_path);
    defer if (loaded.parsed_file) |*pf| pf.deinit();
    defer if (loaded.merged) |*m| m.deinit(allocator);

    // Wire SqliteStore if stats enabled (heap-allocated for stable thread pointer)
    var sqlite_store: ?*SqliteStore = null;
    defer if (sqlite_store) |s| {
        s.close();
        allocator.destroy(s);
    };

    if (loaded.settings.stats) {
        sqlite_store = initStore(allocator);
    }

    const store = if (sqlite_store) |s| s.store() else null;

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
        loaded.rules,
        stdin_data,
        store,
        stdout_stream.writer(),
        stderr_stream.writer(),
    ) catch {
        std.debug.print("veer: internal error during check\n", .{});
        std.process.exit(1);
    };

    // Close store before exit (std.process.exit skips defers)
    if (sqlite_store) |s| {
        s.close();
        allocator.destroy(s);
        sqlite_store = null;
    }

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

    var loaded = loadConfig(allocator, config_path);
    defer if (loaded.parsed_file) |*pf| pf.deinit();
    defer if (loaded.merged) |*m| m.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = list_cmd.run(allocator, loaded.rules, stream.writer()) catch {
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

fn runStats(allocator: std.mem.Allocator) !void {
    const s = initStore(allocator) orelse {
        std.debug.print("veer stats: no database found at .veer/veer.db\n", .{});
        std.process.exit(1);
    };
    defer {
        s.close();
        allocator.destroy(s);
    }

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = stats_cmd.run(allocator, s.store(), stream.writer()) catch {
        std.debug.print("veer stats: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
}

fn runScan(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var opts = scan_cmd.ScanOptions{};
    var settings_path: ?[]const u8 = null;
    var transcript_path: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--global")) opts.global = true;
        if (std.mem.eql(u8, arg, "--min-count")) {
            if (args.next()) |n| {
                opts.min_count = std.fmt.parseInt(u32, n, 10) catch 1;
            }
        }
        if (std.mem.eql(u8, arg, "--output")) {
            if (args.next()) |fmt| {
                opts.output_toml = std.mem.eql(u8, fmt, "toml");
            }
        }
        if (std.mem.eql(u8, arg, "--permissions")) opts.permissions = true;
        if (std.mem.eql(u8, arg, "--settings")) settings_path = args.next();
        if (std.mem.eql(u8, arg, "--transcript")) transcript_path = args.next();
    }

    // Load transcript content
    const content = if (transcript_path) |path|
        std.fs.cwd().readFileAlloc(allocator, path, 100 * 1024 * 1024) catch {
            std.debug.print("veer scan: cannot read {s}\n", .{path});
            std.process.exit(1);
        }
    else blk: {
        // TODO: auto-discover transcripts from ~/.claude/projects/
        std.debug.print("veer scan: use --transcript <path> to specify a JSONL file\n", .{});
        std.process.exit(1);
        break :blk undefined;
    };
    defer allocator.free(content);

    // Load settings if requested
    var settings: ?settings_mod.SettingsReader = null;
    defer if (settings) |*s| s.deinit();
    if (opts.permissions) {
        if (settings_path) |path| {
            settings = settings_mod.SettingsReader.loadFile(allocator, path) catch null;
        }
    }

    var buf: [16384]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = scan_cmd.scanContent(allocator, content, opts, settings, stream.writer()) catch {
        std.debug.print("veer scan: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
}

fn runTest(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var opts = test_cmd.TestOptions{};
    var config_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next();
        } else if (arg.len > 0 and arg[0] != '-') {
            opts.command = arg;
        }
    }

    var loaded = loadConfig(allocator, config_path);
    defer if (loaded.parsed_file) |*pf| pf.deinit();
    defer if (loaded.merged) |*m| m.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = test_cmd.run(allocator, loaded.rules, opts, stream.writer()) catch {
        std.debug.print("veer test: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
}

fn runValidate(allocator: std.mem.Allocator, args: *std.process.ArgIterator) !void {
    var config_path: []const u8 = ".veer/config.toml";
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--config")) {
            config_path = args.next() orelse ".veer/config.toml";
        }
    }

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = validate_cmd.run(allocator, .{ .config_path = config_path }, stream.writer()) catch {
        std.debug.print("veer validate: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
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
        \\  scan       Mine transcripts to discover command patterns
        \\  test       Test a command against rules
        \\  validate   Validate config file
        \\
        \\Options:
        \\  check    --config <path>     Use a specific config file
        \\  install  --global --force --uninstall
        \\  list     --config <path>
        \\  add      --action <action> --command <cmd> [--message <msg>] [--rewrite-to <cmd>]
        \\  remove   <rule-id> [--config <path>]
        \\  scan     --transcript <path> [--min-count <n>] [--output toml] [--permissions --settings <path>]
        \\  test     "<command>" [--config <path>]
        \\  validate [--config <path>]
        \\
    , .{});
}
