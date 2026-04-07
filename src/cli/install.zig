// ABOUTME: Install / uninstall veer as a Claude Code PreToolUse hook.
// ABOUTME: Merges into settings.json, creates config stub, writes skill file.

const std = @import("std");

/// Skill content embedded at compile time. Written to disk on every install.
const skill_content = @embedFile("skill_content.md");

/// Starter config written when no .veer/config.toml exists. An active reject
/// rule so users aren't stuck with a hook that silently allows everything.
const config_stub =
    \\# veer rules - evaluated in order, first match wins.
    \\# Run 'veer list' to see active rules, 'veer test "<cmd>"' to preview behavior.
    \\# See .claude/skills/veer/SKILL.md for a guide on adding rules.
    \\
    \\[[rule]]
    \\id = "no-curl-pipe-shell"
    \\name = "Block curl piped to a shell"
    \\action = "reject"
    \\message = "Don't pipe curl to bash/sh -- download, inspect, then execute."
    \\[rule.match]
    \\command_all = ["curl", "bash"]
    \\
;

/// Gitignore content for the .veer/ directory. Excludes the SQLite database.
const gitignore_content = "veer.db\n";

/// The hook command registered in settings.json.
const hook_command = "veer check";

pub const Scope = enum { project, local, global };

pub const Paths = struct {
    settings: []const u8,
    config: []const u8,
    skill: []const u8,
};

/// Resolve absolute paths for the given install scope.
/// Global-scope paths are heap-allocated; call freePaths to release them.
pub fn resolvePaths(allocator: std.mem.Allocator, scope: Scope) !Paths {
    return switch (scope) {
        .project => .{
            .settings = ".claude/settings.json",
            .config = ".veer/config.toml",
            .skill = ".claude/skills/veer/SKILL.md",
        },
        .local => .{
            .settings = ".claude/settings.local.json",
            .config = ".veer/config.toml",
            .skill = ".claude/skills/veer/SKILL.md",
        },
        .global => blk: {
            const home = std.posix.getenv("HOME") orelse return error.NoHome;
            break :blk .{
                .settings = try std.fmt.allocPrint(allocator, "{s}/.claude/settings.json", .{home}),
                .config = try std.fmt.allocPrint(allocator, "{s}/.config/veer/config.toml", .{home}),
                .skill = try std.fmt.allocPrint(allocator, "{s}/.claude/skills/veer/SKILL.md", .{home}),
            };
        },
    };
}

pub fn freePaths(allocator: std.mem.Allocator, paths: Paths, scope: Scope) void {
    if (scope == .global) {
        allocator.free(paths.settings);
        allocator.free(paths.config);
        allocator.free(paths.skill);
    }
}

/// Install the veer hook:
///   1. Merge veer entry into settings.json (never overwrite unrelated hooks).
///   2. Create config.toml stub if missing.
///   3. Write .gitignore in config dir (excludes veer.db).
///   4. Write SKILL.md (always overwrite).
/// Returns process exit code (0 on success, 1 on user-facing error).
pub fn install(allocator: std.mem.Allocator, paths: Paths, writer: anytype) !u8 {
    const hook_code = try installHook(allocator, paths.settings, writer);
    if (hook_code != 0) return hook_code;
    try ensureConfigStub(paths.config, writer);
    try writeConfigDirGitignore(paths.config, writer);
    try writeSkillFile(paths.skill, writer);
    return 0;
}

/// Uninstall the veer hook:
///   1. Remove veer entry from settings.json (preserve unrelated hooks).
///   2. Delete config.toml, .gitignore, and veer.db from config dir.
///   3. Try to remove the config dir if empty.
///   4. Delete SKILL.md and parent veer/ skill dir if empty.
pub fn uninstall(allocator: std.mem.Allocator, paths: Paths, writer: anytype) !u8 {
    const hook_code = try uninstallHook(allocator, paths.settings, writer);
    if (hook_code != 0) return hook_code;
    try deleteIfExists(paths.config, "config", writer);
    // Clean up .gitignore and veer.db from the config directory.
    if (configDir(paths.config)) |dir| {
        try deleteInDir(dir, ".gitignore", writer);
        try deleteInDir(dir, "veer.db", writer);
        std.fs.cwd().deleteDir(dir) catch {};
    }
    try deleteIfExists(paths.skill, "skill", writer);
    // Remove parent veer/ skill dir if empty
    if (std.mem.lastIndexOfScalar(u8, paths.skill, '/')) |sep| {
        std.fs.cwd().deleteDir(paths.skill[0..sep]) catch {};
    }
    return 0;
}

// -- internal helpers --

fn installHook(allocator: std.mem.Allocator, path: []const u8, writer: anytype) !u8 {
    // Read existing file or start with {}
    const content = readFileAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, "{}"),
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try writer.print("veer install: cannot parse {s} (invalid JSON) -- fix or delete the file first\n", .{path});
        return 1;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try writer.print("veer install: {s} is valid JSON but not an object\n", .{path});
        return 1;
    }

    // Remove any existing veer entry first (enables updating stale entries).
    const was_present = removeVeerEntries(&parsed.value.object);

    const arena = parsed.arena.allocator();

    // Navigate / create hooks.PreToolUse array.
    const hooks_val = try getOrCreateObject(arena, &parsed.value.object, "hooks");
    const pretool_val = try getOrCreateArray(arena, &hooks_val.object, "PreToolUse");

    // Find the matcher="*" entry, or create one.
    var star_entry: *std.json.Value = blk: {
        for (pretool_val.array.items) |*entry| {
            if (entry.* == .object) {
                if (entry.object.get("matcher")) |m| {
                    if (m == .string and std.mem.eql(u8, m.string, "*")) {
                        break :blk entry;
                    }
                }
            }
        }
        // Append a new entry
        var new_obj: std.json.ObjectMap = .init(arena);
        try new_obj.put("matcher", .{ .string = "*" });
        try new_obj.put("hooks", .{ .array = .init(arena) });
        try pretool_val.array.append(.{ .object = new_obj });
        break :blk &pretool_val.array.items[pretool_val.array.items.len - 1];
    };

    // Get or create the nested "hooks" array on that matcher entry.
    const matcher_hooks = try getOrCreateArray(arena, &star_entry.object, "hooks");

    // Append {"type":"command","command":"veer check"}.
    var hook_obj: std.json.ObjectMap = .init(arena);
    try hook_obj.put("type", .{ .string = "command" });
    try hook_obj.put("command", .{ .string = hook_command });
    try matcher_hooks.array.append(.{ .object = hook_obj });

    try writeJsonAtomic(allocator, path, parsed.value);
    const verb: []const u8 = if (was_present) "updated" else "installed";
    try writer.print("veer hook {s} in {s}\n", .{ verb, path });
    return 0;
}

fn uninstallHook(allocator: std.mem.Allocator, path: []const u8, writer: anytype) !u8 {
    const content = readFileAlloc(allocator, path) catch |err| switch (err) {
        error.FileNotFound => {
            try writer.print("no veer hook in {s} (file not found)\n", .{path});
            return 0;
        },
        else => return err,
    };
    defer allocator.free(content);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, content, .{}) catch {
        try writer.print("veer uninstall: cannot parse {s} (invalid JSON) -- fix or delete the file first\n", .{path});
        return 1;
    };
    defer parsed.deinit();

    if (parsed.value != .object) {
        try writer.print("veer uninstall: {s} is valid JSON but not an object\n", .{path});
        return 1;
    }

    const removed = removeVeerEntries(&parsed.value.object);
    if (!removed) {
        try writer.print("no veer hook in {s}\n", .{path});
        return 0;
    }

    // If the object reduced to {}, delete the file entirely.
    if (parsed.value.object.count() == 0) {
        std.fs.cwd().deleteFile(path) catch {};
        try writer.print("veer hook removed from {s} (file deleted)\n", .{path});
        return 0;
    }

    try writeJsonAtomic(allocator, path, parsed.value);
    try writer.print("veer hook removed from {s}\n", .{path});
    return 0;
}

/// Walk obj -> hooks -> PreToolUse[] -> each entry -> hooks[], remove veer
/// entries, and prune empty containers. Returns true if anything was removed.
fn removeVeerEntries(root: *std.json.ObjectMap) bool {
    var removed_any = false;
    const hooks_val = root.getPtr("hooks") orelse return false;
    if (hooks_val.* != .object) return false;

    const pretool_val = hooks_val.object.getPtr("PreToolUse") orelse return false;
    if (pretool_val.* != .array) return false;

    // Walk matcher entries; rebuild the outer array filtering out ones that
    // become empty after removal.
    var i: usize = 0;
    while (i < pretool_val.array.items.len) {
        const entry = &pretool_val.array.items[i];
        if (entry.* != .object) {
            i += 1;
            continue;
        }
        const matcher_hooks = entry.object.getPtr("hooks");
        if (matcher_hooks == null or matcher_hooks.?.* != .array) {
            i += 1;
            continue;
        }
        // Filter out veer entries from this matcher's hooks[].
        var j: usize = 0;
        while (j < matcher_hooks.?.array.items.len) {
            if (isVeerHookEntry(&matcher_hooks.?.array.items[j])) {
                _ = matcher_hooks.?.array.orderedRemove(j);
                removed_any = true;
            } else {
                j += 1;
            }
        }
        // Drop the matcher entry entirely if its hooks[] is now empty.
        if (matcher_hooks.?.array.items.len == 0) {
            _ = pretool_val.array.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    if (!removed_any) return false;

    // Prune empty containers upward.
    if (pretool_val.array.items.len == 0) _ = hooks_val.object.swapRemove("PreToolUse");
    if (hooks_val.object.count() == 0) _ = root.swapRemove("hooks");
    return true;
}

fn isVeerHookEntry(v: *const std.json.Value) bool {
    if (v.* != .object) return false;
    const t = v.object.get("type") orelse return false;
    if (t != .string or !std.mem.eql(u8, t.string, "command")) return false;
    const c = v.object.get("command") orelse return false;
    if (c != .string) return false;
    return std.mem.eql(u8, c.string, hook_command);
}

fn getOrCreateObject(arena: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8) !*std.json.Value {
    if (obj.getPtr(key)) |existing| {
        if (existing.* == .object) return existing;
    }
    try obj.put(key, .{ .object = .init(arena) });
    return obj.getPtr(key).?;
}

fn getOrCreateArray(arena: std.mem.Allocator, obj: *std.json.ObjectMap, key: []const u8) !*std.json.Value {
    if (obj.getPtr(key)) |existing| {
        if (existing.* == .array) return existing;
    }
    try obj.put(key, .{ .array = .init(arena) });
    return obj.getPtr(key).?;
}

fn ensureConfigStub(path: []const u8, writer: anytype) !void {
    if (fileExistsAbs(path)) return;
    try ensureParentDir(path);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(config_stub);
    try writer.print("created {s}\n", .{path});
}

fn writeSkillFile(path: []const u8, writer: anytype) !void {
    try ensureParentDir(path);
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(skill_content);
    try writer.print("wrote skill {s}\n", .{path});
}

fn writeConfigDirGitignore(config_path: []const u8, writer: anytype) !void {
    const dir = configDir(config_path) orelse return;
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/.gitignore", .{dir}) catch return;
    const f = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(gitignore_content);
    try writer.print("wrote {s}\n", .{path});
}

/// Return the parent directory of config_path (e.g. ".veer" from ".veer/config.toml").
fn configDir(config_path: []const u8) ?[]const u8 {
    return if (std.mem.lastIndexOfScalar(u8, config_path, '/')) |sep|
        if (sep > 0) config_path[0..sep] else null
    else
        null;
}

fn deleteIfExists(path: []const u8, label: []const u8, writer: anytype) !void {
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try writer.print("removed {s} {s}\n", .{ label, path });
}

fn deleteInDir(dir: []const u8, name: []const u8, writer: anytype) !void {
    var path_buf: [1024]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, name }) catch return;
    std.fs.cwd().deleteFile(path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    try writer.print("removed {s}\n", .{path});
}

fn fileExistsAbs(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

fn ensureParentDir(path: []const u8) !void {
    if (std.mem.lastIndexOfScalar(u8, path, '/')) |sep| {
        if (sep > 0) try std.fs.cwd().makePath(path[0..sep]);
    }
}

fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const f = try std.fs.cwd().openFile(path, .{});
    defer f.close();
    return try f.readToEndAlloc(allocator, 1024 * 1024);
}

fn writeJsonAtomic(allocator: std.mem.Allocator, path: []const u8, value: std.json.Value) !void {
    const json_text = try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
    defer allocator.free(json_text);

    try ensureParentDir(path);
    const tmp_path = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp_path);

    {
        const f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(json_text);
        try f.writeAll("\n");
    }
    try std.fs.cwd().rename(tmp_path, path);
}

// -- Tests --

const testing = std.testing;

/// Build a Paths struct rooted at a tmp dir (absolute paths).
fn testPaths(allocator: std.mem.Allocator, tmp_root: []const u8) !Paths {
    return .{
        .settings = try std.fmt.allocPrint(allocator, "{s}/.claude/settings.json", .{tmp_root}),
        .config = try std.fmt.allocPrint(allocator, "{s}/.veer/config.toml", .{tmp_root}),
        .skill = try std.fmt.allocPrint(allocator, "{s}/.claude/skills/veer/SKILL.md", .{tmp_root}),
    };
}

fn freeTestPaths(allocator: std.mem.Allocator, paths: Paths) void {
    allocator.free(paths.settings);
    allocator.free(paths.config);
    allocator.free(paths.skill);
}

fn testWriteFile(path: []const u8, content: []const u8) !void {
    try ensureParentDir(path);
    const f = try std.fs.cwd().createFile(path, .{});
    defer f.close();
    try f.writeAll(content);
}

test "install merges into empty settings.json" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    // Pre-populate settings.json with {}
    try testWriteFile(paths.settings, "{}");

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const code = try install(testing.allocator, paths, stream.writer());
    try testing.expectEqual(@as(u8, 0), code);

    const content = try readFileAlloc(testing.allocator, paths.settings);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "veer check") != null);
    try testing.expect(std.mem.indexOf(u8, content, "PreToolUse") != null);
}

test "install preserves existing non-veer PreToolUse hook" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    // Pre-populate with a different PreToolUse hook
    const existing =
        \\{
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      {"matcher":"*","hooks":[{"type":"command","command":"other-tool check"}]}
        \\    ]
        \\  }
        \\}
    ;
    try testWriteFile(paths.settings, existing);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try install(testing.allocator, paths, stream.writer());

    const content = try readFileAlloc(testing.allocator, paths.settings);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "other-tool check") != null);
    try testing.expect(std.mem.indexOf(u8, content, "veer check") != null);
}

test "install is idempotent (no duplicate veer entries)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    _ = try install(testing.allocator, paths, stream.writer());
    stream.reset();
    _ = try install(testing.allocator, paths, stream.writer());

    const content = try readFileAlloc(testing.allocator, paths.settings);
    defer testing.allocator.free(content);
    // Count occurrences of "veer check" -- should be exactly 1
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, "veer check")) |pos| {
        count += 1;
        i = pos + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "install rejects invalid JSON in settings.json" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    const bad = "{not json at all";
    try testWriteFile(paths.settings, bad);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const code = try install(testing.allocator, paths, stream.writer());
    try testing.expectEqual(@as(u8, 1), code);

    // Original file must be untouched
    const content = try readFileAlloc(testing.allocator, paths.settings);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(bad, content);
}

test "install creates .veer/config.toml stub when missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try install(testing.allocator, paths, stream.writer());

    const content = try readFileAlloc(testing.allocator, paths.config);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "no-curl-pipe-shell") != null);
    try testing.expect(std.mem.indexOf(u8, content, "[[rule]]") != null);
}

test "install preserves existing config.toml" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    const user_config = "# user rules\n[[rule]]\nid = \"user-rule\"\n";
    try testWriteFile(paths.config, user_config);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try install(testing.allocator, paths, stream.writer());

    const content = try readFileAlloc(testing.allocator, paths.config);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(user_config, content);
}

test "install always overwrites skill file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    // Pre-populate with stale content
    try testWriteFile(paths.skill, "stale content");

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try install(testing.allocator, paths, stream.writer());

    const content = try readFileAlloc(testing.allocator, paths.skill);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings(skill_content, content);
}

test "uninstall removes veer entry, preserves others" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    // settings.json with both veer AND another hook under a different matcher
    const starting =
        \\{
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      {"matcher":"*","hooks":[{"type":"command","command":"veer check"}]},
        \\      {"matcher":"Write","hooks":[{"type":"command","command":"other-tool"}]}
        \\    ]
        \\  }
        \\}
    ;
    try testWriteFile(paths.settings, starting);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try uninstall(testing.allocator, paths, stream.writer());

    const content = try readFileAlloc(testing.allocator, paths.settings);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "veer check") == null);
    try testing.expect(std.mem.indexOf(u8, content, "other-tool") != null);
}

test "uninstall deletes config and skill" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    try testWriteFile(paths.config, "# rules\n");
    try testWriteFile(paths.skill, "# skill\n");
    try testWriteFile(paths.settings, "{}");

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try uninstall(testing.allocator, paths, stream.writer());

    try testing.expect(!fileExistsAbs(paths.config));
    try testing.expect(!fileExistsAbs(paths.skill));
}

test "uninstall is idempotent (nothing to remove)" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    const code = try uninstall(testing.allocator, paths, stream.writer());
    try testing.expectEqual(@as(u8, 0), code);
}

test "install creates .veer/.gitignore" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try install(testing.allocator, paths, stream.writer());

    var gi_buf: [1024]u8 = undefined;
    const gi_path = try std.fmt.bufPrint(&gi_buf, "{s}/.veer/.gitignore", .{tmp_root});
    const content = try readFileAlloc(testing.allocator, gi_path);
    defer testing.allocator.free(content);
    try testing.expectEqualStrings("veer.db\n", content);
}

test "uninstall removes gitignore and veer.db" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    // Create the files that install would create, plus a veer.db
    try testWriteFile(paths.config, "# rules\n");
    try testWriteFile(paths.settings, "{}");
    var gi_buf: [1024]u8 = undefined;
    const gi_path = try std.fmt.bufPrint(&gi_buf, "{s}/.veer/.gitignore", .{tmp_root});
    try testWriteFile(gi_path, gitignore_content);
    var db_buf: [1024]u8 = undefined;
    const db_path = try std.fmt.bufPrint(&db_buf, "{s}/.veer/veer.db", .{tmp_root});
    try testWriteFile(db_path, "fake db");

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try uninstall(testing.allocator, paths, stream.writer());

    try testing.expect(!fileExistsAbs(gi_path));
    try testing.expect(!fileExistsAbs(db_path));
    try testing.expect(!fileExistsAbs(paths.config));
    // .veer/ dir should be gone (was empty after deletions)
    var dir_buf: [1024]u8 = undefined;
    const dir_path = try std.fmt.bufPrint(&dir_buf, "{s}/.veer", .{tmp_root});
    try testing.expect(!fileExistsAbs(dir_path));
}

test "uninstall removes empty PreToolUse/hooks after veer entry removal" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    // Only veer in settings.json -- after uninstall, file should be gone
    const starting =
        \\{
        \\  "hooks": {
        \\    "PreToolUse": [
        \\      {"matcher":"*","hooks":[{"type":"command","command":"veer check"}]}
        \\    ]
        \\  }
        \\}
    ;
    try testWriteFile(paths.settings, starting);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try uninstall(testing.allocator, paths, stream.writer());

    // File should be deleted (only contained veer's hook which is now removed,
    // leaving {}).
    try testing.expect(!fileExistsAbs(paths.settings));
}
