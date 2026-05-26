# Local Config Tier Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third, gitignored `.veer/config.local.toml` config tier (precedence local > project > global) and make `veer install --local` a fully private install.

**Architecture:** Generalize the two-way config merge into an ordered-tier fold over `[local, project, global]` (first-id-wins, output preserves tier order). Replace `config_path.resolve`'s `global: bool` with a `Target` tagged union built by a pure `targetFromFlags` helper, so illegal flag combinations are unrepresentable past the CLI boundary. Redefine `Scope.local` in the installer to seed `config.local.toml`, skip the project skill, and exclude the local config via the repo's `.git/info/exclude` (per-repo, uncommitted).

**Tech Stack:** Zig 0.15.2, clap (CLI), zig-toml. Tests live in `test` blocks at the bottom of each source file; run via `just test` / `just check`. Spec: `docs/spec/local-config-tier.md`.

**Build/test commands (use these, not raw zig):**
- `just test` -- run all tests
- `just check` -- tests + `zig fmt --check` + smoke tests (this is what the pre-commit hook runs)
- `just build` -- build debug binary

**Conventions you must follow:**
- Every source file starts with two `// ABOUTME:` comment lines (already present in the files you touch -- do not remove them).
- New test modules go in `src/test_all.zig`, but every file you touch here already has `test` blocks wired in, so no new module registration is needed.
- Use `std.testing.allocator` in tests (it detects leaks).
- `src/engine/` must never import `src/store/`; not relevant here but do not introduce new cross-layer imports.
- Match surrounding style. Do not reformat untouched code or change whitespace.

---

## File Structure

Files created or modified, with responsibility:

- `src/config/config.zig` (modify) -- `RuleSource` enum, `RuleTier` type, `mergeRules` fold, `mergeSettings` fold, `MergedConfig.local_parsed`, `loadMerged` local discovery + load, `local_config_relpath`, generalized `findConfigUpwards`.
- `src/cli/test_cmd.zig` (modify) -- add `.local` arm to the `RuleSource` switch in `sourceSuffixFor`.
- `src/cli/config_path.zig` (modify) -- `Target` union, `targetFromFlags`, `resolve(target)` rewrite.
- `src/cli/install.zig` (modify) -- `Paths.skill` optional, `resolvePaths(.local)` config path, `install`/`uninstall` skill guards, `install` git-exclude append for local scope (`.git/info/exclude`), exclude helpers (`gitInfoExcludePath`, `appendExcludeEntry`, `ensureLocalConfigExcluded`).
- `src/main.zig` (modify) -- `--local` flag on `add`/`remove`/`validate`, `resolveRuleConfigPathOrExit` signature, `install`/`uninstall` help text, pass `scope` into `install_cmd.install`.
- `src/cli/skill_content.md` (modify) -- document the three-tier table, `--local`, private install.
- `README.md` (modify) -- document the local tier and the `.git/info/exclude` behavior.

---

## Task 1: Add `local` to `RuleSource` and the test_cmd switch

This is first because adding the enum variant breaks the exhaustive `switch` in `test_cmd.zig` (the compiler enforces it). Doing both together keeps the tree compiling.

**Files:**
- Modify: `src/config/config.zig:37`
- Modify: `src/cli/test_cmd.zig:117-123`

- [ ] **Step 1: Add the `local` variant to `RuleSource`**

In `src/config/config.zig`, change line 37 from:

```zig
pub const RuleSource = enum { project, global };
```

to:

```zig
pub const RuleSource = enum { local, project, global };
```

- [ ] **Step 2: Build to see the exhaustive-switch failure**

Run: `just build`
Expected: FAIL. Compile error in `src/cli/test_cmd.zig` `sourceSuffixFor`: the `switch` on `RuleSource` does not handle `.local`.

- [ ] **Step 3: Add the `.local` arm to `sourceSuffixFor`**

In `src/cli/test_cmd.zig`, the switch currently reads:

```zig
            return switch (src) {
                .project => "\tproject",
                .global => "\tglobal",
            };
```

Add the `.local` arm (keep ordering consistent with the enum):

```zig
            return switch (src) {
                .local => "\tlocal",
                .project => "\tproject",
                .global => "\tglobal",
            };
```

- [ ] **Step 4: Build to verify it compiles**

Run: `just build`
Expected: PASS (binary builds). `list.zig` needs no change -- it uses `@tagName(source)`, which renders `local` automatically.

- [ ] **Step 5: Commit**

```bash
git add src/config/config.zig src/cli/test_cmd.zig
git commit -m "Add local variant to RuleSource"
```

---

## Task 2: Generalize `mergeRules` into an ordered-tier fold

Replace the two-argument `mergeRules(global_rules, project_rules)` with a fold over an ordered slice of tiers (earlier tier = higher precedence, first occurrence of an `id` wins, output preserves tier order). This subsumes the old "project first, then non-overridden global" behavior when called with `[project, global]`.

**Files:**
- Modify: `src/config/config.zig:105-134` (the `mergeRules` function)
- Modify: `src/config/config.zig:377-438` (the three existing `mergeRules` tests)

- [ ] **Step 1: Write failing three-tier tests**

In `src/config/config.zig`, the existing tests call `mergeRules(allocator, &global, &project)`. Replace the three existing tests (`"mergeRules combines non-overlapping rules, project first"`, `"mergeRules tags sources for several rules in each list"`, `"mergeRules project overrides global by ID"`) with the following block, which uses the new tier API:

```zig
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
```

- [ ] **Step 2: Run tests to verify they fail to compile**

Run: `just test`
Expected: FAIL. `mergeRules` still has the old two-slice signature and `RuleTier` does not exist yet, so the test block does not compile.

- [ ] **Step 3: Add `RuleTier` and rewrite `mergeRules`**

In `src/config/config.zig`, add the `RuleTier` type just above `MergeResult` (near line 39):

```zig
/// One tier of rules to merge, tagged with where it came from.
/// In `mergeRules`, earlier tiers have higher precedence.
pub const RuleTier = struct {
    rules: []const Rule,
    source: RuleSource,
};
```

Replace the entire `mergeRules` function (currently lines 102-134) with:

```zig
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

    return .{
        .rules = try rules.toOwnedSlice(allocator),
        .sources = try sources.toOwnedSlice(allocator),
    };
}
```

- [ ] **Step 4: Build to find the now-broken `loadMerged` callsite**

Run: `just build`
Expected: FAIL. `loadMerged` (around line 246) still calls `mergeRules(allocator, global.rule, project.rule)` with the old signature. Leave it for Task 4 -- but to keep this task's tests runnable, temporarily update only that one call. Replace the block at lines 243-263 with this interim version (it will be rewritten in Task 4):

```zig
    if (result.project_parsed != null and result.global_parsed != null) {
        const project = result.project_parsed.?.value;
        const global = result.global_parsed.?.value;
        const tiers = [_]RuleTier{
            .{ .rules = project.rule, .source = .project },
            .{ .rules = global.rule, .source = .global },
        };
        const merge = try mergeRules(allocator, &tiers);
        result.merged_rules = merge.rules;
        result.sources = merge.sources;
        result.config = .{
            .settings = mergeSettings(global.settings, project.settings),
            .rule = merge.rules,
        };
    } else if (result.project_parsed) |p| {
        result.config = p.value;
        const sources = try allocator.alloc(RuleSource, p.value.rule.len);
        @memset(sources, .project);
        result.sources = sources;
    } else if (result.global_parsed) |g| {
        result.config = g.value;
        const sources = try allocator.alloc(RuleSource, g.value.rule.len);
        @memset(sources, .global);
        result.sources = sources;
    }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test`
Expected: PASS. All four new `mergeRules` tests pass; existing `loadMerged` tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/config/config.zig
git commit -m "Generalize mergeRules into an ordered-tier fold"
```

---

## Task 3: Generalize `mergeSettings` into a tier fold

Change `mergeSettings(global, project)` to `mergeSettings(tiers: []const Settings)` where `tiers` is ordered highest-precedence-first. The highest tier's `log_level` wins; each path takes the first non-null walking highest to lowest. With `[project, global]` this reproduces today's behavior exactly.

**Files:**
- Modify: `src/config/config.zig:136-144` (`mergeSettings`)
- Modify: `src/config/config.zig` (the interim `loadMerged` callsite from Task 2, the `mergeSettings` call)
- Test: `src/config/config.zig` (new test block)

- [ ] **Step 1: Write the failing test**

Add to `src/config/config.zig` test section:

`Settings` (defined at `src/config/config.zig:15`) is:

```zig
pub const Settings = struct {
    log_level: []const u8 = "warn",
    claude_settings_path: ?[]const u8 = null,
    claude_projects_path: ?[]const u8 = null,
};
```

So `log_level` is a string, not an enum. The tests:

```zig
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: FAIL. `mergeSettings` still takes two `Settings` args, so the new tests do not compile.

- [ ] **Step 3: Rewrite `mergeSettings`**

Replace `mergeSettings` (lines 136-144) with:

```zig
/// Fold Settings tiers ordered highest-precedence-first. The highest tier's
/// `log_level` wins; each optional path takes the first non-null tier walking
/// highest to lowest. An empty slice yields default Settings.
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
```

- [ ] **Step 4: Update the interim `loadMerged` callsite**

In the `loadMerged` block from Task 2, change:

```zig
            .settings = mergeSettings(global.settings, project.settings),
```

to:

```zig
            .settings = mergeSettings(&.{ project.settings, global.settings }),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test`
Expected: PASS. New `mergeSettings` tests pass; `loadMerged` tests still pass.

- [ ] **Step 6: Commit**

```bash
git add src/config/config.zig
git commit -m "Generalize mergeSettings into a tier fold"
```

---

## Task 4: Discover and load the local tier in `loadMerged`

Add `local_config_relpath`, a `local_parsed` field, generalize `findProjectConfigPath` into `findConfigUpwards(relpath)`, discover the local file (sibling of the project config when one is found, else an independent upward walk), and replace the branchy merge block with a single ordered-tier fold over the present tiers.

**Files:**
- Modify: `src/config/config.zig` (`MergedConfig`, `local_config_relpath`, `findConfigUpwards`/`findProjectConfigPath`, `loadMerged`)
- Test: `src/config/config.zig` + a new fixture dir

- [ ] **Step 1: Add `local_config_relpath` and the `local_parsed` field**

In `src/config/config.zig`, just after `project_config_relpath` (line 146) add:

```zig
pub const local_config_relpath = ".veer/config.local.toml";
```

In `MergedConfig` (struct starting line 47), add the field after `global_parsed`:

```zig
    local_parsed: ?toml.Parsed(Config) = null,
```

and in `MergedConfig.deinit`, after the `global_parsed` deinit line, add:

```zig
        if (self.local_parsed) |*l| l.deinit();
```

- [ ] **Step 2: Generalize the upward search**

Rename the body of `findProjectConfigPath` into a `relpath`-parameterized helper and keep `findProjectConfigPath` as a thin wrapper so existing callers/tests are unaffected. Replace `findProjectConfigPath` (lines 171-194) with:

```zig
/// Walk up from `cwd_abs` (and an optional `project_dir_hint`) looking for
/// `<dir>/<relpath>`. Returns the absolute path of the first match, or null.
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
```

- [ ] **Step 3: Load the local file and fold all present tiers in `loadMerged`**

In `loadMerged`, after the block that sets `result.project_parsed` (the `if (cwd_abs) |cwd| { ... }` block ending around line 223), add local-tier discovery. Insert immediately after that block:

```zig
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
```

Then replace the entire merge block (the `if (result.project_parsed != null and ...)` chain, lines 243-263 / the interim version from Tasks 2-3) with a uniform fold:

```zig
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
```

Note: the `NoConfigFound` guard (`if (result.project_parsed == null and result.global_parsed == null) return error.NoConfigFound;`) currently sits before the merge block. Update it to also account for the local tier:

```zig
    if (result.project_parsed == null and result.global_parsed == null and result.local_parsed == null) {
        return error.NoConfigFound;
    }
```

Place that guard after local discovery and before the fold.

- [ ] **Step 4: Write failing discovery tests**

Create the fixture file `test/configs/local_only/.veer/config.local.toml` with:

```toml
[[rule]]
id = "local-only-rule"
message = "from local"
[rule.match]
command = "localcmd"
```

Add tests to `src/config/config.zig`. The existing `findProjectConfigPath` tests show the tmpDir pattern; mirror it:

```zig
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

test "loadMerged loads a local-only config (no project, no global)" {
    // Point discovery at a fixture dir that has only config.local.toml.
    // loadMerged reads cwd; use an explicit relpath search instead to assert
    // the file parses and tags as .local via the single-tier fold path.
    var result = try loadFile(std.testing.allocator, "test/configs/local_only/.veer/config.local.toml");
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), result.value.rule.len);
    try std.testing.expectEqualStrings("local-only-rule", result.value.rule[0].id);
}
```

Note on the second test: `loadMerged` keys off the real cwd, which a unit test cannot easily relocate without a `chdir`, and the existing suite avoids `chdir`. The fold logic for the local-only case is already covered by Task 2's "single tier" test (with `.local`). If you want a true end-to-end local-only `loadMerged` test, add it to the Justfile smoke tests instead (see Task 9), where a real directory and cwd are available.

- [ ] **Step 5: Run tests to verify the discovery test fails first, then passes**

Run: `just test`
Expected: the `findConfigUpwards` local test FAILS before Step 2-3 are in place; after implementing Steps 1-3 it PASSES. Run again after implementation:

Run: `just test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add src/config/config.zig test/configs/local_only/.veer/config.local.toml
git commit -m "Discover and merge the local config tier in loadMerged"
```

---

## Task 5: `Target` tagged union in `config_path.zig`

Replace `resolve(allocator, global: bool, config_arg)` with a `Target` union plus a pure `targetFromFlags` helper. `--local` resolves to the relative `.veer/config.local.toml`.

**Files:**
- Modify: `src/cli/config_path.zig` (whole file)

- [ ] **Step 1: Write failing tests**

Replace the existing tests in `src/cli/config_path.zig` (lines 49-74) with:

```zig
test "targetFromFlags: default is project" {
    try testing.expectEqual(Target.project, try targetFromFlags(false, false, null));
}

test "targetFromFlags: --local selects local" {
    try testing.expectEqual(Target.local, try targetFromFlags(true, false, null));
}

test "targetFromFlags: --global selects global" {
    try testing.expectEqual(Target.global, try targetFromFlags(false, true, null));
}

test "targetFromFlags: --config selects config path" {
    const t = try targetFromFlags(false, false, "custom/foo.toml");
    try testing.expectEqualStrings("custom/foo.toml", t.config);
}

test "targetFromFlags: any two set is mutually exclusive" {
    try testing.expectError(error.MutuallyExclusive, targetFromFlags(true, true, null));
    try testing.expectError(error.MutuallyExclusive, targetFromFlags(true, false, "f.toml"));
    try testing.expectError(error.MutuallyExclusive, targetFromFlags(false, true, "f.toml"));
}

test "resolve: project yields .veer/config.toml" {
    var r = try resolve(testing.allocator, .project);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(".veer/config.toml", r.path);
    try testing.expect(r.paths_handle == null);
}

test "resolve: local yields .veer/config.local.toml" {
    var r = try resolve(testing.allocator, .local);
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings(".veer/config.local.toml", r.path);
    try testing.expect(r.paths_handle == null);
}

test "resolve: config yields the explicit path" {
    var r = try resolve(testing.allocator, .{ .config = "custom/foo.toml" });
    defer r.deinit(testing.allocator);
    try testing.expectEqualStrings("custom/foo.toml", r.path);
    try testing.expect(r.paths_handle == null);
}

test "resolve: global yields ~/.config/veer/config.toml" {
    var r = try resolve(testing.allocator, .global);
    defer r.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, r.path, "/.config/veer/config.toml"));
    try testing.expect(r.paths_handle != null);
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: FAIL. `Target` and `targetFromFlags` do not exist; `resolve` has the old signature.

- [ ] **Step 3: Rewrite the module API**

In `src/cli/config_path.zig`, change `ResolveError` to drop the now-unused `MutuallyExclusive` (it moves to `targetFromFlags`), keeping `NoHome` and `OutOfMemory`:

```zig
pub const ResolveError = error{
    /// --global was set but $HOME is not in the environment.
    NoHome,
    OutOfMemory,
};

pub const FlagError = error{
    /// More than one of --local / --global / --config was set.
    MutuallyExclusive,
};

/// Which config file a write command (`add`/`remove`/`validate`) targets.
pub const Target = union(enum) {
    project,
    local,
    global,
    config: []const u8,
};

/// Collapse the raw CLI flags into a single `Target`. This is the one place
/// an illegal combination can be reported; the returned `Target` is total.
pub fn targetFromFlags(local: bool, global: bool, config_arg: ?[]const u8) FlagError!Target {
    var count: u8 = 0;
    if (local) count += 1;
    if (global) count += 1;
    if (config_arg != null) count += 1;
    if (count > 1) return error.MutuallyExclusive;
    if (config_arg) |p| return .{ .config = p };
    if (global) return .global;
    if (local) return .local;
    return .project;
}
```

Replace the doc comment and body of `resolve` (lines 30-45) with:

```zig
/// Resolve a `Target` to a concrete config-file path. `--global` allocates
/// (call `Resolved.deinit`); the other variants borrow static/argument
/// strings.
pub fn resolve(allocator: std.mem.Allocator, target: Target) ResolveError!Resolved {
    return switch (target) {
        .project => .{ .path = ".veer/config.toml" },
        .local => .{ .path = ".veer/config.local.toml" },
        .config => |p| .{ .path = p },
        .global => blk: {
            const paths = install_cmd.resolvePaths(allocator, .global) catch |err| switch (err) {
                error.NoHome => return error.NoHome,
                error.OutOfMemory => return error.OutOfMemory,
            };
            break :blk .{ .path = paths.config, .paths_handle = paths };
        },
    };
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: FAIL to build -- `src/main.zig` still calls `resolve(allocator, global, config_arg)`. That is fixed in Task 6. To verify just this module in isolation is not straightforward (tests build as one binary), so proceed to Task 6 and run tests at the end of Task 6.

- [ ] **Step 5: Commit**

```bash
git add src/cli/config_path.zig
git commit -m "Replace config_path bool flag with a Target tagged union"
```

---

## Task 6: Wire `--local` into `add`/`remove`/`validate` in `main.zig`

Add the `--local` flag to the three commands and update `resolveRuleConfigPathOrExit` to build a `Target` via `targetFromFlags`.

**Files:**
- Modify: `src/main.zig` (params for add/remove/validate; `resolveRuleConfigPathOrExit`)

- [ ] **Step 1: Update `resolveRuleConfigPathOrExit`**

Replace the function (lines 710-725) with:

```zig
fn resolveRuleConfigPathOrExit(allocator: std.mem.Allocator, local: bool, global: bool, config_arg: ?[]const u8, verb: []const u8) config_path_mod.Resolved {
    const target = config_path_mod.targetFromFlags(local, global, config_arg) catch {
        std.debug.print("veer {s}: --local, --global, and --config are mutually exclusive\n", .{verb});
        std.process.exit(1);
    };
    return config_path_mod.resolve(allocator, target) catch |err| switch (err) {
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
```

- [ ] **Step 2: Add the `--local` param and update the call for `add`**

In `runAdd` params (lines 440-451), add a `--local` line after the `--config` line:

```zig
        \\    --config <str>      Path to config file (default: .veer/config.toml).
        \\    --local             Write to .veer/config.local.toml (gitignored) instead.
        \\    --global            Write to ~/.config/veer/config.toml instead.
```

Update the call (line 461):

```zig
    var resolved = resolveRuleConfigPathOrExit(allocator, res.args.local != 0, res.args.global != 0, res.args.config, "add");
```

- [ ] **Step 3: Add the `--local` param and update the call for `remove`**

In `runRemove` params (lines 487-493), add `--local`:

```zig
        \\    --config <str>  Path to config file (default: .veer/config.toml).
        \\    --local         Remove from .veer/config.local.toml (gitignored) instead.
        \\    --global        Remove from ~/.config/veer/config.toml instead.
```

Update the call (line 509):

```zig
    var resolved = resolveRuleConfigPathOrExit(allocator, res.args.local != 0, res.args.global != 0, res.args.config, "remove");
```

- [ ] **Step 4: Add the `--local` param and update the call for `validate`**

In `runValidate` params (lines 677-682), add `--local`:

```zig
        \\    --config <str>  Path to config file (default: .veer/config.toml).
        \\    --local         Validate .veer/config.local.toml (gitignored) instead.
        \\    --global        Validate ~/.config/veer/config.toml instead.
```

Update the call (line 692):

```zig
    var resolved = resolveRuleConfigPathOrExit(allocator, res.args.local != 0, res.args.global != 0, res.args.config, "validate");
```

- [ ] **Step 5: Build and run the full suite**

Run: `just test`
Expected: PASS. The Task 5 `config_path` tests now compile and pass; nothing else regressed.

- [ ] **Step 6: Manually verify the flags resolve**

Run:
```bash
just build
./zig-out/bin/veer validate --local --global
```
Expected: prints `veer validate: --local, --global, and --config are mutually exclusive` and exits non-zero.

- [ ] **Step 7: Commit**

```bash
git add src/main.zig
git commit -m "Add --local flag to add, remove, and validate"
```

---

## Task 7: Make `Scope.local` a fully private install (config + skill)

Point `resolvePaths(.local)` at `.veer/config.local.toml`, make `Paths.skill` optional (`null` for local), and guard skill write/delete on non-null.

**Files:**
- Modify: `src/cli/install.zig` (`Paths`, `resolvePaths`, `freePaths`, `install`, `uninstall`, test helpers)

- [ ] **Step 1: Write failing tests**

Add to `src/cli/install.zig` test section:

```zig
test "resolvePaths(.local) targets config.local.toml and no skill" {
    const paths = try resolvePaths(testing.allocator, .local);
    defer freePaths(testing.allocator, paths, .local);
    try testing.expectEqualStrings(".claude/settings.local.json", paths.settings);
    try testing.expectEqualStrings(".veer/config.local.toml", paths.config);
    try testing.expect(paths.skill == null);
}

test "install with null skill writes no skill file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    const paths = Paths{
        .settings = try std.fmt.allocPrint(testing.allocator, "{s}/.claude/settings.local.json", .{tmp_root}),
        .config = try std.fmt.allocPrint(testing.allocator, "{s}/.veer/config.local.toml", .{tmp_root}),
        .skill = null,
    };
    defer testing.allocator.free(paths.settings);
    defer testing.allocator.free(paths.config);

    var buf: [4096]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    _ = try install(testing.allocator, paths, .local, false, stream.writer());

    // Config stub written to the local path; no skill dir created.
    try testing.expect(fileExistsAbs(paths.config));
    var skill_buf: [1024]u8 = undefined;
    const skill_path = try std.fmt.bufPrint(&skill_buf, "{s}/.claude/skills/veer/SKILL.md", .{tmp_root});
    try testing.expect(!fileExistsAbs(skill_path));
}
```

Note: the `install` signature gains a `scope` parameter in Step 3; existing `install(...)` test calls must be updated to pass `.project` (Step 4 covers this).

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: FAIL. `Paths.skill` is not optional, `resolvePaths(.local)` returns the shared config path, and `install` does not take a `scope`.

- [ ] **Step 3: Make `Paths.skill` optional and update `resolvePaths`/`freePaths`**

In `src/cli/install.zig`, change `Paths` (lines 44-48):

```zig
pub const Paths = struct {
    settings: []const u8,
    config: []const u8,
    skill: ?[]const u8,
};
```

Update `resolvePaths` (lines 52-73): the `.project` and `.global` arms keep their skill strings; change the `.local` arm to:

```zig
        .local => .{
            .settings = ".claude/settings.local.json",
            .config = ".veer/config.local.toml",
            .skill = null,
        },
```

Update `freePaths` (lines 75-81) to guard skill:

```zig
pub fn freePaths(allocator: std.mem.Allocator, paths: Paths, scope: Scope) void {
    if (scope == .global) {
        allocator.free(paths.settings);
        allocator.free(paths.config);
        if (paths.skill) |s| allocator.free(s);
    }
}
```

- [ ] **Step 4: Thread `scope` through `install` and guard the skill write**

Change the `install` signature (line 90) to take `scope`:

```zig
pub fn install(allocator: std.mem.Allocator, paths: Paths, scope: Scope, verbose: bool, writer: anytype) !u8 {
    const hook_code = try installHook(allocator, paths.settings, verbose, writer);
    if (hook_code != 0) return hook_code;
    try ensureConfigStub(paths.config, writer);
    if (paths.skill) |skill| try writeSkillFile(skill, writer);
    if (scope == .local) try ensureLocalConfigExcluded(allocator, local_config_relpath, writer);
    return 0;
}
```

`local_config_relpath` is `".veer/config.local.toml"` (defined in `src/config/config.zig`; import it as needed, e.g. `const config_mod = @import("../config/config.zig");` and use `config_mod.local_config_relpath`, or hardcode the string with a comment -- match how the file already references config paths). `ensureLocalConfigExcluded` is implemented in Task 8. For this task, add a temporary no-op stub so the build passes:

```zig
fn ensureLocalConfigExcluded(allocator: std.mem.Allocator, config_relpath: []const u8, writer: anytype) !void {
    _ = allocator;
    _ = config_relpath;
    _ = writer;
}
```

Task 8 replaces this stub with the real implementation.

- [ ] **Step 5: Guard the skill delete in `uninstall`**

In `uninstall` (lines 105-122), replace the skill-deletion lines:

```zig
    try deleteIfExists(paths.skill, "skill", writer);
    // Remove parent veer/ skill dir if empty
    if (std.mem.lastIndexOfScalar(u8, paths.skill, '/')) |sep| {
        std.fs.cwd().deleteDir(paths.skill[0..sep]) catch {};
    }
```

with:

```zig
    if (paths.skill) |skill| {
        try deleteIfExists(skill, "skill", writer);
        // Remove parent veer/ skill dir if empty
        if (std.mem.lastIndexOfScalar(u8, skill, '/')) |sep| {
            std.fs.cwd().deleteDir(skill[0..sep]) catch {};
        }
    }
```

- [ ] **Step 6: Update existing `install` call sites and test helpers**

The `testPaths` helper (lines 384-390) returns `.skill` as a string -- that is fine (`?[]const u8` accepts it). The `freeTestPaths` helper frees `paths.skill` unconditionally; change it to guard:

```zig
fn freeTestPaths(allocator: std.mem.Allocator, paths: Paths) void {
    allocator.free(paths.settings);
    allocator.free(paths.config);
    if (paths.skill) |s| allocator.free(s);
}
```

Update every existing `install(testing.allocator, paths, false, stream.writer())` call in the test block to pass `.project` as the new scope arg: `install(testing.allocator, paths, .project, false, stream.writer())`. There are several (search for `try install(testing.allocator, paths,`). The two-arg `--verbose` install tests pass `true`/`false` for verbose; insert `.project` before that bool.

Also update the production call site in `src/main.zig` `runInstall` (line 331):

```zig
    const exit_code = install_cmd.install(allocator, paths, scope, verbose, stream.writer()) catch |err| {
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `just test`
Expected: PASS. The new `resolvePaths(.local)` and null-skill install tests pass; existing install/uninstall tests still pass with the `.project` scope arg.

- [ ] **Step 8: Commit**

```bash
git add src/cli/install.zig src/main.zig
git commit -m "Make install --local fully private (config.local.toml, no skill)"
```

---

## Task 8: Add the local config to `.git/info/exclude`

Replace the Task 7 stub with a real `ensureLocalConfigExcluded` that adds `.veer/config.local.toml` to the repo's `.git/info/exclude` -- git's per-repo, UNCOMMITTED ignore file. This avoids the leak inherent in editing the tracked `.gitignore` (whose modification would eventually be committed and expose veer to teammates) and the over-breadth of the global excludes.

**Why `git rev-parse --git-path info/exclude` and not a hardcoded `.git/info/exclude`:** in a linked git worktree, `.git` is a FILE pointing at `<repo>/.git/worktrees/<name>`, so the literal path does not exist. `git rev-parse --git-path info/exclude` returns the correct path in plain repos, worktrees, and submodules (verified empirically: it resolves to the shared common-dir `info/exclude`, and an entry there takes effect inside worktrees). `info/exclude` patterns are matched relative to the repo root, exactly like a root `.gitignore`, so the entry is simply `.veer/config.local.toml` with no relative-path math.

**Files:**
- Modify: `src/cli/install.zig` (`ensureLocalConfigExcluded` + helpers + tests)

- [ ] **Step 1: Write failing tests**

Add to `src/cli/install.zig` test section. The `appendExcludeEntry` helper is cwd-independent (takes an absolute path), so it is driven directly with a tmp file. `gitInfoExcludePath` shells out to git; tests run inside the veer git repo, so it returns a real path ending in `info/exclude`.

```zig
test "appendExcludeEntry adds the entry to an existing file" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    var ex_buf: [1024]u8 = undefined;
    const ex_path = try std.fmt.bufPrint(&ex_buf, "{s}/exclude", .{tmp_root});
    try testWriteFile(ex_path, "# git ignore patterns\n*~\n");

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try appendExcludeEntry(testing.allocator, ex_path, ".veer/config.local.toml", stream.writer());

    const content = try readFileAlloc(testing.allocator, ex_path);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, ".veer/config.local.toml") != null);
    try testing.expect(std.mem.indexOf(u8, content, "*~") != null);
}

test "appendExcludeEntry creates the file when missing" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    // Path under an existing dir, but the exclude file itself does not exist yet.
    var ex_buf: [1024]u8 = undefined;
    const ex_path = try std.fmt.bufPrint(&ex_buf, "{s}/exclude", .{tmp_root});

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try appendExcludeEntry(testing.allocator, ex_path, ".veer/config.local.toml", stream.writer());

    const content = try readFileAlloc(testing.allocator, ex_path);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, ".veer/config.local.toml") != null);
}

test "appendExcludeEntry is idempotent" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(tmp_root);

    var ex_buf: [1024]u8 = undefined;
    const ex_path = try std.fmt.bufPrint(&ex_buf, "{s}/exclude", .{tmp_root});
    try testWriteFile(ex_path, ".veer/config.local.toml\n");

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try appendExcludeEntry(testing.allocator, ex_path, ".veer/config.local.toml", stream.writer());

    const content = try readFileAlloc(testing.allocator, ex_path);
    defer testing.allocator.free(content);
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, content, i, ".veer/config.local.toml")) |pos| {
        count += 1;
        i = pos + 1;
    }
    try testing.expectEqual(@as(usize, 1), count);
}

test "gitInfoExcludePath returns a path inside a git repo" {
    // The test process runs inside the veer git repo, so git resolves a path.
    const path = try gitInfoExcludePath(testing.allocator);
    defer if (path) |p| testing.allocator.free(p);
    try testing.expect(path != null);
    try testing.expect(std.mem.endsWith(u8, std.mem.trim(u8, path.?, " \t\r\n"), "info/exclude"));
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test`
Expected: FAIL. `appendExcludeEntry` and `gitInfoExcludePath` do not exist.

- [ ] **Step 3: Implement the helpers**

In `src/cli/install.zig`, replace the Task 7 stub `ensureLocalConfigExcluded` with the following. First confirm the `std.process.Child.run` API against the installed stdlib (`/opt/homebrew/Cellar/zig@0.15/0.15.2/lib/zig/std/process/Child.zig`): it takes a struct with `.allocator` and `.argv` and returns a result with `.term` and owned `.stdout` / `.stderr`. Adjust field/method names if 0.15.2 differs.

```zig
const std = @import("std"); // already imported at top of file; do not duplicate

/// Resolve the repo's per-repo exclude file via git. Returns its path
/// (possibly relative to cwd) or null if not in a git repo / git unavailable.
/// `git rev-parse --git-path info/exclude` resolves correctly in plain repos
/// and in linked worktrees (where `.git` is a file). Caller owns the slice.
fn gitInfoExcludePath(allocator: std.mem.Allocator) !?[]u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "--git-path", "info/exclude" },
    }) catch return null;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    if (result.term != .Exited or result.term.Exited != 0) return null;
    const trimmed = std.mem.trim(u8, result.stdout, " \t\r\n");
    if (trimmed.len == 0) return null;
    return try allocator.dupe(u8, trimmed);
}

/// Append `entry` to the git exclude file at `exclude_path` if no line already
/// equals it (after trimming). Creates the file if it does not exist (its
/// parent `info/` dir always exists in a valid git repo). Idempotent. Uses the
/// read-then-rewrite idiom from `writeSkillFile`/`writeJsonAtomic`.
fn appendExcludeEntry(allocator: std.mem.Allocator, exclude_path: []const u8, entry: []const u8, writer: anytype) !void {
    const content = readFileAlloc(allocator, exclude_path) catch |err| switch (err) {
        error.FileNotFound => try allocator.dupe(u8, ""),
        else => return err,
    };
    defer allocator.free(content);

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), entry)) return;
    }

    const needs_nl = content.len > 0 and content[content.len - 1] != '\n';
    const f = try std.fs.cwd().createFile(exclude_path, .{ .truncate = true });
    defer f.close();
    try f.writeAll(content);
    if (needs_nl) try f.writeAll("\n");
    try f.writeAll(entry);
    try f.writeAll("\n");
    try writer.print("excluded {s} via {s}\n", .{ entry, exclude_path });
}

/// For a local install, add the local config to the repo's `.git/info/exclude`
/// (per-repo, uncommitted). Silently does nothing when not in a git repo.
/// `config_relpath` is the repo-root-relative path (".veer/config.local.toml"),
/// which is exactly the pattern `info/exclude` expects.
fn ensureLocalConfigExcluded(allocator: std.mem.Allocator, config_relpath: []const u8, writer: anytype) !void {
    const exclude_path = (try gitInfoExcludePath(allocator)) orelse return;
    defer allocator.free(exclude_path);
    try appendExcludeEntry(allocator, exclude_path, config_relpath, writer);
}
```

Notes:
- Do NOT add a second `const std = @import("std");` -- it is already at the top of the file; the line above is only to show which namespace is used.
- `readFileAlloc` and the `createFile(.{ .truncate = true })` pattern already exist in this file; reuse them.
- The `gitInfoExcludePath` test asserts the returned path ends in `info/exclude`; the path may be relative (e.g. `.git/info/exclude`) when git is run from the repo root, which is fine -- `std.fs.cwd()` operations in `appendExcludeEntry` honor cwd.

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test`
Expected: PASS.

- [ ] **Step 5: Manually verify end to end (including a worktree)**

Run:
```bash
just build
BIN="$PWD/zig-out/bin/veer"
# Plain repo:
d="$(mktemp -d)"; ( cd "$d" && git init -q && "$BIN" install --local \
  && echo "--- check-ignore ---" && git check-ignore .veer/config.local.toml \
  && echo "--- status (should NOT list config.local.toml) ---" && git status --porcelain \
  && echo "--- .gitignore must NOT exist or NOT mention veer ---" && (cat .gitignore 2>/dev/null || echo "(no .gitignore -- good)") \
  && ls -a .claude .veer )
rm -rf "$d"
```
Expected: `git check-ignore` prints `.veer/config.local.toml`; `git status --porcelain` does NOT list it; there is no `.gitignore` (veer did not create or touch one); `.claude/settings.local.json` and `.veer/config.local.toml` exist; no `.claude/skills/veer/SKILL.md`.

Optionally also verify inside a worktree of that repo (`git worktree add ../wt` then run `install --local` there and confirm `git check-ignore` works), to confirm the `git rev-parse --git-path` resolution.

- [ ] **Step 6: Commit**

```bash
git add src/cli/install.zig
git commit -m "Exclude local config via .git/info/exclude on install --local"
```

---

## Task 9: Documentation and smoke tests

Update the embedded skill content, README, and `install`/`uninstall` help text. Add a smoke-test recipe exercising the local tier end to end.

**Files:**
- Modify: `src/cli/skill_content.md`
- Modify: `README.md`
- Modify: `src/main.zig` (install/uninstall `--local` help text)
- Modify: `Justfile` (smoke test recipe)
- Test: `src/cli/install.zig` (skill_content sentinel)

- [ ] **Step 1: Add a sentinel test for the local-tier docs**

In `src/cli/install.zig`, alongside the existing `skill_content documents ...` tests (lines 409-423), add:

```zig
test "skill_content documents the local config path" {
    try testing.expect(std.mem.indexOf(u8, skill_content, ".veer/config.local.toml") != null);
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `just test`
Expected: FAIL -- `skill_content.md` does not yet mention `.veer/config.local.toml`.

- [ ] **Step 3: Update `src/cli/skill_content.md`**

In the "Two config files: project and global" section, change the heading and table to cover three tiers. Update the table to add the local row:

```
| Path | Scope | Use it for |
|---|---|---|
| `.veer/config.local.toml` | per-repo, gitignored | personal per-repo rules not shared with the team |
| `.veer/config.toml` | per-repo, version-controlled | repo-specific tooling redirects |
| `~/.config/veer/config.toml` | personal, all projects | cross-cutting personal preferences |
```

Add a short paragraph after the table:

```
Precedence is local > project > global: a local rule with the same `id` as a
project or global rule replaces it (and `enabled = false` in the local file
disables a lower-tier rule). `veer install --local` is a fully private
install -- it puts the hook in `.claude/settings.local.json`, seeds
`.veer/config.local.toml`, adds that file to `.git/info/exclude` (git's
per-repo, uncommitted ignore so it never leaks to teammates), and writes no
project skill (it relies on a global skill from `veer install --global`). Use
it when you want veer in a repo your teammates do not use.
```

Document the `--local` flag in the "Adding a rule" section near the `--global` examples:

```
`veer add --local`, `veer remove --local`, and `veer validate --local` target
`.veer/config.local.toml`.
```

- [ ] **Step 4: Run the sentinel test**

Run: `just test`
Expected: PASS.

- [ ] **Step 5: Update `README.md`**

Find the section documenting the two config files (search for `~/.config/veer/config.toml`). Add the local tier to the table/list, document precedence (local > project > global), and add a short "Private install" note describing `veer install --local` (private hook, `config.local.toml`, added to `.git/info/exclude` so it stays uncommitted, no project skill, recommend running `veer install --global` once for the skill). Keep prose plain: no emojis, no em dashes, no hyperbole (per repo conventions).

- [ ] **Step 6: Update install/uninstall help text in `main.zig`**

In `runInstall`'s `install_desc` (lines 286-310), replace the `--local` paragraph (lines 294-295):

```zig
        \\With --local, this is a fully private install: the hook goes into
        \\.claude/settings.local.json, the config stub is written to
        \\.veer/config.local.toml (and added to .git/info/exclude so it stays
        \\uncommitted), and no project skill is written. Run 'veer install
        \\--global' once so a global skill is available.
```

Update the `--local` flag summary line (line 279):

```zig
        \\    --local    Fully private install: hook in settings.local.json, config.local.toml, no project skill.
```

In `runUninstall`'s `uninstall_desc` (lines 348-365), replace the `--local` paragraph (lines 356-357):

```zig
        \\With --local, the hook is removed from .claude/settings.local.json and
        \\.veer/config.local.toml is deleted (the private install never wrote a
        \\project skill, and the .git/info/exclude entry is left in place).
```

Update the `--local` flag summary line (line 344):

```zig
        \\    --local   Uninstall the private install: settings.local.json hook and config.local.toml.
```

- [ ] **Step 7: Add a smoke-test recipe to the `Justfile`**

Open the `Justfile`, find the existing smoke-test recipes (`check-allow`, `check-rewrite`, `check-deny`, and the `check-from-subdir` recipes referenced in `just check` output). Add a recipe that exercises the local tier override end to end. Model it on the existing smoke recipes (they build the binary and pipe a hook envelope into `veer check`). Example shape (adapt the envelope JSON and assertions to match the existing recipes' style):

```just
# Verify a local-tier rule overrides a project rule of the same id.
check-local-override: build
    #!/usr/bin/env bash
    set -euo pipefail
    tmp="$(mktemp -d)"
    mkdir -p "$tmp/.veer"
    cat > "$tmp/.veer/config.toml" <<'EOF'
    [[rule]]
    id = "shared"
    action = "reject"
    message = "PROJECT rule"
    [rule.match]
    command = "danger"
    EOF
    cat > "$tmp/.veer/config.local.toml" <<'EOF'
    [[rule]]
    id = "shared"
    action = "reject"
    message = "LOCAL rule wins"
    [rule.match]
    command = "danger"
    EOF
    out="$(cd "$tmp" && echo '{"tool_name":"Bash","tool_input":{"command":"danger"}}' | "{{justfile_directory()}}/zig-out/bin/veer" check 2>&1 || true)"
    echo "$out" | grep -q "LOCAL rule wins" && echo "check-local-override: PASS" || { echo "check-local-override: FAIL"; echo "$out"; exit 1; }
    rm -rf "$tmp"
```

If `just check` aggregates smoke recipes via a list, add `check-local-override` to that aggregation so it runs in CI.

- [ ] **Step 8: Run the full check suite**

Run: `just check`
Expected: PASS -- all tests, `zig fmt --check`, and every smoke recipe including `check-local-override`.

- [ ] **Step 9: Regenerate the checked-in skill and verify no unintended drift**

The checked-in `.claude/skills/veer/SKILL.md` is generated from `skill_content.md`. Per project history (`759f13f update checked in skill`), regenerate it:

```bash
./zig-out/bin/veer install   # rewrites .claude/skills/veer/SKILL.md from the embedded content
git diff --stat
```
Expected: only `.claude/skills/veer/SKILL.md` (and possibly `.veer/config.toml` if absent) change, reflecting the new local-tier docs. Review the diff.

- [ ] **Step 10: Commit**

```bash
git add src/cli/skill_content.md src/cli/install.zig README.md src/main.zig Justfile .claude/skills/veer/SKILL.md
git commit -m "Document the local config tier and private install"
```

---

## Self-Review (completed during planning)

**Spec coverage:**
- Section 1 (file + discovery) -> Task 4. Section 2 (merge fold) -> Tasks 1, 2. Section 3 (settings fold) -> Task 3. Section 4 (Target union + which commands get --local) -> Tasks 5, 6, plus `list`/`test` source rendering in Task 1. Section 5 (install --local) -> Tasks 7, 8. Section 5a (uninstall --local) -> Task 7. Section 6 (validate --local) -> Task 6. Section 7 (docs) -> Task 9. Testing section -> covered across tasks.
- Regression guarantee (absent local tier == today) -> Task 2 "regression" test + Task 3 "regression" test.

**Type/name consistency check:**
- `RuleSource` = `{ local, project, global }` used consistently (Tasks 1, 2, 4).
- `RuleTier { rules, source }` defined Task 2, consumed Task 4.
- `mergeRules(allocator, []const RuleTier)` signature consistent Tasks 2, 4.
- `mergeSettings(&.{...})` (highest-first) consistent Tasks 3, 4.
- `Target { project, local, global, config }`, `targetFromFlags(local, global, config_arg)`, `resolve(allocator, target)` consistent Tasks 5, 6.
- `resolveRuleConfigPathOrExit(allocator, local, global, config_arg, verb)` consistent Tasks 6.
- `Paths.skill: ?[]const u8`, `install(allocator, paths, scope, verbose, writer)` consistent Tasks 7, 8, 9, and the `src/main.zig` call site.
- `ensureLocalConfigExcluded` / `gitInfoExcludePath` / `appendExcludeEntry` defined Task 8 (`ensureLocalConfigExcluded` stubbed Task 7).

**Verified against source during planning:** `Settings.log_level` is a `[]const u8` (default `"warn"`), so Task 3 uses string literals and `expectEqualStrings`. Task 8 locates the per-repo exclude file with `git rev-parse --git-path info/exclude` (verified to resolve correctly inside a worktree) and appends via the existing read-then-rewrite `createFile(.{ .truncate = true })` idiom (same as `writeSkillFile`), avoiding any seek-API uncertainty.
