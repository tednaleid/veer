# Implementation Spec: veer - Stage 2: Config Loading + Rule Validation

**Contract**: `docs/spec/contract.md`
**References**: `docs/spec/veer-prd.md` (config format, rule schema, merging rules), `docs/spec/veer-spec.md` (Zig patterns)
**Depends on**: Stage 1 (build system must be working)
**Estimated Effort**: M

## Technical Approach

This stage implements TOML config parsing, rule structures, validation, and config merging. The config module defines what rules look like and how they're loaded -- it doesn't evaluate them (that's Stage 3).

Config files use the TOML schema defined in `docs/spec/veer-prd.md` lines 298-459. There are two config locations: global (`~/.config/veer/config.toml`) and project (`.veer/config.toml`). Project config is merged with global config, with project rules taking precedence by ID.

We use the zig-toml package (already declared in build.zig.zon from Stage 1) for parsing.

## Feedback Strategy

**Inner-loop command**: `zig build test`
**Playground**: Zig test blocks in `src/config/config.zig` and `src/config/rule.zig`, plus TOML fixture files in `test/configs/`
**Why this approach**: Config loading is a data-in/struct-out transformation. Table-driven tests with fixture files give clear pass/fail signals.

## File Changes

### New Files

| File Path | Purpose |
|-----------|---------|
| `src/config/rule.zig` | Rule, MatchConfig, Action, AstMatch structs + validation |
| `src/config/config.zig` | Config struct, TOML loading, file discovery, merging |
| `test/configs/basic.toml` | Simple config with 2-3 rules |
| `test/configs/complex_rules.toml` | Config exercising all match types and rule fields |
| `test/configs/empty.toml` | Empty/minimal config (just settings, no rules) |
| `test/configs/invalid_duplicate_id.toml` | Config with duplicate rule IDs (should fail validation) |
| `test/configs/invalid_missing_field.toml` | Config missing required fields (should fail validation) |

### Modified Files

| File Path | Changes |
|-----------|---------|
| `build.zig` | Add `src/config/config.zig` and `src/config/rule.zig` to test modules. Add zig-toml import to test builds. |

## Implementation Details

### Rule Struct (src/config/rule.zig)

Define all types from the TOML schema in `docs/spec/veer-prd.md` lines 298-358:

```zig
const std = @import("std");

pub const Action = enum {
    rewrite,
    warn,
    deny,
};

pub const AstMatch = struct {
    has_node: ?[]const u8 = null,
    min_depth: ?u32 = null,
    min_count: ?u32 = null,
};

pub const MatchConfig = struct {
    command: ?[]const u8 = null,
    command_glob: ?[]const u8 = null,
    command_regex: ?[]const u8 = null,
    pipeline_contains: ?[]const []const u8 = null,
    has_flag: ?[]const u8 = null,
    arg_pattern: ?[]const u8 = null,
    ast: ?AstMatch = null,
    tool: ?[]const u8 = null, // For non-Bash tool matching
};

pub const Rule = struct {
    id: []const u8,
    name: []const u8,
    action: Action,
    priority: i32 = 100,
    enabled: bool = true,
    tool: []const u8 = "Bash",
    message: ?[]const u8 = null,
    rewrite_to: ?[]const u8 = null,
    tags: ?[]const []const u8 = null,
    match: MatchConfig,
};
```

**Validation function:**
```zig
pub const ValidationError = error{
    MissingRequiredField,
    DuplicateRuleId,
    RewriteRequiresTarget,
    WarnDenyRequiresMessage,
    EmptyMatch,
};

pub fn validate(rules: []const Rule) ValidationError!void {
    // 1. Each rule must have non-empty id and name
    // 2. No duplicate IDs
    // 3. action=rewrite requires rewrite_to to be set
    // 4. action=warn/deny requires message to be set
    // 5. match must have at least one field set (not all null)
}
```

**Feedback loop**:
- **Playground**: Test blocks in rule.zig
- **Experiment**: Create a Rule with each action type, test validation passes. Create invalid rules, test validation fails.
- **Check command**: `zig build test`

### Config Loading (src/config/config.zig)

```zig
const std = @import("std");
const toml = @import("toml");
const Rule = @import("rule.zig").Rule;

pub const Settings = struct {
    stats: bool = true,
    log_level: []const u8 = "warn",
    claude_settings_path: ?[]const u8 = null,
    claude_projects_path: ?[]const u8 = null,
};

pub const Config = struct {
    settings: Settings,
    rules: []Rule,

    /// Rules sorted by priority (lower first), ready for evaluation.
    pub fn sortedRules(self: *Config) []Rule {
        std.sort.pdq(Rule, self.rules, {}, compareByPriority);
        return self.rules;
    }
};

pub const ConfigError = error{
    FileNotFound,
    ParseFailed,
    InvalidRule,
    MissingRequiredField,
    DuplicateRuleId,
    RewriteRequiresTarget,
    WarnDenyRequiresMessage,
    EmptyMatch,
};
```

**Key functions:**

```zig
/// Load config from a specific file path.
pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) ConfigError!Config

/// Load config from a TOML string (used by tests and parseFile).
pub fn loadString(allocator: std.mem.Allocator, toml_str: []const u8) ConfigError!Config

/// Discover and load merged config (project + global).
/// Searches: .veer/config.toml (project), then ~/.config/veer/config.toml (global).
pub fn loadMerged(allocator: std.mem.Allocator) ConfigError!Config

/// Merge two configs. Project rules override global rules with same ID.
pub fn merge(allocator: std.mem.Allocator, global: Config, project: Config) Config
```

**Config file discovery:**
1. Project: `.veer/config.toml` in the current working directory
2. Global: `~/.config/veer/config.toml` (use `$XDG_CONFIG_HOME/veer/config.toml` if set, fallback to `~/.config/veer/config.toml`)
3. If neither exists, return empty config with defaults

**Config merging rules** (from `docs/spec/veer-prd.md` lines 461-468):
1. Settings from project override global (per-field)
2. Rules merged by ID -- project rule with same ID replaces global rule entirely
3. All rules sorted by priority (lower first) for evaluation
4. A project rule can disable a global rule by setting `enabled = false` with the same ID

**Feedback loop**:
- **Playground**: TOML fixture files in `test/configs/` + test blocks in config.zig
- **Experiment**: Load each fixture, verify parsed Config matches expectations. Test merging with overlapping rule IDs.
- **Check command**: `zig build test`

## Testing Requirements

### Rule Validation Tests (src/config/rule.zig)

- Valid rule with all fields -- validation passes
- Missing `id` -- returns `MissingRequiredField`
- Missing `name` -- returns `MissingRequiredField`
- Duplicate rule IDs -- returns `DuplicateRuleId`
- action=rewrite without rewrite_to -- returns `RewriteRequiresTarget`
- action=warn without message -- returns `WarnDenyRequiresMessage`
- Match with no fields set -- returns `EmptyMatch`
- Rule with priority ordering -- lower priority sorts first

### Config Loading Tests (src/config/config.zig)

- Load `test/configs/basic.toml` -- correct number of rules, correct field values
- Load `test/configs/complex_rules.toml` -- all match types parsed correctly
- Load `test/configs/empty.toml` -- empty rules list, default settings
- Load from string with all rule fields -- round-trip correctness
- Load invalid TOML -- returns `ParseFailed`
- Load file that doesn't exist -- returns `FileNotFound`

### Config Merging Tests

- Global-only config -- all rules present
- Project-only config -- all rules present
- Both with non-overlapping rules -- union of rules
- Both with overlapping rule ID -- project rule wins
- Project disables global rule (`enabled = false`) -- rule excluded from sorted output
- Settings merge -- project fields override global, unset fields fall back to global

### Test Fixtures

**test/configs/basic.toml:**
```toml
[settings]
stats = true

[[rule]]
id = "use-just-test"
name = "Redirect pytest to just test"
action = "rewrite"
rewrite_to = "just test"
message = "Use just test."
[rule.match]
command = "pytest"

[[rule]]
id = "no-curl-pipe-bash"
name = "Block curl piped to bash"
action = "deny"
priority = 1
message = "Don't pipe curl to bash."
[rule.match]
pipeline_contains = ["curl", "bash"]
```

**test/configs/complex_rules.toml:**
Include rules exercising: `command`, `command_glob`, `command_regex`, `pipeline_contains`, `has_flag`, `arg_pattern`, `ast`, and non-Bash `tool` field. See `docs/spec/veer-prd.md` lines 361-459 for examples.

## Error Handling

| Scenario | Handling |
|----------|----------|
| TOML parse failure | Return `ConfigError.ParseFailed` |
| Config file not found | Return `ConfigError.FileNotFound` |
| Rule validation failure | Return specific `ConfigError` variant |
| No config files found | Return default Config (empty rules, default settings) |
| HOME / XDG_CONFIG_HOME not set | Fall back to `.veer/config.toml` only |

## Validation Commands

```bash
zig build test
```

## Open Items

- [ ] Confirm zig-toml API for deserializing into Zig structs (may need manual field mapping if comptime deserialization doesn't match our struct layout)
- [ ] Decide whether `loadString()` is needed separately from `loadFile()` -- useful for tests, but may be redundant
