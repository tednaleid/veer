# Local config tier

Status: design pending review.
Date: 2026-05-26.

## Summary

Add a third, project-local-but-gitignored config tier to veer:
`.veer/config.local.toml`. It sits beside the version-controlled
`.veer/config.toml` and lets a developer add or override rules for a single
repo without committing them. Precedence is **local > project > global**.

The feature is purely additive: a repo with no `config.local.toml` behaves
exactly as it does today. The only way to change existing behavior is to opt
in by creating the file.

## Motivation

Today veer reads two config files and merges them:

| Path | Scope |
|---|---|
| `.veer/config.toml` | per-repo, version-controlled |
| `~/.config/veer/config.toml` | personal, all projects |

There is no equivalent of Claude Code's `settings.local.json` -- a per-repo
file that stays out of version control. Developers who want repo-specific
rules that should not be committed (personal experiments, machine-specific
redirects, rules they are not ready to share) have no clean place to put
them. The only workaround is gitignoring `.veer/config.toml` itself, which
gives up the shared committed rules. This tier lets a developer have both a
committed project config and an uncommitted local overlay.

## Decisions

These were settled during brainstorming and are not open:

1. File name: `.veer/config.local.toml` (mirrors Claude Code's
   `settings.json` / `settings.local.json` pairing).
2. Precedence: local > project > global.
3. CLI: add a `--local` flag to `add`, `remove`, `validate` (the commands
   whose `--global` targets a config file, via `config_path.resolve`).
   `install` / `uninstall` already have `--local` via the `Scope` enum.
   `list` / `test` / `check` need no flag -- they read all tiers via
   `loadMerged` and surface local rules through the `source` column.
   `scan` is untouched (its `--global` means "scan global transcripts",
   not a config target).
4. Merge structure: ordered-tier fold (not repeated two-way merges).
5. Flag plumbing: a `Target` **tagged union** with `--config` folded in, so
   illegal flag combinations are unrepresentable past the CLI boundary.
6. `veer install --local` becomes a *fully private* install: hook into
   `.claude/settings.local.json` (already), config stub into
   `.veer/config.local.toml` (changed from the shared `.veer/config.toml`),
   and **no project skill file** (relies on a global skill install).
7. `install --local` ignore: add `.veer/config.local.toml` to the repo's
   `.git/info/exclude` (located via `git rev-parse --git-path info/exclude`,
   which resolves correctly in linked worktrees too). This keeps the ignore
   rule per-repo and uncommitted, so it never leaks to teammates. Append only
   if absent (idempotent); skip silently when not in a git repo. Chosen over
   the tracked `.gitignore` (which would commit the rule) and the global
   excludes (too broad). Verified empirically that `info/exclude` takes effect
   inside a worktree.

## Existing state worth noting

`veer install --local` and `veer uninstall --local` already exist and are
wired (`resolveScope` in `main.zig`, `Scope = enum { project, local, global }`
in `src/cli/install.zig`). Today `Scope.local` only half-privatizes:

| Artifact | `Scope.local` today | After this change |
|---|---|---|
| hook registration | `.claude/settings.local.json` | unchanged |
| config stub | `.veer/config.toml` (shared) | `.veer/config.local.toml` |
| skill file | `.claude/skills/veer/SKILL.md` (shared) | not written |

Redefining where `install --local` *writes* the config does not lose the
"shared rules + private hook" case: `loadMerged` still *reads* any committed
`.veer/config.toml` as the project tier, so a private `config.local.toml`
simply overlays whatever the team committed (if anything).

## Design

### 1. File and discovery

- New constant `local_config_relpath = ".veer/config.local.toml"` in
  `src/config/config.zig`, beside the existing `project_config_relpath`.
- The local file is discovered in the **same directory** where the project
  `config.toml` was found, so the two always pair from the project root
  regardless of cwd drift (Claude Code's Bash tool persists cwd between
  calls). Discovery reuses the existing upward directory walk and the
  `$CLAUDE_PROJECT_DIR` hint that `findProjectConfigPath` already implements.
- If no project `config.toml` exists, the local file is still searched for
  independently via the same walk. A local file alone is a valid config
  source.
- `error.NoConfigFound` is returned only when all three tiers are absent.

### 2. Merge semantics (ordered-tier fold)

- `RuleSource` changes from `enum { project, global }` to
  `enum { local, project, global }`.
- `mergeRules` is rewritten to fold over an ordered slice of tiers in
  precedence order `[local, project, global]`. First occurrence of a rule
  `id` wins; later tiers with the same id are dropped. Merged output order
  is local rules, then non-overridden project rules, then non-overridden
  global rules.
- Because rules evaluate first-match-wins, putting local rules first in the
  merged output also gives them first shot at matching, consistent with the
  precedence.
- `enabled = false` in a higher tier disables a lower-tier rule of the same
  id. This falls out of the id-wins logic for free (the higher-tier disabled
  rule replaces the lower-tier one, then is skipped at evaluation).
- **Regression guarantee:** when the local tier is absent or empty, the fold
  collapses to exactly `[project, global]` -- identical ordering, override,
  and disable semantics to today. Pinned by test.

### 3. Settings merge

- `mergeSettings` is extended to fold local -> project -> global. The
  highest tier that set a field wins. Same shape as the current two-way
  merge, one more layer. Applies to `log_level`, `claude_settings_path`,
  `claude_projects_path`.

### 4. CLI surface (`Target` tagged union)

- Introduce in `src/cli/config_path.zig`:

  ```zig
  const Target = union(enum) {
      project,
      local,
      global,
      config: []const u8, // explicit --config <path>
  };
  ```

- `resolve` returns one `Target`. This replaces the current
  `resolve(allocator, global: bool, config_arg: ?[]const u8)` signature.
  Past the CLI boundary there is no representable illegal state -- no
  "both global and local" combination exists in the type.
- The mutual-exclusion check (`--global` + `--local` + `--config` are
  mutually exclusive) lives in exactly one place: the CLI arg-parsing layer
  that collapses clap's separate raw flags into a single `Target`. Any pair
  set together yields `error.MutuallyExclusive`.
- `--local` is added only to `add`, `remove`, `validate` -- the commands
  whose `--global` resolves a config-file target through
  `config_path.resolve`. `--local` resolves to the relative
  `.veer/config.local.toml` (matching how the project default is relative).
- `resolve`'s flag inputs are collapsed into a `Target` by a pure
  `targetFromFlags(local, global, config_arg)` helper that returns
  `error.MutuallyExclusive` when more than one is set. `resolve(allocator,
  target)` then maps the `Target` to a path. This is the single CLI boundary
  where an illegal combination can be reported; everything downstream is a
  total `Target`.
- `install` / `uninstall` already accept `--local` via `resolveScope` and the
  `Scope` enum; their behavior changes are in section 5, not new flags.
- `install`'s `Scope` enum (`{ project, local, global }`) and
  `config_path`'s `Target` union (`{ project, local, global, config }`) stay
  as two distinct types: `install` has no `--config` option, and `Target`
  exists to resolve a single write path for `add`/`remove`/`validate`. Not
  unified (YAGNI).
- `list` and `test` already render a source column / field. `list.zig` uses
  `@tagName(source)`, so `local` appears automatically. `test_cmd.zig` has an
  explicit `switch` on `RuleSource` in `sourceSuffixFor` that must gain a
  `.local => "\tlocal"` arm (the compiler enforces this). Neither command
  gets a `--local` flag.
- `scan` is not modified.

### 5. `veer install --local` (modify existing `Scope.local`)

- `resolvePaths(.local)` changes the config target from `.veer/config.toml`
  to `.veer/config.local.toml`, and drops the skill (see below).
- `Paths.skill` becomes optional (`?[]const u8`). For `Scope.local` it is
  `null`. `install` skips `writeSkillFile` when skill is `null`; `uninstall`
  skips the skill-deletion step when skill is `null`. `Scope.project` and
  `Scope.global` keep writing/removing the skill as today.
- Rationale: Claude Code has no `skills.local` concept, so a project skill is
  always a committed footprint. A fully-private install relies on a global
  skill (`veer install --global`) for agent guidance.
- Config stub: writes a starter `.veer/config.local.toml` only if absent;
  never clobbers an existing local config (`ensureConfigStub` already
  no-ops when the file exists).
- ignore registration: add `.veer/config.local.toml` to the repo's
  `.git/info/exclude` -- git's per-repo, uncommitted ignore file. Locate it
  with `git rev-parse --git-path info/exclude` (returns the correct path in
  plain repos and in linked worktrees, where `.git` is a file). `info/exclude`
  patterns are relative to the repo root, so the entry is exactly
  `.veer/config.local.toml` (no relative-path computation). Append only if not
  already present (idempotent). If `git rev-parse` fails (not a git repo, or
  git unavailable), skip silently. Chosen over the tracked `.gitignore` (which
  would commit the ignore rule and leak veer to teammates) and over the global
  excludes (too broad). `.claude/settings.local.json` is Claude Code's own
  file; veer does not touch its ignore.
- The hook still goes into `.claude/settings.local.json` (unchanged).

### 5a. `veer uninstall --local`

- Removes the veer hook from `.claude/settings.local.json` (unchanged
  behavior).
- Deletes `.veer/config.local.toml` (the new local config target).
- Skips skill deletion (skill is `null` for `Scope.local`; the private
  install never wrote one).
- Does not remove the `config.local.toml` entry from `.git/info/exclude`
  (leave it; matching how uninstall otherwise avoids touching unrelated
  config, and a stale exclude entry for a deleted file is harmless).

### 6. `veer validate --local`

- Validates `.veer/config.local.toml` syntax and rule schema, mirroring
  `validate` and `validate --global`.

### 7. Documentation

- Update the embedded skill content `src/cli/skill_content.md` to document
  the three-tier table, the `--local` flag, and the fully-private
  `install --local` semantics (private hook, `config.local.toml`, no project
  skill, relies on a global skill). (Running `veer install` rewrites the
  checked-in `.claude/skills/veer/SKILL.md` from this content.) The existing
  `skill_content` sentinel tests in `install.zig` still pass; add analogous
  sentinels for the local-tier anchors if helpful.
- Update `README` to describe the local tier, the gitignore behavior, and the
  recommendation to run `veer install --global` once so the private
  `install --local` has a skill to lean on.
- Update the `install` / `uninstall` `--local` help text in `main.zig` to
  reflect the fully-private semantics (it currently only mentions the
  settings.local.json hook).

## Testing (red/green per CLAUDE.md)

- `mergeRules` three-tier: local overrides project overrides global by id;
  merged ordering is local, project, global; `enabled = false` disables
  across tiers.
- `mergeRules` regression: absent/empty local tier produces output identical
  to the current two-tier merge.
- `mergeSettings` three-way precedence: highest set tier wins per field.
- `resolve` with `Target`: each flag (`--local`, `--global`, `--config`,
  default) maps to the correct variant/path; any mutually-exclusive pair
  yields `error.MutuallyExclusive`.
- Local discovery: local file found beside project config; local-only (no
  project config) still loads; cwd-drift resolved via `$CLAUDE_PROJECT_DIR`
  hint.
- `resolvePaths(.local)`: config path is `.veer/config.local.toml`; skill is
  `null`; settings is `.claude/settings.local.json`.
- `install --local`: writes hook to `.claude/settings.local.json`; seeds
  `.veer/config.local.toml` when absent; does not clobber an existing local
  config; does **not** write a project skill file; adds `.veer/config.local.toml`
  to `.git/info/exclude` (located via `git rev-parse --git-path info/exclude`);
  idempotent (no duplicate entry on re-run); skips silently when not in a git
  repo.
- `uninstall --local`: removes hook from `.claude/settings.local.json`;
  deletes `.veer/config.local.toml`; does not error on a missing project
  skill.

## Non-goals

- No fully generic N-tier / arbitrary-depth config search (YAGNI; three
  fixed tiers).
- No change to the TOML rule schema itself.
- No change to existing flag spellings, and no behavior change for `install`
  (project), `install --global`, or rule evaluation when no
  `config.local.toml` exists. The one intentional behavior change is
  `install --local` / `uninstall --local` (config target and skill), which
  only affects developers who opt into the private install.
