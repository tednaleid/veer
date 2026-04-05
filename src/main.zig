// ABOUTME: Entry point for veer, a Claude Code PreToolUse hook that redirects
// ABOUTME: agent tool calls toward safer, project-appropriate alternatives.

const std = @import("std");
const clap = @import("clap");
const config_mod = @import("config/config.zig");

// Keep in sync with build.zig.zon
const version = "0.1.2";
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

const Command = enum { check, install, uninstall, list, add, remove, stats, scan, @"test", validate };

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const main_params = comptime clap.parseParamsComptime(
        \\-h, --help     Display this help and exit.
        \\-v, --version  Display version information and exit.
        \\<command>
        \\
    );
    const main_parsers = .{ .command = clap.parsers.enumeration(Command) };

    var iter = try std.process.ArgIterator.initWithAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip program name

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| {
        diag.reportToFile(.stderr(), err) catch {};
        std.debug.print("Try 'veer --help' for usage.\n", .{});
        std.process.exit(1);
    };
    defer res.deinit();

    if (res.args.help != 0) {
        printMainHelp();
        std.process.exit(0);
    }
    if (res.args.version != 0) {
        std.debug.print("veer {s}\n", .{version});
        std.process.exit(0);
    }

    const cmd = res.positionals[0] orelse {
        printMainHelp();
        std.process.exit(1);
    };

    switch (cmd) {
        .check => try runCheck(allocator, &iter),
        .install => try runInstall(allocator, &iter),
        .uninstall => try runUninstall(allocator, &iter),
        .list => try runList(allocator, &iter),
        .add => try runAdd(allocator, &iter),
        .remove => try runRemove(allocator, &iter),
        .stats => try runStats(allocator, &iter),
        .scan => try runScan(allocator, &iter),
        .@"test" => try runTest(allocator, &iter),
        .validate => try runValidate(allocator, &iter),
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

/// Like loadConfig, but for the check hot-path: any failure exits 2 (reject)
/// with a hook-oriented message that reaches the LLM via Claude Code's
/// exit-2 semantics. Silently allowing on misconfiguration would defeat the
/// purpose of the hook.
fn loadConfigForCheck(allocator: std.mem.Allocator, config_path: ?[]const u8) LoadedConfig {
    if (config_path) |path| {
        if (config_mod.loadFile(allocator, path)) |result| {
            return .{
                .rules = result.value.rule,
                .settings = result.value.settings,
                .parsed_file = result,
                .merged = null,
            };
        } else |_| {
            std.debug.print(
                \\veer: failed to load config at {s}
                \\Fix the file or run 'veer uninstall' to remove the hook.
                \\
            , .{path});
            std.process.exit(2);
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
            std.debug.print(
                \\veer: no config at .veer/config.toml
                \\The veer PreToolUse hook is installed but has no rules loaded, so every Bash
                \\tool call is being blocked. Fix with:
                \\  veer install            # create a starter config in this repo
                \\  veer uninstall          # remove the veer hook entirely
                \\
            , .{});
        } else {
            std.debug.print("veer: failed to load config: {}\n", .{err});
        }
        std.process.exit(2);
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

/// Handle a subcommand parse error by reporting it and exiting nonzero.
fn subcommandParseFail(diag: *clap.Diagnostic, err: anyerror, name: []const u8) noreturn {
    diag.reportToFile(.stderr(), err) catch {};
    std.debug.print("Try 'veer {s} --help' for usage.\n", .{name});
    std.process.exit(1);
}

/// Print per-subcommand help to stdout and exit 0.
fn printSubHelp(comptime params: []const clap.Param(clap.Help)) noreturn {
    clap.helpToFile(.stdout(), clap.Help, params, .{}) catch {};
    std.process.exit(0);
}

/// Print a prose description followed by the flag list, then exit 0.
/// Uses a single buffered writer so description and flags stay in order
/// (clap.helpToFile uses a positioned-write writer that would overwrite
/// anything already written to the file).
fn printSubHelpWithDesc(desc: []const u8, comptime params: []const clap.Param(clap.Help)) noreturn {
    var buf: [2048]u8 = undefined;
    var file_writer = std.fs.File.stdout().writer(&buf);
    const w = &file_writer.interface;
    w.writeAll(desc) catch {};
    w.writeAll("\n") catch {};
    clap.help(w, clap.Help, params, .{}) catch {};
    w.flush() catch {};
    std.process.exit(0);
}

fn runCheck(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\    --config <str>  Path to config file.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "check");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(&params);

    const config_path: ?[]const u8 = res.args.config;

    var loaded = loadConfigForCheck(allocator, config_path);
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

fn runInstall(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display this help and exit.
        \\    --local   Write hook into .claude/settings.local.json instead of .claude/settings.json.
        \\    --global  Install into your home directory (all projects) instead of the current one.
        \\
    );
    const install_desc =
        \\Install veer as a Claude Code PreToolUse hook.
        \\
        \\By default, installs into the CURRENT directory:
        \\  - merges the 'veer check' hook into .claude/settings.json (preserves other hooks)
        \\  - creates .veer/config.toml with a starter rule if it does not already exist
        \\  - writes .claude/skills/veer/SKILL.md (guides Claude on reading and adding veer rules)
        \\
        \\With --local, the hook goes into .claude/settings.local.json (user-private,
        \\typically gitignored); config and skill still go to the project paths.
        \\
        \\With --global, files are written to your home directory:
        \\  - ~/.claude/settings.json (hook)
        \\  - ~/.config/veer/config.toml (if missing)
        \\  - ~/.claude/skills/veer/SKILL.md
        \\
        \\Re-running is idempotent: an existing veer entry is not duplicated.
        \\
    ;
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "install");
    defer res.deinit();

    if (res.args.help != 0) printSubHelpWithDesc(install_desc, &params);

    const scope = resolveScope(res.args.local != 0, res.args.global != 0, "install");

    const paths = install_cmd.resolvePaths(allocator, scope) catch |err| {
        std.debug.print("veer install: {}\n", .{err});
        std.process.exit(1);
    };
    defer install_cmd.freePaths(allocator, paths, scope);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = install_cmd.install(allocator, paths, stream.writer()) catch |err| {
        std.debug.print("veer install: {}\n", .{err});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
}

fn runUninstall(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display this help and exit.
        \\    --local   Uninstall from .claude/settings.local.json instead of .claude/settings.json.
        \\    --global  Uninstall from your home directory (all projects) instead of the current one.
        \\
    );
    const uninstall_desc =
        \\Remove the veer PreToolUse hook and its supporting files.
        \\
        \\By default, removes from the CURRENT directory:
        \\  - removes the 'veer check' entry from .claude/settings.json (preserves other hooks)
        \\  - deletes .veer/config.toml
        \\  - deletes .claude/skills/veer/SKILL.md
        \\
        \\With --local, the same cleanup runs but the hook is removed from
        \\.claude/settings.local.json.
        \\
        \\With --global, files are removed from your home directory:
        \\  - ~/.claude/settings.json (veer entry)
        \\  - ~/.config/veer/config.toml
        \\  - ~/.claude/skills/veer/SKILL.md
        \\
        \\Re-running is safe: if nothing is installed, nothing is removed.
        \\
    ;
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "uninstall");
    defer res.deinit();

    if (res.args.help != 0) printSubHelpWithDesc(uninstall_desc, &params);

    const scope = resolveScope(res.args.local != 0, res.args.global != 0, "uninstall");

    const paths = install_cmd.resolvePaths(allocator, scope) catch |err| {
        std.debug.print("veer uninstall: {}\n", .{err});
        std.process.exit(1);
    };
    defer install_cmd.freePaths(allocator, paths, scope);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const exit_code = install_cmd.uninstall(allocator, paths, stream.writer()) catch |err| {
        std.debug.print("veer uninstall: {}\n", .{err});
        std.process.exit(1);
    };

    const output = stream.getWritten();
    if (output.len > 0) _ = std.fs.File.stdout().write(output) catch {};
    std.process.exit(exit_code);
}

fn resolveScope(local: bool, global: bool, verb: []const u8) install_cmd.Scope {
    if (local and global) {
        std.debug.print("veer {s}: --local and --global are mutually exclusive\n", .{verb});
        std.process.exit(1);
    }
    if (global) return .global;
    if (local) return .local;
    return .project;
}

fn runList(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\    --config <str>  Path to config file.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "list");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(&params);

    const config_path: ?[]const u8 = res.args.config;

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

fn runAdd(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit.
        \\    --action <str>      Rule action (allow, deny, rewrite, warn).
        \\    --command <str>     Command pattern to match.
        \\    --id <str>          Rule identifier.
        \\    --name <str>        Rule name.
        \\    --message <str>     Message to display.
        \\    --rewrite-to <str>  Command to rewrite to.
        \\    --config <str>      Path to config file (default: .veer/config.toml).
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "add");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(&params);

    const opts = add_cmd.AddOptions{
        .action = res.args.action,
        .command = res.args.command,
        .id = res.args.id,
        .name = res.args.name,
        .message = res.args.message,
        .rewrite_to = res.args.@"rewrite-to",
        .config_path = res.args.config orelse ".veer/config.toml",
    };

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

fn runRemove(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\    --config <str>  Path to config file (default: .veer/config.toml).
        \\<str>
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "remove");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(&params);

    const rule_id = res.positionals[0] orelse {
        std.debug.print("veer remove: rule ID required\n", .{});
        std.debug.print("Try 'veer remove --help' for usage.\n", .{});
        std.process.exit(1);
    };

    const config_path = res.args.config orelse ".veer/config.toml";

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

fn runStats(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help  Display this help and exit.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "stats");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(&params);

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

fn runScan(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\    --global              Scan global transcripts.
        \\    --min-count <usize>   Minimum occurrence count to report.
        \\    --output <str>        Output format (toml).
        \\    --permissions         Include Claude Code permissions.
        \\    --settings <str>      Path to settings.json.
        \\    --transcript <str>    Path to transcript JSONL file.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "scan");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(&params);

    var opts = scan_cmd.ScanOptions{};
    opts.global = res.args.global != 0;
    if (res.args.@"min-count") |n| opts.min_count = @intCast(n);
    if (res.args.output) |fmt| opts.output_toml = std.mem.eql(u8, fmt, "toml");
    opts.permissions = res.args.permissions != 0;

    const settings_path: ?[]const u8 = res.args.settings;
    const transcript_path: ?[]const u8 = res.args.transcript;

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
    defer if (settings) |*sr| sr.deinit();
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

fn runTest(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\    --config <str>  Path to config file.
        \\    --file <str>    File containing commands to test (one per line).
        \\<str>
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "test");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(&params);

    const opts = test_cmd.TestOptions{
        .command = res.positionals[0],
        .file_path = res.args.file,
    };
    const config_path: ?[]const u8 = res.args.config;

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

fn runValidate(allocator: std.mem.Allocator, iter: *std.process.ArgIterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\    --config <str>  Path to config file (default: .veer/config.toml).
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(&diag, err, "validate");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(&params);

    const config_path = res.args.config orelse ".veer/config.toml";

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

fn printMainHelp() void {
    std.debug.print(
        \\Usage: veer [--help|--version] <command> [<args>]
        \\
        \\Options:
        \\  -h, --help     Display this help and exit.
        \\  -v, --version  Display version information and exit.
        \\
        \\Commands:
        \\  check      Evaluate a tool call against rules (PreToolUse hook)
        \\  install    Register veer as a Claude Code hook
        \\  uninstall  Remove the veer hook, config, and skill
        \\  list       Display current rules
        \\  add        Add a rule to config
        \\  remove     Remove a rule by ID
        \\  stats      Display usage statistics
        \\  scan       Mine transcripts to discover command patterns
        \\  test       Test a command against rules
        \\  validate   Validate config file
        \\
        \\Run 'veer <command> --help' for details on a specific command.
        \\
    , .{});
}
