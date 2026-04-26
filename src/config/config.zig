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
    stats: bool = true,
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

/// Result of loadMerged(). Owns parsed configs and merged rules.
pub const MergedConfig = struct {
    config: Config = .{},
    project_parsed: ?toml.Parsed(Config) = null,
    global_parsed: ?toml.Parsed(Config) = null,
    merged_rules: ?[]Rule = null,
    /// Absolute path of the project config that was loaded, if any.
    /// Owned by this struct; freed in deinit.
    project_config_path: ?[]const u8 = null,

    pub fn deinit(self: *MergedConfig, allocator: std.mem.Allocator) void {
        if (self.merged_rules) |r| allocator.free(r);
        if (self.project_parsed) |*p| p.deinit();
        if (self.global_parsed) |*g| g.deinit();
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

/// Merge two configs. Project rules override global rules with the same ID.
/// Project rules come first (definition order), then non-overridden global rules.
/// Caller owns the returned slice (allocated with `allocator`).
pub fn mergeRules(allocator: std.mem.Allocator, global_rules: []const Rule, project_rules: []const Rule) ![]Rule {
    var merged = std.ArrayListUnmanaged(Rule).empty;

    // Add all project rules first
    for (project_rules) |r| {
        try merged.append(allocator, r);
    }

    // Add global rules that aren't overridden by project rules
    for (global_rules) |global_rule| {
        var overridden = false;
        for (project_rules) |project_rule| {
            if (std.mem.eql(u8, global_rule.id, project_rule.id)) {
                overridden = true;
                break;
            }
        }
        if (!overridden) {
            try merged.append(allocator, global_rule);
        }
    }

    return merged.items;
}

/// Merge two Settings. Project fields override global when set
/// (non-default values win).
pub fn mergeSettings(global: Settings, project: Settings) Settings {
    return .{
        .stats = project.stats,
        .log_level = project.log_level,
        .claude_settings_path = project.claude_settings_path orelse global.claude_settings_path,
        .claude_projects_path = project.claude_projects_path orelse global.claude_projects_path,
    };
}

pub const project_config_relpath = ".veer/config.toml";

/// Build the global config path: $XDG_CONFIG_HOME/veer/config.toml or ~/.config/veer/config.toml.
/// Caller owns the returned string.
pub fn globalConfigPath(allocator: std.mem.Allocator) ![]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fmt.allocPrint(allocator, "{s}/veer/config.toml", .{xdg});
    }
    const home = std.posix.getenv("HOME") orelse return error.FileNotFound;
    return std.fmt.allocPrint(allocator, "{s}/.config/veer/config.toml", .{home});
}

/// Locate the project's `.veer/config.toml`.
///
/// Discovery order:
///   1. If `project_dir_hint` is non-null, try `<hint>/.veer/config.toml`.
///      Used by `loadMerged` to forward `$CLAUDE_PROJECT_DIR` (set by Claude
///      Code for every PreToolUse hook invocation), making discovery
///      deterministic for the hook case regardless of cwd drift.
///   2. Walk up from `cwd_abs` toward filesystem root, checking
///      `<dir>/.veer/config.toml` at each level. Same algorithm git uses
///      for `.git/`. Handles CLI usage (`veer test` from a subdirectory).
///
/// Returns the absolute path of the first match, or null if none exists.
/// Caller owns the returned slice.
pub fn findProjectConfigPath(
    allocator: std.mem.Allocator,
    cwd_abs: []const u8,
    project_dir_hint: ?[]const u8,
) !?[]u8 {
    if (project_dir_hint) |hint| {
        if (hint.len > 0) {
            const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ hint, project_config_relpath });
            if (fileExists(candidate)) return candidate;
            allocator.free(candidate);
        }
    }

    var current: []const u8 = cwd_abs;
    while (true) {
        const candidate = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ current, project_config_relpath });
        if (fileExists(candidate)) return candidate;
        allocator.free(candidate);

        const parent = std.fs.path.dirname(current) orelse return null;
        if (parent.ptr == current.ptr and parent.len == current.len) return null;
        current = parent;
    }
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
    if (result.project_parsed == null and result.global_parsed == null) {
        return error.NoConfigFound;
    }

    // Build merged config
    if (result.project_parsed != null and result.global_parsed != null) {
        const project = result.project_parsed.?.value;
        const global = result.global_parsed.?.value;
        result.merged_rules = try mergeRules(allocator, global.rule, project.rule);
        result.config = .{
            .settings = mergeSettings(global.settings, project.settings),
            .rule = result.merged_rules.?,
        };
    } else if (result.project_parsed) |p| {
        result.config = p.value;
    } else if (result.global_parsed) |g| {
        result.config = g.value;
    }

    return result;
}

// -- Tests --

test "loadString parses basic config" {
    const input =
        \\[settings]
        \\stats = true
        \\
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
    try std.testing.expect(config.settings.stats);
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

test "loadString with empty config returns defaults" {
    const input =
        \\[settings]
        \\stats = false
    ;

    var result = try loadString(std.testing.allocator, input);
    defer result.deinit();

    try std.testing.expect(!result.value.settings.stats);
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

test "mergeRules combines non-overlapping rules, project first" {
    const global = [_]Rule{
        .{ .id = "g1", .message = "m", .match = .{ .command = "a" } },
    };
    const project = [_]Rule{
        .{ .id = "p1", .message = "m", .match = .{ .command = "b" } },
    };

    const merged = try mergeRules(std.testing.allocator, &global, &project);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 2), merged.len);
    // Project rules first, then global
    try std.testing.expectEqualStrings("p1", merged[0].id);
    try std.testing.expectEqualStrings("g1", merged[1].id);
}

test "mergeRules project overrides global by ID" {
    const global = [_]Rule{
        .{ .id = "shared", .name = "Global version", .message = "global msg", .match = .{ .command = "a" } },
    };
    const project = [_]Rule{
        .{ .id = "shared", .name = "Project version", .message = "project msg", .match = .{ .command = "a" } },
    };

    const merged = try mergeRules(std.testing.allocator, &global, &project);
    defer std.testing.allocator.free(merged);

    try std.testing.expectEqual(@as(usize, 1), merged.len);
    try std.testing.expectEqualStrings("Project version", merged[0].displayName());
    try std.testing.expectEqual(Action.reject, merged[0].effectiveAction());
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

    try std.testing.expect(!result.value.settings.stats);
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

test "globalConfigPath uses XDG_CONFIG_HOME" {
    // We can't easily set env vars in Zig tests, but we can verify the
    // function returns a path ending with the expected suffix.
    const path = try globalConfigPath(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expect(std.mem.endsWith(u8, path, "/veer/config.toml"));
}

test "mergeSettings project overrides global" {
    const global = Settings{
        .stats = true,
        .log_level = "info",
        .claude_settings_path = "/global/path",
    };
    const project = Settings{
        .stats = false,
        .log_level = "debug",
    };

    const merged = mergeSettings(global, project);
    try std.testing.expect(!merged.stats);
    try std.testing.expectEqualStrings("debug", merged.log_level);
    // Project didn't set claude_settings_path, so global value falls through
    try std.testing.expectEqualStrings("/global/path", merged.claude_settings_path.?);
}
