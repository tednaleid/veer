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
} || ValidationError;

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
