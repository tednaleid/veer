// ABOUTME: Entry point for veer, a Claude Code PreToolUse hook that redirects
// ABOUTME: agent tool calls toward safer, project-appropriate alternatives.

const std = @import("std");
const clap = @import("clap");
const config_mod = @import("config/config.zig");

// Keep in sync with build.zig.zon
const version = "0.2.0";
const check_cmd = @import("cli/check.zig");
const install_cmd = @import("cli/install.zig");
const list_cmd = @import("cli/list.zig");
const add_cmd = @import("cli/add.zig");
const remove_cmd = @import("cli/remove.zig");
const stats_cmd = @import("cli/stats.zig");
const scan_cmd = @import("cli/scan.zig");
const test_cmd = @import("cli/test_cmd.zig");
const validate_cmd = @import("cli/validate_cmd.zig");
const config_path_mod = @import("cli/config_path.zig");
const settings_mod = @import("claude/settings.zig");

const Command = enum { check, install, uninstall, list, add, remove, stats, scan, @"test", validate };

pub fn main(init: std.process.Init.Minimal) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const environ = init.environ;

    var threaded: std.Io.Threaded = .init(allocator, .{ .environ = environ });
    defer threaded.deinit();
    const io = threaded.io();

    const main_params = comptime clap.parseParamsComptime(
        \\-h, --help     Display this help and exit.
        \\-v, --version  Display version information and exit.
        \\<command>
        \\
    );
    const main_parsers = .{ .command = clap.parsers.enumeration(Command) };

    var iter = try init.args.iterateAllocator(allocator);
    defer iter.deinit();
    _ = iter.next(); // skip program name

    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &main_params, main_parsers, &iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
        .terminating_positional = 0,
    }) catch |err| {
        diag.reportToFile(io, .stderr(), err) catch {};
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
        .check => try runCheck(allocator, io, environ, &iter),
        .install => try runInstall(allocator, io, environ, &iter),
        .uninstall => try runUninstall(allocator, io, environ, &iter),
        .list => try runList(allocator, io, environ, &iter),
        .add => try runAdd(allocator, io, environ, &iter),
        .remove => try runRemove(allocator, io, environ, &iter),
        .stats => try runStats(allocator, io, environ, &iter),
        .scan => try runScan(allocator, io, &iter),
        .@"test" => try runTest(allocator, io, environ, &iter),
        .validate => try runValidate(allocator, io, environ, &iter),
    }
}

const LoadedConfig = struct {
    rules: []const config_mod.Rule,
    settings: config_mod.Settings,
    parsed_file: ?@import("toml").Parsed(config_mod.Config),
    merged: ?config_mod.MergedConfig,
    /// Parallel to `rules`; populated only when `merged != null`. Lets
    /// `list`/`test` show which file each rule came from. `null` when the
    /// config was loaded from an explicit single-file path.
    sources: ?[]const config_mod.RuleSource,
};

/// Load config from explicit path or auto-discover. Exits on failure.
fn loadConfig(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, config_path: ?[]const u8) LoadedConfig {
    if (config_path) |path| {
        if (config_mod.loadFile(allocator, io, path)) |result| {
            return .{
                .rules = result.value.rule,
                .settings = result.value.settings,
                .parsed_file = result,
                .merged = null,
                .sources = null,
            };
        } else |_| {
            std.debug.print("veer: failed to load config: {s}\n", .{path});
            std.process.exit(1);
        }
    }

    if (config_mod.loadMerged(allocator, io, environ)) |result| {
        return .{
            .rules = result.config.rule,
            .settings = result.config.settings,
            .parsed_file = null,
            .merged = result,
            .sources = result.sources,
        };
    } else |err| {
        if (err == error.NoConfigFound) {
            printNoConfigSearchPath(allocator, io, environ);
            std.debug.print("Create .veer/config.toml or run `veer install`.\n", .{});
        } else {
            std.debug.print("veer: failed to load config: {}\n", .{err});
        }
        std.process.exit(1);
    }
}

/// Print "no config found" plus the cwd that was searched and
/// `$CLAUDE_PROJECT_DIR` if it was set. Best-effort: if cwd resolution fails
/// we still print a useful header.
fn printNoConfigSearchPath(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ) void {
    std.debug.print("veer: no config found (looked for .veer/config.local.toml, .veer/config.toml, and ~/.config/veer/config.toml)\n", .{});
    if (std.process.currentPathAlloc(io, allocator)) |cwd| {
        defer allocator.free(cwd);
        std.debug.print("  cwd: {s} (walked up to /, no config)\n", .{cwd});
    } else |_| {}
    if (environ.getPosix("CLAUDE_PROJECT_DIR")) |dir| {
        std.debug.print("  CLAUDE_PROJECT_DIR: {s} (no .veer/config.toml there either)\n", .{dir});
    }
}

/// Like loadConfig, but for the check hot-path: any failure exits 2 (reject)
/// with a hook-oriented message that reaches the LLM via Claude Code's
/// exit-2 semantics. Silently allowing on misconfiguration would defeat the
/// purpose of the hook.
fn loadConfigForCheck(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, config_path: ?[]const u8) LoadedConfig {
    if (config_path) |path| {
        var detail: ?config_mod.ParseDetail = null;
        defer if (detail) |*d| d.deinit(allocator);

        if (config_mod.loadFileDetailed(allocator, io, path, &detail)) |result| {
            return .{
                .rules = result.value.rule,
                .settings = result.value.settings,
                .parsed_file = result,
                .merged = null,
                .sources = null,
            };
        } else |_| {
            std.debug.print("veer: failed to load config at {s}\n", .{path});
            if (detail) |d| switch (d) {
                .position => |pos| std.debug.print("  TOML syntax error at line {d}, column {d}\n", .{ pos.line, pos.column }),
                .field_path => |fp| {
                    std.debug.print("  invalid value for ", .{});
                    for (fp, 0..) |seg, i| {
                        if (i > 0) std.debug.print(".", .{});
                        std.debug.print("{s}", .{seg});
                    }
                    std.debug.print("\n", .{});
                },
            };
            std.debug.print("Fix the file or run 'veer uninstall' to remove the hook.\n", .{});
            std.process.exit(2);
        }
    }

    if (config_mod.loadMerged(allocator, io, environ)) |result| {
        return .{
            .rules = result.config.rule,
            .settings = result.config.settings,
            .parsed_file = null,
            .merged = result,
            .sources = result.sources,
        };
    } else |err| {
        if (err == error.NoConfigFound) {
            printNoConfigSearchPath(allocator, io, environ);
            std.debug.print(
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

/// Handle a subcommand parse error by reporting it and exiting nonzero.
fn subcommandParseFail(io: std.Io, diag: *clap.Diagnostic, err: anyerror, name: []const u8) noreturn {
    diag.reportToFile(io, .stderr(), err) catch {};
    std.debug.print("Try 'veer {s} --help' for usage.\n", .{name});
    std.process.exit(1);
}

/// Print per-subcommand help to stdout and exit 0.
fn printSubHelp(io: std.Io, comptime params: []const clap.Param(clap.Help)) noreturn {
    clap.helpToFile(io, .stdout(), clap.Help, params, .{}) catch {};
    std.process.exit(0);
}

/// Print a prose description followed by the flag list, then exit 0.
/// Uses a single buffered writer so description and flags stay in order
/// (clap.helpToFile uses a positioned-write writer that would overwrite
/// anything already written to the file).
fn printSubHelpWithDesc(io: std.Io, desc: []const u8, comptime params: []const clap.Param(clap.Help)) noreturn {
    var buf: [2048]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(io, &buf);
    const w = &file_writer.interface;
    w.writeAll(desc) catch {};
    w.writeAll("\n") catch {};
    clap.help(w, clap.Help, params, .{}) catch {};
    w.flush() catch {};
    std.process.exit(0);
}

fn runCheck(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\    --config <str>  Path to config file.
        \\    --verbose       Emit a systemMessage banner showing each Bash command
        \\                    (and its rewrite target, if any). User-visible in the
        \\                    Claude Code transcript; not sent to the LLM. Set by
        \\                    'veer install --verbose'.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(io, &diag, err, "check");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(io, &params);

    const config_path: ?[]const u8 = res.args.config;
    const verbose: bool = res.args.verbose != 0;

    var loaded = loadConfigForCheck(allocator, io, environ, config_path);
    defer if (loaded.parsed_file) |*pf| pf.deinit();
    defer if (loaded.merged) |*m| m.deinit(allocator);

    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().readerStreaming(io, &stdin_buf);
    const stdin_data = stdin_reader.interface.allocRemaining(allocator, .limited(1024 * 1024)) catch {
        std.debug.print("veer: failed to read stdin\n", .{});
        std.process.exit(1);
    };
    defer allocator.free(stdin_data);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    var stderr_buf: [4096]u8 = undefined;
    var stderr_stream = std.Io.Writer.fixed(&stderr_buf);

    const root: ?[]const u8 = if (loaded.merged) |m| m.projectRoot() else null;

    const exit_code = check_cmd.run(
        allocator,
        io,
        loaded.rules,
        root,
        environ.getPosix("HOME"),
        stdin_data,
        &stdout_stream,
        &stderr_stream,
        verbose,
    ) catch {
        std.debug.print("veer: internal error during check\n", .{});
        std.process.exit(1);
    };

    const stdout_output = stdout_stream.buffered();
    const stderr_output = stderr_stream.buffered();
    if (stdout_output.len > 0) std.Io.File.stdout().writeStreamingAll(io, stdout_output) catch {};
    if (stderr_output.len > 0) std.Io.File.stderr().writeStreamingAll(io, stderr_output) catch {};

    std.process.exit(exit_code);
}

fn runInstall(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help     Display this help and exit.
        \\    --local    Fully private install: hook in settings.local.json, config.local.toml, no project skill.
        \\    --global   Install into your home directory (all projects) instead of the current one.
        \\    --verbose  Install in verbose mode: each Bash command (and its rewrite target)
        \\               shows as a systemMessage banner in the Claude Code transcript.
        \\               User-visible, not sent to the LLM.
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
        \\With --local, this is a fully private install: the hook goes into
        \\.claude/settings.local.json, the config stub is written to
        \\.veer/config.local.toml (and added to .git/info/exclude so it stays
        \\uncommitted), and no project skill is written. Run 'veer install
        \\--global' once so a global skill is available.
        \\
        \\With --global, files are written to your home directory:
        \\  - ~/.claude/settings.json (hook)
        \\  - ~/.config/veer/config.toml (if missing)
        \\  - ~/.claude/skills/veer/SKILL.md
        \\
        \\With --verbose, the installed hook is 'veer check --verbose'. Each Bash
        \\command (and its rewrite target, if any) appears as a systemMessage banner
        \\in the transcript. The banner is visible to you but is not added to
        \\Claude's context. Non-Bash tools produce no banner. Re-run without
        \\--verbose to switch back.
        \\
        \\Re-running updates the hook entry to match the current version and flags.
        \\
    ;
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(io, &diag, err, "install");
    defer res.deinit();

    if (res.args.help != 0) printSubHelpWithDesc(io, install_desc, &params);

    const scope = resolveScope(res.args.local != 0, res.args.global != 0, "install");
    const verbose: bool = res.args.verbose != 0;

    const paths = install_cmd.resolvePaths(allocator, environ, scope) catch |err| {
        std.debug.print("veer install: {}\n", .{err});
        std.process.exit(1);
    };
    defer install_cmd.freePaths(allocator, paths, scope);

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    const exit_code = install_cmd.install(allocator, io, paths, verbose, &stream) catch |err| {
        std.debug.print("veer install: {}\n", .{err});
        std.process.exit(1);
    };

    if (exit_code == 0 and scope == .local) {
        // Best-effort: keep .veer/config.local.toml out of git via the repo's
        // per-repo, uncommitted .git/info/exclude. No-op outside a git repo.
        install_cmd.ensureLocalConfigExcluded(allocator, io, paths.config, &stream) catch |err| {
            std.debug.print("veer install: warning: could not register .git/info/exclude entry: {}\n", .{err});
        };
    }

    const output = stream.buffered();
    if (output.len > 0) std.Io.File.stdout().writeStreamingAll(io, output) catch {};
    std.process.exit(exit_code);
}

fn runUninstall(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help    Display this help and exit.
        \\    --local   Uninstall the private install: settings.local.json hook and config.local.toml.
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
        \\With --local, the hook is removed from .claude/settings.local.json and
        \\.veer/config.local.toml is deleted (the private install never wrote a
        \\project skill, and the .git/info/exclude entry is left in place).
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
    }) catch |err| subcommandParseFail(io, &diag, err, "uninstall");
    defer res.deinit();

    if (res.args.help != 0) printSubHelpWithDesc(io, uninstall_desc, &params);

    const scope = resolveScope(res.args.local != 0, res.args.global != 0, "uninstall");

    const paths = install_cmd.resolvePaths(allocator, environ, scope) catch |err| {
        std.debug.print("veer uninstall: {}\n", .{err});
        std.process.exit(1);
    };
    defer install_cmd.freePaths(allocator, paths, scope);

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    const exit_code = install_cmd.uninstall(allocator, io, paths, &stream) catch |err| {
        std.debug.print("veer uninstall: {}\n", .{err});
        std.process.exit(1);
    };

    const output = stream.buffered();
    if (output.len > 0) std.Io.File.stdout().writeStreamingAll(io, output) catch {};
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

fn runList(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\    --config <str>  Path to config file.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(io, &diag, err, "list");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(io, &params);

    const config_path: ?[]const u8 = res.args.config;

    var loaded = loadConfig(allocator, io, environ, config_path);
    defer if (loaded.parsed_file) |*pf| pf.deinit();
    defer if (loaded.merged) |*m| m.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    const exit_code = list_cmd.run(allocator, loaded.rules, loaded.sources, &stream) catch {
        std.debug.print("veer list: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.buffered();
    if (output.len > 0) std.Io.File.stdout().writeStreamingAll(io, output) catch {};
    std.process.exit(exit_code);
}

fn runAdd(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit.
        \\    --action <str>      Rule action (allow, reject, rewrite).
        \\    --command <str>     Command pattern to match. Mutually exclusive with --path.
        \\    --path <str>        Path glob to match. Mutually exclusive with --command.
        \\    --tool <str>        Tool to match (default: Bash for --command, Write and Edit for --path).
        \\    --id <str>          Rule identifier.
        \\    --name <str>        Rule name.
        \\    --message <str>     Message to display.
        \\    --rewrite-to <str>  Command to rewrite to.
        \\    --config <str>      Path to config file (default: .veer/config.toml).
        \\    --local             Write to .veer/config.local.toml (gitignored) instead.
        \\    --global            Write to ~/.config/veer/config.toml instead.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(io, &diag, err, "add");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(io, &params);

    var resolved = resolveRuleConfigPathOrExit(allocator, environ, res.args.local != 0, res.args.global != 0, res.args.config, "add");
    defer resolved.deinit(allocator);

    const opts = add_cmd.AddOptions{
        .action = res.args.action,
        .command = res.args.command,
        .path = res.args.path,
        .tool = res.args.tool,
        .id = res.args.id,
        .name = res.args.name,
        .message = res.args.message,
        .rewrite_to = res.args.@"rewrite-to",
        .config_path = resolved.path,
    };

    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    const exit_code = add_cmd.run(allocator, io, opts, &stream) catch {
        std.debug.print("veer add: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.buffered();
    if (output.len > 0) std.Io.File.stdout().writeStreamingAll(io, output) catch {};
    std.process.exit(exit_code);
}

fn runRemove(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\    --config <str>  Path to config file (default: .veer/config.toml).
        \\    --local         Remove from .veer/config.local.toml (gitignored) instead.
        \\    --global        Remove from ~/.config/veer/config.toml instead.
        \\<str>
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(io, &diag, err, "remove");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(io, &params);

    const rule_id = res.positionals[0] orelse {
        std.debug.print("veer remove: rule ID required\n", .{});
        std.debug.print("Try 'veer remove --help' for usage.\n", .{});
        std.process.exit(1);
    };

    var resolved = resolveRuleConfigPathOrExit(allocator, environ, res.args.local != 0, res.args.global != 0, res.args.config, "remove");
    defer resolved.deinit(allocator);

    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    const exit_code = remove_cmd.run(allocator, io, rule_id, resolved.path, &stream) catch {
        std.debug.print("veer remove: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.buffered();
    if (output.len > 0) std.Io.File.stdout().writeStreamingAll(io, output) catch {};
    std.process.exit(exit_code);
}

fn runStats(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help              Display this help and exit.
        \\    --since <str>       Time window (e.g. "1h", "24h", "7d"). Default: all time.
        \\    --projects <str>    Override the Claude Code projects root (default: $HOME/.claude/projects).
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(io, &diag, err, "stats");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(io, &params);

    const since_ms: ?u64 = if (res.args.since) |s| blk: {
        const parsed = stats_cmd.parseSince(s) orelse {
            std.debug.print("veer stats: invalid --since value '{s}' (try '24h', '7d', '30m')\n", .{s});
            std.process.exit(1);
        };
        break :blk parsed;
    } else null;

    const projects_root: []const u8 = if (res.args.projects) |p|
        try allocator.dupe(u8, p)
    else blk: {
        const home = environ.getPosix("HOME") orelse {
            std.debug.print("veer stats: $HOME not set; pass --projects <path>\n", .{});
            std.process.exit(1);
        };
        break :blk try std.fmt.allocPrint(allocator, "{s}/.claude/projects", .{home});
    };
    defer allocator.free(projects_root);

    // Stream output to stdout directly; transcripts can produce > a few KB.
    var stdout_buf: [16 * 1024]u8 = undefined;
    var stdout_stream = std.Io.Writer.fixed(&stdout_buf);
    const exit_code = stats_cmd.run(allocator, io, projects_root, since_ms, &stdout_stream) catch {
        std.debug.print("veer stats: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stdout_stream.buffered();
    if (output.len > 0) std.Io.File.stdout().writeStreamingAll(io, output) catch {};
    std.process.exit(exit_code);
}

fn runScan(allocator: std.mem.Allocator, io: std.Io, iter: *std.process.Args.Iterator) !void {
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
    }) catch |err| subcommandParseFail(io, &diag, err, "scan");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(io, &params);

    var opts = scan_cmd.ScanOptions{};
    opts.global = res.args.global != 0;
    if (res.args.@"min-count") |n| opts.min_count = @intCast(n);
    if (res.args.output) |fmt| opts.output_toml = std.mem.eql(u8, fmt, "toml");
    opts.permissions = res.args.permissions != 0;

    const settings_path: ?[]const u8 = res.args.settings;
    const transcript_path: ?[]const u8 = res.args.transcript;

    // Load transcript content
    const content = if (transcript_path) |path|
        std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(100 * 1024 * 1024)) catch {
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
            settings = settings_mod.SettingsReader.loadFile(allocator, io, path) catch null;
        }
    }

    var buf: [16384]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    const exit_code = scan_cmd.scanContent(allocator, content, opts, settings, &stream) catch {
        std.debug.print("veer scan: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.buffered();
    if (output.len > 0) std.Io.File.stdout().writeStreamingAll(io, output) catch {};
    std.process.exit(exit_code);
}

fn runTest(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help                Display this help and exit.
        \\    --config <str>        Path to config file.
        \\    --file <str>          File containing commands to test (one per line).
        \\    --tool <str>          Tool name to evaluate against (default: Bash).
        \\    --path <str>          Target path, for tools that carry one.
        \\    --content-file <str>  File whose body stands in for tool content.
        \\<str>
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(io, &diag, err, "test");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(io, &params);

    const opts = test_cmd.TestOptions{
        .command = res.positionals[0],
        .file_path = res.args.file,
        .tool = res.args.tool orelse "Bash",
        .path = res.args.path,
        .content_file = res.args.@"content-file",
        .home = environ.getPosix("HOME"),
    };
    const config_path: ?[]const u8 = res.args.config;

    var loaded = loadConfig(allocator, io, environ, config_path);
    defer if (loaded.parsed_file) |*pf| pf.deinit();
    defer if (loaded.merged) |*m| m.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    const exit_code = test_cmd.run(allocator, io, loaded.rules, loaded.sources, opts, &stream) catch {
        std.debug.print("veer test: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.buffered();
    if (output.len > 0) std.Io.File.stdout().writeStreamingAll(io, output) catch {};
    std.process.exit(exit_code);
}

fn runValidate(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, iter: *std.process.Args.Iterator) !void {
    const params = comptime clap.parseParamsComptime(
        \\-h, --help          Display this help and exit.
        \\    --config <str>  Path to config file (default: .veer/config.toml).
        \\    --local         Validate .veer/config.local.toml (gitignored) instead.
        \\    --global        Validate ~/.config/veer/config.toml instead.
        \\
    );
    var diag = clap.Diagnostic{};
    var res = clap.parseEx(clap.Help, &params, clap.parsers.default, iter, .{
        .diagnostic = &diag,
        .allocator = allocator,
    }) catch |err| subcommandParseFail(io, &diag, err, "validate");
    defer res.deinit();

    if (res.args.help != 0) printSubHelp(io, &params);

    var resolved = resolveRuleConfigPathOrExit(allocator, environ, res.args.local != 0, res.args.global != 0, res.args.config, "validate");
    defer resolved.deinit(allocator);

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    const exit_code = validate_cmd.run(allocator, io, .{ .config_path = resolved.path }, &stream) catch {
        std.debug.print("veer validate: internal error\n", .{});
        std.process.exit(1);
    };

    const output = stream.buffered();
    if (output.len > 0) std.Io.File.stdout().writeStreamingAll(io, output) catch {};
    std.process.exit(exit_code);
}

/// Wrapper around `config_path_mod.resolve` that maps errors to user-facing
/// messages and exits the process. Keeps the runAdd/runRemove/runValidate
/// dispatchers compact.
fn resolveRuleConfigPathOrExit(allocator: std.mem.Allocator, environ: std.process.Environ, local: bool, global: bool, config_arg: ?[]const u8, verb: []const u8) config_path_mod.Resolved {
    const target = config_path_mod.targetFromFlags(local, global, config_arg) catch {
        std.debug.print("veer {s}: --local, --global, and --config are mutually exclusive\n", .{verb});
        std.process.exit(1);
    };
    return config_path_mod.resolve(allocator, environ, target) catch |err| switch (err) {
        error.NoHome => {
            std.debug.print("veer {s}: --global requires $HOME to be set\n", .{verb});
            std.process.exit(1);
        },
        error.OutOfMemory => {
            std.debug.print("veer {s}: out of memory\n", .{verb});
            std.process.exit(1);
        },
    };
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
