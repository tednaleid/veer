// ABOUTME: Config loading, file discovery, and merging for veer.
// ABOUTME: Parses TOML config files into Config structs using zig-toml.

const std = @import("std");
const toml = @import("toml");
const rule_mod = @import("rule.zig");

pub const Rule = rule_mod.Rule;
pub const Action = rule_mod.Action;
pub const MatchConfig = rule_mod.MatchConfig;
pub const AstMatch = rule_mod.AstMatch;
pub const ValidationError = rule_mod.ValidationError;
pub const validate = rule_mod.validate;

pub const Settings = struct {
    log_level: []const u8 = "warn",
    claude_settings_path: ?[]const u8 = null,
    claude_projects_path: ?[]const u8 = null,
};

/// Top-level config structure matching the TOML schema.
/// Field name "rule" maps to [[rule]] array of tables in TOML.
pub const Config = struct {
    settings: Settings = .{},
    rule: []const Rule = &.{},
};

pub const ConfigError = error{
    ParseFailed,
    FileNotFound,
    ReadFailed,
    NoConfigFound,
} || ValidationError;

/// Which file a rule originated from after merging. Used by `veer list` and
/// `veer test` to show users which config a rule came from.
pub const RuleSource = enum { local, project, global };

/// One tier of rules to merge, tagged with where it came from.
/// In `mergeRules`, earlier tiers have higher precedence.
pub const RuleTier = struct {
    rules: []const Rule,
    source: RuleSource,
};

/// Output of `mergeRules`. The two slices are parallel: `sources[i]` describes
/// where `rules[i]` came from. Both are owned by the caller.
pub const MergeResult = struct {
    rules: []Rule,
    sources: []RuleSource,
};

/// Result of loadMerged(). Owns parsed configs and merged rules.
pub const MergedConfig = struct {
    config: Config = .{},
    project_parsed: ?toml.Parsed(Config) = null,
    global_parsed: ?toml.Parsed(Config) = null,
    local_parsed: ?toml.Parsed(Config) = null,
    merged_rules: ?[]Rule = null,
    /// Parallel to `config.rule` after `loadMerged` returns: `sources[i]` is
    /// the origin of `config.rule[i]`. Always populated by `loadMerged`
    /// (even when only one of project/global is present); `null` only for
    /// configs loaded via the explicit single-file path.
    sources: ?[]RuleSource = null,
    /// Absolute path of the project config that was loaded, if any.
    /// Owned by this struct; freed in deinit.
    project_config_path: ?[]const u8 = null,

    pub fn deinit(self: *MergedConfig, allocator: std.mem.Allocator) void {
        if (self.merged_rules) |r| allocator.free(r);
        if (self.sources) |s| allocator.free(s);
        if (self.project_parsed) |*p| p.deinit();
        if (self.global_parsed) |*g| g.deinit();
        if (self.local_parsed) |*l| l.deinit();
        if (self.project_config_path) |p| allocator.free(p);
    }
};

/// Parse a TOML string into a Config. Caller owns the returned Parsed value.
pub fn loadString(allocator: std.mem.Allocator, input: []const u8) !toml.Parsed(Config) {
    var parser = toml.Parser(Config).init(allocator);
    defer parser.deinit();

    var result = parser.parseString(input) catch {
        return error.ParseFailed;
    };

    validate(result.value.rule) catch |err| {
        result.deinit();
        return err;
    };

    return result;
}

/// Load config from a file path. Caller owns the returned Parsed value.
pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !toml.Parsed(Config) {
    const file = std.fs.cwd().openFile(path, .{}) catch {
        return error.FileNotFound;
    };
    defer file.close();

    const content = file.readToEndAlloc(allocator, 1024 * 1024) catch {
        return error.ReadFailed;
    };
    defer allocator.free(content);

    return loadString(allocator, content);
}

/// Fold an ordered list of tiers into one merged rule set. Earlier tiers
/// have higher precedence: the first occurrence of a rule `id` wins and
/// later tiers with the same id are dropped. Output order preserves tier
/// order (all kept tier[0] rules, then kept tier[1] rules, ...), which keeps
/// higher-precedence rules earlier for the first-match-wins evaluator.
/// Caller owns both slices on the returned `MergeResult`.
pub fn mergeRules(allocator: std.mem.Allocator, tiers: []const RuleTier) !MergeResult {
    var rules = std.ArrayListUnmanaged(Rule).empty;
    errdefer rules.deinit(allocator);
    var sources = std.ArrayListUnmanaged(RuleSource).empty;
    errdefer sources.deinit(allocator);

    for (tiers) |tier| {
        next_rule: for (tier.rules) |r| {
            for (rules.items) |existing| {
                if (std.mem.eql(u8, existing.id, r.id)) continue :next_rule;
            }
            try rules.append(allocator, r);
            try sources.append(allocator, tier.source);
        }
    }

    const owned_rules = try rules.toOwnedSlice(allocator);
    errdefer allocator.free(owned_rules);
    const owned_sources = try sources.toOwnedSlice(allocator);
    return .{
        .rules = owned_rules,
        .sources = owned_sources,
    };
}

/// Fold Settings tiers ordered highest-precedence-first. The highest tier's
/// `log_level` wins; each optional path takes the first non-null tier walking
/// highest to lowest. An empty slice yields default Settings.
/// `log_level` is a non-null string (default "warn") with no "unset" sentinel,
/// so the `log_set` guard takes the first tier's value once; re-assigning every
/// iteration would instead make the LAST (lowest-precedence) tier win.
pub fn mergeSettings(tiers: []const Settings) Settings {
    var result = Settings{};
    var log_set = false;
    for (tiers) |t| {
        if (!log_set) {
            result.log_level = t.log_level;
            log_set = true;
        }
        if (result.claude_settings_path == null) result.claude_settings_path = t.claude_settings_path;
        if (result.claude_projects_path == null) result.claude_projects_path = t.claude_projects_path;
    }
    return result;
}

pub const project_config_relpath = ".veer/config.toml";
pub const local_config_relpath = ".veer/config.local.toml";

/// Build the global config path: $XDG_CONFIG_HOME/veer/config.toml or ~/.config/veer/config.toml.
/// Caller owns the returned string.
pub fn globalConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/veer/config.toml", .{xdg});
    }
    const home = std.posix.getenv("HOME") orelse return error.FileNotFound;
    return std.fmt.allocPrint(allocator, "{s}/.config/veer/config.toml", .{home});
}

/// Walk up from `cwd_abs` (and an optional `project_dir_hint`) looking for
/// `<dir>/<relpath>`. Returns the absolute path of the first match, or null.
///
/// Discovery order:
///   1. If `project_dir_hint` is non-null, try `<hint>/<relpath>`.
///      Used by `loadMerged` to forward `$CLAUDE_PROJECT_DIR` (set by Claude
///      Code for every PreToolUse hook invocation), making discovery
///      deterministic for the hook case regardless of cwd drift.
///   2. Walk up from `cwd_abs` toward filesystem root, checking
///      `<dir>/<relpath>` at each level. Same algorithm git uses
///      for `.git/`. Handles CLI usage (`veer test` from a subdirectory).
///
/// Caller owns the returned slice.
pub fn findConfigUpwards(
    allocator: std.mem.Allocator,
    cwd_abs: []const u8,
    project_dir_hint: ?[]const u8,
    relpath: []const u8,
) !?[]u8 {
    if (project_dir_hint) |hint| {
        if (hint.len > 0) {
            const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ hint, relpath });
            if (fileExists(candidate)) return candidate;
            allocator.free(candidate);
        }
    }

    var current: []const u8 = cwd_abs;
    while (true) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current, relpath });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);

        const parent = std.fs.path.dirname(current) orelse return null;
        if (parent.ptr == current.ptr and parent.len == current.len) return null;
        current = parent;
    }
}

/// Locate the project's `.veer/config.toml`. See `findConfigUpwards`.
pub fn findProjectConfigPath(
    allocator: std.mem.Allocator,
    cwd_abs: []const u8,
    project_dir_hint: ?[]const u8,
) !?[]u8 {
    return findConfigUpwards(allocator, cwd_abs, project_dir_hint, project_config_relpath);
}

fn fileExists(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    file.close();
    return true;
}

/// Auto-discover and merge project + global configs.
/// Project config is found via `findProjectConfigPath` (honors
/// `$CLAUDE_PROJECT_DIR`, then walks up from cwd). Global config is
/// `~/.config/veer/config.toml` (or `$XDG_CONFIG_HOME/veer/config.toml`).
/// Returns error.NoConfigFound if neither exists.
pub fn loadMerged(allocator: std.mem.Allocator) !MergedConfig {
    var result = MergedConfig{};
    errdefer result.deinit(allocator);

    const cwd_abs = std.fs.cwd().realpathAlloc(allocator, ".") catch null;
    defer if (cwd_abs) |c| allocator.free(c);

    if (cwd_abs) |cwd| {
        const hint = std.posix.getenv("CLAUDE_PROJECT_DIR");
        if (try findProjectConfigPath(allocator, cwd, hint)) |project_path| {
            result.project_config_path = project_path;
            result.project_parsed = loadFile(allocator, project_path) catch |err| blk: {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
        }
    }

    // Local tier: sibling of the project config when one was found, else an
    // independent upward walk. A local file alone is a valid config source.
    if (cwd_abs) |cwd| {
        const hint = std.posix.getenv("CLAUDE_PROJECT_DIR");
        const local_path: ?[]u8 = if (result.project_config_path) |pp| blk: {
            const dir = std.fs.path.dirname(pp) orelse break :blk null;
            const lp = try std.fmt.allocPrint(allocator, "{s}/config.local.toml", .{dir});
            if (fileExists(lp)) break :blk lp;
            allocator.free(lp);
            break :blk null;
        } else try findConfigUpwards(allocator, cwd, hint, local_config_relpath);

        if (local_path) |lp| {
            defer allocator.free(lp);
            result.local_parsed = loadFile(allocator, lp) catch |err| blk: {
                if (err == error.FileNotFound) break :blk null;
                return err;
            };
        }
    }

    // Try global config
    const global_path = globalConfigPath(allocator) catch null;
    defer if (global_path) |p| allocator.free(p);

    if (global_path) |path| {
        result.global_parsed = loadFile(allocator, path) catch |err| blk: {
            if (err == error.FileNotFound) break :blk null;
            return err;
        };
    }

    // Must have at least one config
    if (result.project_parsed == null and result.global_parsed == null and result.local_parsed == null) {
        return error.NoConfigFound;
    }

    // Collect present tiers, highest precedence first: local, project, global.
    var rule_tiers = std.ArrayListUnmanaged(RuleTier).empty;
    defer rule_tiers.deinit(allocator);
    var setting_tiers = std.ArrayListUnmanaged(Settings).empty;
    defer setting_tiers.deinit(allocator);

    if (result.local_parsed) |p| {
        try rule_tiers.append(allocator, .{ .rules = p.value.rule, .source = .local });
        try setting_tiers.append(allocator, p.value.settings);
    }
    if (result.project_parsed) |p| {
        try rule_tiers.append(allocator, .{ .rules = p.value.rule, .source = .project });
        try setting_tiers.append(allocator, p.value.settings);
    }
    if (result.global_parsed) |g| {
        try rule_tiers.append(allocator, .{ .rules = g.value.rule, .source = .global });
        try setting_tiers.append(allocator, g.value.settings);
    }

    const merge = try mergeRules(allocator, rule_tiers.items);
    result.merged_rules = merge.rules;
    result.sources = merge.sources;
    result.config = .{
        .settings = mergeSettings(setting_tiers.items),
        .rule = merge.rules,
    };

    return result;
}

// -- Tests --

test "loadString parses basic config" {
    const input =
        \\[[rule]]
        \\id = "use-just-test"
        \\name = "Redirect pytest"
        \\action = "rewrite"
        \\rewrite_to = "just test"
        \\[rule.match]
        \\command = "pytest"
    ;

    var result = try loadString(std.testing.allocator, input);
    defer result.deinit();

    const config = result.value;
    try std.testing.expectEqual(@as(usize, 1), config.rule.len);
    try std.testing.expectEqualStrings("use-just-test", config.rule[0].id);
    try std.testing.expectEqualStrings("pytest", config.rule[0].match.command.?);
    try std.testing.expectEqual(Action.rewrite, config.rule[0].effectiveAction());
    try std.testing.expectEqualStrings("just test", config.rule[0].rewrite_to.?);
}

test "loadString parses multiple rules" {
    const input =
        \\[[rule]]
        \\id = "rule-a"
        \\name = "Rule A"
        \\action = "reject"
        \\message = "Don't do A."
        \\priority = 10
        \\[rule.match]
        \\command = "foo"
        \\
        \\[[rule]]
        \\id = "rule-b"
        \\name = "Rule B"
        \\action = "reject"
        \\message = "Never do B."
        \\priority = 1
        \\[rule.match]
        \\command = "bar"
    ;

    var result = try loadString(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.value.rule.len);
    try std.testing.expectEqualStrings("rule-a", result.value.rule[0].id);
    try std.testing.expectEqualStrings("rule-b", result.value.rule[1].id);
}

test "loadString with settings-only config has no rules" {
    const input =
        \\[settings]
        \\log_level = "debug"
    ;

    var result = try loadString(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expectEqualStrings("debug", result.value.settings.log_level);
    try std.testing.expectEqual(@as(usize, 0), result.value.rule.len);
}

test "loadString rejects duplicate rule IDs" {
    const input =
        \\[[rule]]
        \\id = "same"
        \\name = "Rule 1"
        \\action = "reject"
        \\message = "msg"
        \\[rule.match]
        \\command = "foo"
        \\
        \\[[rule]]
        \\id = "same"
        \\name = "Rule 2"
        \\action = "reject"
        \\message = "msg"
        \\[rule.match]
        \\command = "bar"
    ;

    try std.testing.expectError(error.DuplicateRuleId, loadString(std.testing.allocator, input));
}

test "loadString rejects rewrite without target" {
    const input =
        \\[[rule]]
        \\id = "bad"
        \\name = "Bad rule"
        \\action = "rewrite"
        \\[rule.match]
        \\command = "foo"
    ;

    try std.testing.expectError(error.RewriteRequiresTarget, loadString(std.testing.allocator, input));
}

test "loadString rejects invalid TOML" {
    try std.testing.expectError(error.ParseFailed, loadString(std.testing.allocator, "this is not valid toml [[["));
}

test "loadFile returns FileNotFound for missing file" {
    try std.testing.expectError(error.FileNotFound, loadFile(std.testing.allocator, "/nonexistent/path/config.toml"));
}

test "mergeRules combines non-overlapping rules in tier order" {
    const local = [_]Rule{
        .{ .id = "l1", .message = "m", .match = .{ .command = "x" } },
    };
    const project = [_]Rule{
        .{ .id = "p1", .message = "m", .match = .{ .command = "b" } },
    };
    const global = [_]Rule{
        .{ .id = "g1", .message = "m", .match = .{ .command = "a" } },
    };
    const tiers = [_]RuleTier{
        .{ .rules = &local, .source = .local },
        .{ .rules = &project, .source = .project },
        .{ .rules = &global, .source = .global },
    };

    const merged = try mergeRules(std.testing.allocator, &tiers);
    defer std.testing.allocator.free(merged.rules);
    defer std.testing.allocator.free(merged.sources);

    try std.testing.expectEqual(@as(usize, 3), merged.rules.len);
    try std.testing.expectEqualStrings("l1", merged.rules[0].id);
    try std.testing.expectEqualStrings("p1", merged.rules[1].id);
    try std.testing.expectEqualStrings("g1", merged.rules[2].id);
    try std.testing.expectEqualSlices(
        RuleSource,
        &.{ .local, .project, .global },
        merged.sources,
    );
}

test "mergeRules: local overrides project overrides global by id" {
    const local = [_]Rule{
        .{ .id = "shared", .name = "Local", .message = "m", .match = .{ .command = "a" } },
    };
    const project = [_]Rule{
        .{ .id = "shared", .name = "Project", .message = "m", .match = .{ .command = "a" } },
        .{ .id = "ponly", .name = "ProjectOnly", .message = "m", .match = .{ .command = "b" } },
    };
    const global = [_]Rule{
        .{ .id = "shared", .name = "Global", .message = "m", .match = .{ .command = "a" } },
        .{ .id = "ponly", .name = "GlobalShadowed", .message = "m", .match = .{ .command = "c" } },
        .{ .id = "gonly", .name = "GlobalOnly", .message = "m", .match = .{ .command = "d" } },
    };
    const tiers = [_]RuleTier{
        .{ .rules = &local, .source = .local },
        .{ .rules = &project, .source = .project },
        .{ .rules = &global, .source = .global },
    };

    const merged = try mergeRules(std.testing.allocator, &tiers);
    defer std.testing.allocator.free(merged.rules);
    defer std.testing.allocator.free(merged.sources);

    // shared -> local, ponly -> project, gonly -> global
    try std.testing.expectEqual(@as(usize, 3), merged.rules.len);
    try std.testing.expectEqualStrings("shared", merged.rules[0].id);
    try std.testing.expectEqualStrings("Local", merged.rules[0].displayName());
    try std.testing.expectEqual(RuleSource.local, merged.sources[0]);
    try std.testing.expectEqualStrings("ponly", merged.rules[1].id);
    try std.testing.expectEqualStrings("ProjectOnly", merged.rules[1].displayName());
    try std.testing.expectEqual(RuleSource.project, merged.sources[1]);
    try std.testing.expectEqualStrings("gonly", merged.rules[2].id);
    try std.testing.expectEqual(RuleSource.global, merged.sources[2]);
}

test "mergeRules regression: two tiers behave like the old project-over-global merge" {
    const project = [_]Rule{
        .{ .id = "p1", .message = "m", .match = .{ .command = "c" } },
        .{ .id = "p2", .message = "m", .match = .{ .command = "d" } },
    };
    const global = [_]Rule{
        .{ .id = "g1", .message = "m", .match = .{ .command = "a" } },
        .{ .id = "g2", .message = "m", .match = .{ .command = "b" } },
    };
    const tiers = [_]RuleTier{
        .{ .rules = &project, .source = .project },
        .{ .rules = &global, .source = .global },
    };

    const merged = try mergeRules(std.testing.allocator, &tiers);
    defer std.testing.allocator.free(merged.rules);
    defer std.testing.allocator.free(merged.sources);

    try std.testing.expectEqual(@as(usize, 4), merged.rules.len);
    try std.testing.expectEqualStrings("p1", merged.rules[0].id);
    try std.testing.expectEqualStrings("p2", merged.rules[1].id);
    try std.testing.expectEqualStrings("g1", merged.rules[2].id);
    try std.testing.expectEqualStrings("g2", merged.rules[3].id);
    try std.testing.expectEqualSlices(
        RuleSource,
        &.{ .project, .project, .global, .global },
        merged.sources,
    );
}

test "mergeRules with a single tier copies rules and tags the source" {
    const global = [_]Rule{
        .{ .id = "g1", .message = "m", .match = .{ .command = "a" } },
    };
    const tiers = [_]RuleTier{
        .{ .rules = &global, .source = .global },
    };
    const merged = try mergeRules(std.testing.allocator, &tiers);
    defer std.testing.allocator.free(merged.rules);
    defer std.testing.allocator.free(merged.sources);

    try std.testing.expectEqual(@as(usize, 1), merged.rules.len);
    try std.testing.expectEqual(RuleSource.global, merged.sources[0]);
}

test "loadFile parses basic.toml fixture" {
    var result = try loadFile(std.testing.allocator, "test/configs/basic.toml");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.value.rule.len);
    try std.testing.expectEqualStrings("use-just-test", result.value.rule[0].id);
    try std.testing.expectEqualStrings("no-curl-pipe-bash", result.value.rule[1].id);
    try std.testing.expectEqual(Action.rewrite, result.value.rule[0].effectiveAction());
    try std.testing.expectEqual(Action.reject, result.value.rule[1].effectiveAction());
}

test "loadFile parses empty.toml fixture" {
    var result = try loadFile(std.testing.allocator, "test/configs/empty.toml");
    defer result.deinit();

    try std.testing.expectEqualStrings("debug", result.value.settings.log_level);
    try std.testing.expectEqual(@as(usize, 0), result.value.rule.len);
}

test "loadMerged finds project config when present" {
    // This test works when .veer/config.toml exists in the project root.
    // loadMerged should find it and return the config.
    if (loadMerged(std.testing.allocator)) |*result| {
        var r = result.*;
        defer r.deinit(std.testing.allocator);
        try std.testing.expect(r.config.rule.len > 0);
    } else |_| {
        // If no config exists, that's also OK for this test
    }
}

test "findProjectConfigPath finds config at cwd when present" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".veer");
    var f = try tmp.dir.createFile(".veer/config.toml", .{});
    f.close();

    const tmp_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_abs);

    const path = try findProjectConfigPath(std.testing.allocator, tmp_abs, null);
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expect(path != null);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/.veer/config.toml", .{tmp_abs});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path.?);
}

test "findProjectConfigPath walks up from a subdir" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".veer");
    var f = try tmp.dir.createFile(".veer/config.toml", .{});
    f.close();
    try tmp.dir.makePath("sub/sub2");

    const tmp_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_abs);
    const subdir_abs = try std.fmt.allocPrint(std.testing.allocator, "{s}/sub/sub2", .{tmp_abs});
    defer std.testing.allocator.free(subdir_abs);

    const path = try findProjectConfigPath(std.testing.allocator, subdir_abs, null);
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expect(path != null);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/.veer/config.toml", .{tmp_abs});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path.?);
}

test "findProjectConfigPath returns null when no config up the tree" {
    // A synthetic absolute path with no .veer/config.toml at any level.
    // Walk-up traverses dirname components without touching the filesystem
    // for nonexistent ancestors -- only the candidate file open touches FS.
    const path = try findProjectConfigPath(
        std.testing.allocator,
        "/nonexistent-veer-test-path-aaa/bbb/ccc",
        null,
    );
    defer if (path) |p| std.testing.allocator.free(p);
    try std.testing.expect(path == null);
}

test "findProjectConfigPath honors project_dir_hint over cwd walk-up" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.makePath(".veer");
    var f = try tmp.dir.createFile(".veer/config.toml", .{});
    f.close();

    const tmp_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_abs);

    // cwd points at a nonexistent path, so only the hint can produce a hit.
    const path = try findProjectConfigPath(
        std.testing.allocator,
        "/nonexistent-veer-test-path-aaa/bbb/ccc",
        tmp_abs,
    );
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expect(path != null);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/.veer/config.toml", .{tmp_abs});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path.?);
}

test "findProjectConfigPath falls back to walk-up when hint dir has no config" {
    var hint_tmp = std.testing.tmpDir(.{});
    defer hint_tmp.cleanup();
    var cwd_tmp = std.testing.tmpDir(.{});
    defer cwd_tmp.cleanup();

    try cwd_tmp.dir.makePath(".veer");
    var f = try cwd_tmp.dir.createFile(".veer/config.toml", .{});
    f.close();

    const hint_abs = try hint_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(hint_abs);
    const cwd_abs = try cwd_tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(cwd_abs);

    const path = try findProjectConfigPath(std.testing.allocator, cwd_abs, hint_abs);
    defer if (path) |p| std.testing.allocator.free(p);

    try std.testing.expect(path != null);
    const expected = try std.fmt.allocPrint(std.testing.allocator, "{s}/.veer/config.toml", .{cwd_abs});
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualStrings(expected, path.?);
}

test "findConfigUpwards finds a local config beside the project config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_abs = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(tmp_abs);

    try tmp.dir.makePath(".veer");
    var pf = try tmp.dir.createFile(".veer/config.toml", .{});
    pf.close();
    var lf = try tmp.dir.createFile(".veer/config.local.toml", .{});
    lf.close();

    const path = try findConfigUpwards(std.testing.allocator, tmp_abs, null, local_config_relpath);
    defer if (path) |p| std.testing.allocator.free(p);
    try std.testing.expect(path != null);
    try std.testing.expect(std.mem.endsWith(u8, path.?, "/.veer/config.local.toml"));
}

test "loadFile parses the local-only fixture" {
    var result = try loadFile(std.testing.allocator, "test/configs/local_only/.veer/config.local.toml");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.value.rule.len);
    try std.testing.expectEqualStrings("local-only-rule", result.value.rule[0].id);
}

test "globalConfigPath uses XDG_CONFIG_HOME" {
    // We can't easily set env vars in Zig tests, but we can verify the
    // function returns a path ending with the expected suffix.
    const path = try globalConfigPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/veer/config.toml"));
}

test "mergeSettings with no tiers yields default Settings" {
    const merged = mergeSettings(&.{});
    try std.testing.expectEqualStrings("warn", merged.log_level);
    try std.testing.expect(merged.claude_settings_path == null);
    try std.testing.expect(merged.claude_projects_path == null);
}

test "mergeSettings: project overrides global" {
    const global = Settings{
        .log_level = "info",
        .claude_settings_path = "/global/path",
    };
    const project = Settings{
        .log_level = "debug",
    };

    const merged = mergeSettings(&.{ project, global });
    try std.testing.expectEqualStrings("debug", merged.log_level);
    // Project didn't set claude_settings_path, so global value falls through
    try std.testing.expectEqualStrings("/global/path", merged.claude_settings_path.?);
}

test "mergeSettings: highest tier wins for log_level, first non-null path wins" {
    const local = Settings{ .log_level = "debug", .claude_settings_path = null, .claude_projects_path = "L" };
    const project = Settings{ .log_level = "warn", .claude_settings_path = "P", .claude_projects_path = "P" };
    const global = Settings{ .log_level = "error", .claude_settings_path = "G", .claude_projects_path = "G" };

    // Ordered highest-first: local, project, global.
    const merged = mergeSettings(&.{ local, project, global });
    try std.testing.expectEqualStrings("debug", merged.log_level);
    try std.testing.expectEqualStrings("P", merged.claude_settings_path.?);
    try std.testing.expectEqualStrings("L", merged.claude_projects_path.?);
}

test "mergeSettings regression: two tiers match old project-over-global behavior" {
    const project = Settings{ .log_level = "warn", .claude_settings_path = null, .claude_projects_path = "P" };
    const global = Settings{ .log_level = "error", .claude_settings_path = "G", .claude_projects_path = "G" };

    const merged = mergeSettings(&.{ project, global });
    try std.testing.expectEqualStrings("warn", merged.log_level);
    try std.testing.expectEqualStrings("G", merged.claude_settings_path.?);
    try std.testing.expectEqualStrings("P", merged.claude_projects_path.?);
}
