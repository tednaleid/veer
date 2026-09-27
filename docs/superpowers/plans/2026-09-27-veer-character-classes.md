# veer Character Classes and Stop Rules Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let veer rules forbid named character classes (emoji, status markers, em dashes) in any text Claude writes through a tool, and in Claude's finished replies via the `Stop` hook.

**Architecture:** A new `src/engine/chars.zig` owns character classification (backed by a generated Unicode table) and markdown code-span masking. Rules gain an `event` field (`PreToolUse` or `Stop`), a `tool = "*"` wildcard, and a `content_chars` matcher. The hook parser extracts content for every tool that writes text and reads `Stop` input; `veer check` answers `Stop` with non-error `additionalContext` feedback. `veer install` registers the `Stop` hook next to `PreToolUse`.

**Tech Stack:** Zig 0.16.0, `sam701/zig-toml`, `zig-clap`, tree-sitter-bash (vendored), SQLite (vendored), a `uv` Python script for table generation.

**Spec:** `docs/superpowers/specs/2026-09-27-veer-character-classes-design.md`
**ADR:** `docs/adr/0001-hook-events-beyond-pretooluse.md`
**Glossary:** `CONTEXT.md` (Rule, Hook event, Tool, Character class)

## Global Constraints

- **Zig 0.16.0.** Stdlib reference: `/opt/homebrew/Cellar/zig/0.16.0/lib/zig/std/`. Read `CLAUDE.md` for the 0.15 to 0.16 API differences before writing code. Verify any stdlib call used below (`std.unicode.utf8Decode`, `std.unicode.utf8ByteSequenceLength`, `std.Io.Writer.Allocating`) against the stdlib source; if a signature differs, adapt the call, not the design.
- **Use the Justfile.** `just check` (tests + lint + smoke tests, what CI and the pre-commit hook run), `just test`, `just lint`, `just fmt`, `just build`. Never invoke `zig build` directly when a recipe exists.
- **Never use `--no-verify` when committing.** Every commit must pass `just check`.
- **Red/green TDD.** Write the failing test, run it, see it fail for the right reason, then implement.
- **Tests live in `test` blocks at the bottom of the file they test.** Register every new source file in `src/test_all.zig`.
- **`std.testing.allocator` in every test.** Table-driven tests via `inline for` over anonymous struct tuples.
- **Every new code file starts with two `// ABOUTME: ` lines** (`# ABOUTME: ` for Python).
- **`src/config/` must not import from `src/engine/`.** Schema enums (`Event`, `ContentFormat`, `CharClass`) live in `src/config/rule.zig`; `src/engine/chars.zig` imports them.
- **Test source uses `\u{...}` escapes for emoji and symbols**, never literal glyphs, so the source stays readable and greppable.
- **No emoji, em dashes, or hyperbole in docs or comments.** Comments state what is true now.
- **veer fails open.** Any parse, allocation, or I/O failure while evaluating content means "no match", never a rejection.
- **Commit trailer:** every commit message ends with
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`

## Review Focus

1. **Invalid UTF-8 in content** (binary-ish Write content, truncated strings): scanning must not crash or read out of bounds; invalid bytes are skipped. Test in Task 1.
2. **Searching for a banned character with Grep/Read**: must never be rejected by a `tool = "*"` rule. Test in Task 5.
3. **A `Stop` hook when no rule is a Stop rule, or when the event is unknown (`MessageDisplay`, `SubagentStop`)**: exit 0 with no output, never "invalid JSON input". Test in Task 6.
4. **Existing configs keep working**: rules without `event` stay PreToolUse; `content_regex` on ExitPlanMode is unchanged; Bash rewrites are unchanged. Covered by the existing suite passing plus the test in Task 4.
5. **`stop_hook_active` loop guard**: a second Stop in a row must allow even when the reply still has emoji. Test in Task 6.

## File Structure

**New:**
- `scripts/gen_emoji_table.py`: downloads Unicode `emoji-data.txt` and writes the range table.
- `src/engine/emoji_table.zig`: generated, checked in. `Emoji_Presentation` and `Emoji` ranges.
- `src/engine/chars.zig`: character classes, UTF-8 scanning, code-span masking, hit formatting.

**Modified:**
- `src/config/rule.zig`: `Event`, `ContentFormat`, `CharClass`, `content_chars`, `event`, `tool = "*"`, `toolFields`, `contentFormatFor`, validation.
- `src/cli/validate_cmd.zig`: messages for the new validation errors.
- `src/config/config.zig`: TOML parse test for the new fields.
- `src/engine/matcher.zig`: `matchContent` gains a format parameter and `content_chars`.
- `src/engine/engine.zig`: `ToolCall.event`, `ToolCall.content_format`, event filtering, `CheckResult.content_chars`.
- `src/claude/hook.zig`: `hook_event_name`, Stop input, per-tool content extraction, `formatStopFeedback`.
- `src/cli/check.zig`: Stop output, loop guard, hit lines on stderr.
- `src/main.zig`: larger check output buffers, `veer test --event`.
- `src/cli/install.zig`: register and remove the Stop hook.
- `src/cli/test_cmd.zig`: `--event`, content format by tool, hit lines.
- `src/cli/list.zig`: show `Stop` in the tool column for Stop rules.
- `src/test_all.zig`, `Justfile`, `README.md`, `src/cli/skill_content.md`.

---

### Task 1: Emoji table and character classification

**Files:**
- Create: `scripts/gen_emoji_table.py`
- Create: `src/engine/emoji_table.zig` (generated)
- Create: `src/engine/chars.zig`
- Modify: `src/config/rule.zig` (add `CharClass` and `ContentFormat` enums only)
- Modify: `src/test_all.zig`, `Justfile`

**Interfaces:**
- Produces (in `rule.zig`): `pub const CharClass = enum { emoji, status_markers, emdash };` and `pub const ContentFormat = enum { raw, markdown };`
- Produces (in `chars.zig`):
  - `pub const ClassSet = struct { emoji: bool = false, status_markers: bool = false, emdash: bool = false, pub fn fromNames(names: []const []const u8) ?ClassSet }`
  - `pub const Hit = struct { line: u32, start: usize, end: usize };`
  - `pub fn firstHit(text: []const u8, classes: ClassSet) ?Hit`

- [ ] **Step 1: Add the schema enums to `src/config/rule.zig`**

Below `AstMatch`:

```zig
/// Named character sets a `content_chars` matcher can forbid.
pub const CharClass = enum { emoji, status_markers, emdash };

/// How a tool's content is written. Code spans in markdown content are not
/// checked by `content_chars`.
pub const ContentFormat = enum { raw, markdown };
```

- [ ] **Step 2: Write the generator script `scripts/gen_emoji_table.py`**

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = []
# ///
# ABOUTME: Generates src/engine/emoji_table.zig from Unicode emoji-data.txt.
# ABOUTME: Run via `just gen-emoji-table`; the generated file is checked in.
import pathlib
import re
import urllib.request

VERSION = "18.0.0"
URL = f"https://www.unicode.org/Public/{VERSION}/ucd/emoji/emoji-data.txt"
OUT = pathlib.Path(__file__).resolve().parent.parent / "src/engine/emoji_table.zig"
LINE = re.compile(r"^([0-9A-F]{4,6})(?:\.\.([0-9A-F]{4,6}))?\s*;\s*(\w+)")


def ranges(text: str, prop: str) -> list[list[int]]:
    found = []
    for line in text.splitlines():
        m = LINE.match(line)
        if not m or m.group(3) != prop:
            continue
        lo = int(m.group(1), 16)
        hi = int(m.group(2) or m.group(1), 16)
        found.append([lo, hi])
    found.sort()
    merged: list[list[int]] = []
    for lo, hi in found:
        if merged and lo <= merged[-1][1] + 1:
            merged[-1][1] = max(merged[-1][1], hi)
        else:
            merged.append([lo, hi])
    return merged


def zig_array(name: str, rs: list[list[int]]) -> str:
    body = "\n".join(f"    .{{ 0x{lo:04X}, 0x{hi:04X} }}," for lo, hi in rs)
    return f"pub const {name} = [_]Range{{\n{body}\n}};\n"


def main() -> None:
    text = urllib.request.urlopen(URL).read().decode("utf-8")
    presentation = ranges(text, "Emoji_Presentation")
    emoji = ranges(text, "Emoji")
    OUT.write_text(
        "// ABOUTME: Unicode emoji property ranges, generated from emoji-data.txt.\n"
        "// ABOUTME: Regenerate with `just gen-emoji-table`; do not edit by hand.\n\n"
        f'pub const unicode_version = "{VERSION}";\n\n'
        "/// Inclusive code point range, sorted and non-overlapping within each table.\n"
        "pub const Range = [2]u21;\n\n"
        + zig_array("emoji_presentation", presentation)
        + "\n"
        + zig_array("emoji", emoji)
    )
    print(f"wrote {OUT}: {len(presentation)} Emoji_Presentation ranges, {len(emoji)} Emoji ranges")


if __name__ == "__main__":
    main()
```

- [ ] **Step 3: Add the Justfile recipe and generate the table**

Add to `Justfile` after the `fmt` recipe:

```just
# Regenerate the Unicode emoji table from emoji-data.txt
gen-emoji-table:
    ./scripts/gen_emoji_table.py
    zig fmt src/engine/emoji_table.zig
```

Run: `chmod +x scripts/gen_emoji_table.py && just gen-emoji-table`
Expected: `wrote .../src/engine/emoji_table.zig: 80 Emoji_Presentation ranges, 150 Emoji ranges` (counts for Unicode 18.0). If the pinned URL 404s, open `https://www.unicode.org/Public/` and use the directory for the latest released version; update `VERSION` to match.

- [ ] **Step 4: Write the failing classification tests in `src/engine/chars.zig`**

Create the file with the ABOUTME header, a stub, and the tests:

```zig
// ABOUTME: Character classes (emoji, status markers, em dashes) for content rules.
// ABOUTME: Scans UTF-8 text for class members, masks markdown code spans, formats hits.

const std = @import("std");
const rule_mod = @import("../config/rule.zig");
const table = @import("emoji_table.zig");

pub const ClassSet = struct {
    emoji: bool = false,
    status_markers: bool = false,
    emdash: bool = false,

    /// Build a set from class names. Returns null when a name is unknown or
    /// the list is empty.
    pub fn fromNames(names: []const []const u8) ?ClassSet {
        _ = names;
        return null;
    }
};

/// A byte range [start, end) of `text` holding one class member, and the
/// 1-based line it starts on.
pub const Hit = struct { line: u32, start: usize, end: usize };

pub fn firstHit(text: []const u8, classes: ClassSet) ?Hit {
    _ = text;
    _ = classes;
    return null;
}

// -- Tests --

const emoji_only = ClassSet{ .emoji = true };
const all_classes = ClassSet{ .emoji = true, .status_markers = true, .emdash = true };

test "firstHit emoji class" {
    // expected: null for no hit, else the hit's byte length.
    const cases = .{
        .{ "Done \u{2705}", @as(?usize, 3) },
        .{ "\u{26A0}\u{FE0F} careful", @as(?usize, 6) },
        .{ "\u{26A0} careful", @as(?usize, null) },
        .{ "\u{2705}\u{FE0E}", @as(?usize, null) },
        .{ "\u{2713} \u{2717} \u{2715}", @as(?usize, null) },
        .{ "Press \u{2318}K, a \u{2192} b, \u{2500}\u{25BC}", @as(?usize, null) },
        .{ "#1 and 1. step and \u{00A9} \u{2122}", @as(?usize, null) },
        .{ "1\u{FE0F}\u{20E3}", @as(?usize, 7) },
        .{ "\u{1F44D}\u{1F3FD}", @as(?usize, 8) },
        .{ "\u{1F468}\u{200D}\u{1F4BB}", @as(?usize, 11) },
        .{ "\u{1F1FA}\u{1F1F8}", @as(?usize, 8) },
        .{ "\u{1F4A1} idea", @as(?usize, 4) },
        .{ "plain ascii text", @as(?usize, null) },
    };
    inline for (cases) |c| {
        const hit = firstHit(c[0], emoji_only);
        if (c[1]) |len| {
            try std.testing.expect(hit != null);
            try std.testing.expectEqual(len, hit.?.end - hit.?.start);
        } else {
            try std.testing.expect(hit == null);
        }
    }
}

test "firstHit status markers and emdash" {
    const cases = .{
        .{ "\u{2713} done", ClassSet{ .status_markers = true }, true },
        .{ "\u{26A0} careful", ClassSet{ .status_markers = true }, true },
        .{ "\u{2715} close", ClassSet{ .status_markers = true }, false },
        .{ "\u{2605} star", ClassSet{ .status_markers = true }, true },
        .{ "foo \u{2014} bar", ClassSet{ .emdash = true }, true },
        .{ "pages 1\u{2013}5", ClassSet{ .emdash = true }, false },
        .{ "\u{2705}", ClassSet{ .status_markers = true, .emdash = true }, false },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[2], firstHit(c[0], c[1]) != null);
    }
}

test "firstHit reports an emoji-presented marker once, as emoji" {
    const hit = firstHit("\u{26A0}\u{FE0F}", all_classes).?;
    try std.testing.expectEqual(@as(usize, 6), hit.end - hit.start);
}

test "firstHit reports the line number" {
    const hit = firstHit("one\ntwo\nthree \u{2705}", emoji_only).?;
    try std.testing.expectEqual(@as(u32, 3), hit.line);
}

test "firstHit skips invalid UTF-8 without crashing" {
    const cases = .{
        .{ "\xff\xfe \u{2705}", true },
        .{ "\xe2\x9c", false },
        .{ "abc\xf0", false },
        .{ "\xc0\xaf", false },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[1], firstHit(c[0], emoji_only) != null);
    }
}

test "ClassSet.fromNames" {
    const all = ClassSet.fromNames(&.{ "emoji", "status_markers", "emdash" }).?;
    try std.testing.expect(all.emoji and all.status_markers and all.emdash);
    try std.testing.expect(ClassSet.fromNames(&.{"emojis"}) == null);
    try std.testing.expect(ClassSet.fromNames(&.{}) == null);
}
```

Register it in `src/test_all.zig` after `engine/path.zig`:

```zig
    _ = @import("engine/chars.zig");
```

- [ ] **Step 5: Run the tests to verify they fail**

Run: `just test`
Expected: FAIL in `firstHit emoji class` (null where a hit was expected) and `ClassSet.fromNames`.

- [ ] **Step 6: Implement classification**

Replace the stubs in `chars.zig`:

```zig
pub const ClassSet = struct {
    emoji: bool = false,
    status_markers: bool = false,
    emdash: bool = false,

    /// Build a set from class names. Returns null when a name is unknown or
    /// the list is empty.
    pub fn fromNames(names: []const []const u8) ?ClassSet {
        if (names.len == 0) return null;
        var set = ClassSet{};
        for (names) |name| {
            const class = std.meta.stringToEnum(rule_mod.CharClass, name) orelse return null;
            switch (class) {
                .emoji => set.emoji = true,
                .status_markers => set.status_markers = true,
                .emdash => set.emdash = true,
            }
        }
        return set;
    }
};

pub const Hit = struct { line: u32, start: usize, end: usize };

const status_markers = [_]u21{
    0x2713, 0x2714, 0x2717, 0x2718, 0x2610, 0x2611,
    0x2612, 0x26A0, 0x2733, 0x2734, 0x2605, 0x2606,
};

const Decoded = struct { cp: u21, len: usize };

/// Decode the code point at `i`. Invalid or truncated UTF-8 decodes as
/// U+FFFD with length 1, so scanning always advances.
fn decodeAt(text: []const u8, i: usize) Decoded {
    const invalid = Decoded{ .cp = 0xFFFD, .len = 1 };
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return invalid;
    if (i + len > text.len) return invalid;
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return invalid;
    return .{ .cp = cp, .len = len };
}

fn peek(text: []const u8, i: usize) ?Decoded {
    if (i >= text.len) return null;
    return decodeAt(text, i);
}

fn inRanges(ranges: []const table.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

fn isRegionalIndicator(cp: u21) bool {
    return cp >= 0x1F1E6 and cp <= 0x1F1FF;
}

/// Length in bytes of an emoji starting at `i`, or null when the code point
/// at `i` does not start one.
fn emojiLen(text: []const u8, i: usize, first: Decoded) ?usize {
    const next = peek(text, i + first.len);
    const next_cp: ?u21 = if (next) |n| n.cp else null;

    const is_keycap_base = (first.cp >= '0' and first.cp <= '9') or first.cp == '#' or first.cp == '*';
    if (is_keycap_base) {
        var j = i + first.len;
        if (next_cp == 0xFE0F) j += 3;
        const after = peek(text, j) orelse return null;
        if (after.cp == 0x20E3) return j + after.len - i;
        return null;
    }

    const presented = (inRanges(&table.emoji_presentation, first.cp) and next_cp != 0xFE0E) or
        (inRanges(&table.emoji, first.cp) and next_cp == 0xFE0F);
    if (!presented) return null;

    var j = i + first.len;
    if (isRegionalIndicator(first.cp)) {
        if (next) |n| {
            if (isRegionalIndicator(n.cp)) j += n.len;
        }
    }
    return extendSequence(text, j) - i;
}

/// Advance past code points that continue an emoji: variation selector 16,
/// skin tone modifiers, tag characters, the keycap mark, and ZWJ joins.
fn extendSequence(text: []const u8, start: usize) usize {
    var j = start;
    while (peek(text, j)) |d| {
        const continues = d.cp == 0xFE0F or d.cp == 0x20E3 or
            (d.cp >= 0x1F3FB and d.cp <= 0x1F3FF) or
            (d.cp >= 0xE0020 and d.cp <= 0xE007F);
        if (continues) {
            j += d.len;
        } else if (d.cp == 0x200D) {
            j += d.len;
            if (peek(text, j)) |joined| j += joined.len;
        } else {
            break;
        }
    }
    return j;
}

/// Length in bytes of a class member starting at `i`, or null.
fn memberLen(text: []const u8, i: usize, d: Decoded, classes: ClassSet) ?usize {
    if (classes.emoji) {
        if (emojiLen(text, i, d)) |len| return len;
    }
    if (classes.status_markers and std.mem.indexOfScalar(u21, &status_markers, d.cp) != null) return d.len;
    if (classes.emdash and d.cp == 0x2014) return d.len;
    return null;
}

/// Iterates the class members in `text`, in order.
pub const Scanner = struct {
    text: []const u8,
    classes: ClassSet,
    i: usize = 0,
    line: u32 = 1,

    pub fn next(self: *Scanner) ?Hit {
        while (self.i < self.text.len) {
            const d = decodeAt(self.text, self.i);
            if (d.cp == '\n') {
                self.line += 1;
                self.i += 1;
                continue;
            }
            if (memberLen(self.text, self.i, d, self.classes)) |len| {
                const hit = Hit{ .line = self.line, .start = self.i, .end = self.i + len };
                self.i += len;
                return hit;
            }
            self.i += d.len;
        }
        return null;
    }
};

pub fn firstHit(text: []const u8, classes: ClassSet) ?Hit {
    var scanner = Scanner{ .text = text, .classes = classes };
    return scanner.next();
}
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `just test`
Expected: PASS, including every existing test.

- [ ] **Step 8: Commit**

```bash
just check
git add scripts/gen_emoji_table.py src/engine/emoji_table.zig src/engine/chars.zig src/config/rule.zig src/test_all.zig Justfile
git commit -m "feat: add Unicode-backed character classes for emoji, status markers, and em dashes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: Markdown code spans and hit formatting

**Files:**
- Modify: `src/engine/chars.zig`

**Interfaces:**
- Consumes: `ClassSet`, `Scanner`, `Hit` from Task 1; `rule_mod.ContentFormat`.
- Produces:
  - `pub fn containsAny(allocator: std.mem.Allocator, text: []const u8, format: rule_mod.ContentFormat, classes: ClassSet) bool`
  - `pub fn writeHits(allocator: std.mem.Allocator, writer: anytype, text: []const u8, format: rule_mod.ContentFormat, names: []const []const u8, max: usize) !void`

- [ ] **Step 1: Write the failing tests**

Append to the tests in `chars.zig`. The table is the spec's code-span table:

```zig
test "containsAny markdown code spans (spec table)" {
    const cases = .{
        .{ "Done \u{2705}", true },
        .{ "Run `grep -E \"\u{2713}|\u{2717}\"`", false },
        .{ "```\necho \"\u{2713} ok\"\n```\n", false },
        .{ "~~~\n\u{2705}\n~~~\n", false },
        .{ "``a ` \u{2713}``", false },
        .{ "\u{26A0}\u{FE0F} careful", true },
        .{ "\u{26A0} careful", true },
        .{ "Press \u{2318}K, a \u{2192} b, #1, 1. step, \u{00A9}", false },
        .{ "pages 1\u{2013}5", false },
        .{ "foo \u{2014} bar", true },
        .{ "> \u{2713} check passed", true },
        .{ "```\nnever closed\n\u{2705}\n", false },
        .{ "it's `\u{2713} ok", true },
        .{ "- item\n    - nested \u{2705}", true },
        .{ "```\ncode\n```\nafter \u{2705}", true },
        .{ "`a`\n\n\u{2705} `b`", true },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[1], containsAny(std.testing.allocator, c[0], .markdown, all_classes));
    }
}

test "containsAny raw content checks code spans too" {
    try std.testing.expect(containsAny(std.testing.allocator, "echo `\u{2713}`", .raw, all_classes));
}

test "writeHits lists hits with line, code points, and glyph" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeHits(std.testing.allocator, &w, "ok\n\u{2705} and \u{26A0}\u{FE0F}", .raw, &.{"emoji"}, 5);
    try std.testing.expectEqualStrings(
        "  line 2: U+2705 (\u{2705})\n  line 2: U+26A0 U+FE0F (\u{26A0}\u{FE0F})\n",
        w.buffered(),
    );
}

test "writeHits caps the list and counts the rest" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeHits(std.testing.allocator, &w, "\u{2014}\u{2014}\u{2014}", .raw, &.{"emdash"}, 2);
    try std.testing.expectEqualStrings(
        "  line 1: U+2014 (\u{2014})\n  line 1: U+2014 (\u{2014})\n  and 1 more\n",
        w.buffered(),
    );
}

test "writeHits skips code spans in markdown" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try writeHits(std.testing.allocator, &w, "`\u{2705}` \u{2705}", .markdown, &.{"emoji"}, 5);
    try std.testing.expectEqualStrings("  line 1: U+2705 (\u{2705})\n", w.buffered());
}
```

Add stubs so the file compiles:

```zig
pub fn containsAny(allocator: std.mem.Allocator, text: []const u8, format: rule_mod.ContentFormat, classes: ClassSet) bool {
    _ = allocator;
    _ = text;
    _ = format;
    _ = classes;
    return false;
}

pub fn writeHits(allocator: std.mem.Allocator, writer: anytype, text: []const u8, format: rule_mod.ContentFormat, names: []const []const u8, max: usize) !void {
    _ = allocator;
    _ = writer;
    _ = text;
    _ = format;
    _ = names;
    _ = max;
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test`
Expected: FAIL in `containsAny markdown code spans (spec table)` on the cases expecting `true`, and in the three `writeHits` tests.

- [ ] **Step 3: Implement code-span masking, `containsAny`, and `writeHits`**

Replace the stubs:

```zig
/// Copy of `text` with fenced code blocks and inline code spans replaced by
/// spaces. Newlines are kept, so byte offsets and line numbers are unchanged.
/// A fence that never closes masks the rest of the text. A backtick run with
/// no matching closer before a blank line is literal text.
fn maskCodeSpans(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, text);
    maskFences(out);
    maskInlineCode(out);
    return out;
}

fn blank(bytes: []u8) void {
    for (bytes) |*b| {
        if (b.* != '\n') b.* = ' ';
    }
}

const Fence = struct { char: u8, len: usize };

/// A fence line: up to three spaces, then three or more backticks or tildes.
fn fenceAt(line: []const u8) ?Fence {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') i += 1;
    if (i >= line.len or (line[i] != '`' and line[i] != '~')) return null;
    const c = line[i];
    var n: usize = 0;
    while (i + n < line.len and line[i + n] == c) n += 1;
    if (n < 3) return null;
    return .{ .char = c, .len = n };
}

fn maskFences(out: []u8) void {
    var open: ?Fence = null;
    var start: usize = 0;
    while (start < out.len) {
        const end = std.mem.indexOfScalarPos(u8, out, start, '\n') orelse out.len;
        const line = out[start..end];
        const fence = fenceAt(line);
        if (open) |o| {
            if (fence) |f| {
                const rest = std.mem.trim(u8, line, " \t`~");
                if (f.char == o.char and f.len >= o.len and rest.len == 0) open = null;
            }
            blank(line);
        } else if (fence) |f| {
            open = f;
            blank(line);
        }
        start = end + 1;
    }
}

fn runLen(out: []const u8, i: usize) usize {
    var n: usize = 0;
    while (i + n < out.len and out[i + n] == '`') n += 1;
    return n;
}

fn maskInlineCode(out: []u8) void {
    var i: usize = 0;
    while (i < out.len) {
        if (out[i] != '`') {
            i += 1;
            continue;
        }
        const n = runLen(out, i);
        const limit = std.mem.indexOfPos(u8, out, i + n, "\n\n") orelse out.len;
        var j = i + n;
        const closer: ?usize = while (j < limit) {
            if (out[j] == '`') {
                const m = runLen(out, j);
                if (m == n) break j;
                j += m;
            } else {
                j += 1;
            }
        } else null;
        if (closer) |c| {
            blank(out[i .. c + n]);
            i = c + n;
        } else {
            i += n;
        }
    }
}

/// True when `text` holds a member of `classes`, ignoring code spans when
/// `format` is markdown. Allocation failure counts as no match.
pub fn containsAny(allocator: std.mem.Allocator, text: []const u8, format: rule_mod.ContentFormat, classes: ClassSet) bool {
    if (format == .raw) return firstHit(text, classes) != null;
    const masked = maskCodeSpans(allocator, text) catch return false;
    defer allocator.free(masked);
    return firstHit(masked, classes) != null;
}

/// Write up to `max` hits, one per line, as `  line N: U+XXXX (glyph)`,
/// followed by `  and N more` when hits were left out.
pub fn writeHits(allocator: std.mem.Allocator, writer: anytype, text: []const u8, format: rule_mod.ContentFormat, names: []const []const u8, max: usize) !void {
    const classes = ClassSet.fromNames(names) orelse return;
    const masked: ?[]u8 = if (format == .markdown) try maskCodeSpans(allocator, text) else null;
    defer if (masked) |m| allocator.free(m);

    var scanner = Scanner{ .text = masked orelse text, .classes = classes };
    var shown: usize = 0;
    var extra: usize = 0;
    while (scanner.next()) |hit| {
        if (shown == max) {
            extra += 1;
            continue;
        }
        const glyph = text[hit.start..hit.end];
        try writer.print("  line {d}:", .{hit.line});
        var k: usize = 0;
        while (k < glyph.len) {
            const d = decodeAt(glyph, k);
            try writer.print(" U+{X:0>4}", .{d.cp});
            k += d.len;
        }
        try writer.print(" ({s})\n", .{glyph});
        shown += 1;
    }
    if (extra > 0) try writer.print("  and {d} more\n", .{extra});
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just check
git add src/engine/chars.zig
git commit -m "feat: skip markdown code spans and format character-class hits

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: Rule schema and validation

**Files:**
- Modify: `src/config/rule.zig`
- Modify: `src/cli/validate_cmd.zig`
- Modify: `src/config/config.zig` (test only)

**Interfaces:**
- Consumes: `CharClass`, `ContentFormat` from Task 1.
- Produces (in `rule.zig`):
  - `pub const Event = enum { PreToolUse, Stop };`
  - `MatchConfig.content_chars: ?[]const []const u8 = null`
  - `Rule.event: Event = .PreToolUse`
  - `Rule.matchesTool` returns true for `tool = "*"`
  - `pub fn contentFormatFor(tool: []const u8) ContentFormat`
  - `ValidationError.StopRequiresReject`, `ValidationError.ToolOnNonToolEvent`, `ValidationError.UnknownCharClass`
  - `pub fn schemaIssue(rule: Rule) ?ValidationError` and `pub fn issueText(err: ValidationError) []const u8`

- [ ] **Step 1: Write the failing tests in `rule.zig`**

```zig
test "tool wildcard matches every tool" {
    const rule = Rule{ .id = "r", .tool = "*", .message = "m", .match = .{ .content_chars = &.{"emoji"} } };
    try std.testing.expect(rule.matchesTool("Write"));
    try std.testing.expect(rule.matchesTool("mcp__github__create_pull_request"));
}

test "content_chars counts as a content matcher" {
    try std.testing.expect(fieldsUsed(.{ .content_chars = &.{"emoji"} }).content);
}

test "tools that write text carry content" {
    const cases = .{
        .{ "Bash", true },          .{ "Write", true },
        .{ "Edit", true },          .{ "NotebookEdit", true },
        .{ "Agent", true },         .{ "SubagentHandback", true },
        .{ "AskUserQuestion", true }, .{ "ExitPlanMode", true },
        .{ "Read", false },         .{ "Grep", false },
        .{ "Glob", false },         .{ "WebFetch", false },
        .{ "WebSearch", false },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[1], toolFields(c[0]).?.content);
    }
}

test "contentFormatFor" {
    const cases = .{
        .{ "ExitPlanMode", ContentFormat.markdown },
        .{ "Agent", ContentFormat.markdown },
        .{ "SubagentHandback", ContentFormat.markdown },
        .{ "AskUserQuestion", ContentFormat.markdown },
        .{ "Write", ContentFormat.raw },
        .{ "Bash", ContentFormat.raw },
        .{ "mcp__x__y", ContentFormat.raw },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[1], contentFormatFor(c[0]));
    }
}

test "validation of event and content_chars" {
    const chars: []const []const u8 = &.{ "emoji", "status_markers", "emdash" };
    const cases = .{
        .{ Rule{ .id = "ok-stop", .event = .Stop, .message = "m", .match = .{ .content_chars = chars } }, @as(?ValidationError, null) },
        .{ Rule{ .id = "ok-star", .tool = "*", .message = "m", .match = .{ .content_chars = chars } }, @as(?ValidationError, null) },
        .{ Rule{ .id = "stop-rewrite", .event = .Stop, .rewrite_to = "x", .match = .{ .content_chars = chars } }, @as(?ValidationError, ValidationError.StopRequiresReject) },
        .{ Rule{ .id = "stop-allow", .event = .Stop, .action = .allow, .message = "m", .match = .{ .content_chars = chars } }, @as(?ValidationError, ValidationError.StopRequiresReject) },
        .{ Rule{ .id = "stop-tool", .event = .Stop, .tool = "Write", .message = "m", .match = .{ .content_chars = chars } }, @as(?ValidationError, ValidationError.ToolOnNonToolEvent) },
        .{ Rule{ .id = "stop-tool-any", .event = .Stop, .tool_any = &.{"Write"}, .message = "m", .match = .{ .content_chars = chars } }, @as(?ValidationError, ValidationError.ToolOnNonToolEvent) },
        .{ Rule{ .id = "stop-command", .event = .Stop, .message = "m", .match = .{ .command = "ls" } }, @as(?ValidationError, ValidationError.MatcherToolMismatch) },
        .{ Rule{ .id = "stop-path", .event = .Stop, .message = "m", .match = .{ .path = "src/**" } }, @as(?ValidationError, ValidationError.MatcherToolMismatch) },
        .{ Rule{ .id = "bad-class", .tool = "*", .message = "m", .match = .{ .content_chars = &.{"emojis"} } }, @as(?ValidationError, ValidationError.UnknownCharClass) },
        .{ Rule{ .id = "empty-class", .tool = "*", .message = "m", .match = .{ .content_chars = &.{} } }, @as(?ValidationError, ValidationError.UnknownCharClass) },
        .{ Rule{ .id = "star-rewrite", .tool = "*", .rewrite_to = "x", .match = .{ .content_chars = chars } }, @as(?ValidationError, ValidationError.RewriteRequiresCommand) },
        .{ Rule{ .id = "grep-content", .tool = "Grep", .message = "m", .match = .{ .content_chars = chars } }, @as(?ValidationError, ValidationError.MatcherToolMismatch) },
    };
    inline for (cases) |c| {
        const rules = [_]Rule{c[0]};
        if (c[1]) |expected| {
            try std.testing.expectError(expected, validate(&rules));
        } else {
            try validate(&rules);
        }
    }
}
```

In `src/config/config.zig`, next to the other `loadString` tests:

```zig
test "loadString parses event, tool wildcard, and content_chars" {
    var result = try loadString(std.testing.allocator,
        \\[[rule]]
        \\id = "no-emoji-in-replies"
        \\event = "Stop"
        \\message = "m"
        \\[rule.match]
        \\content_chars = ["emoji", "emdash"]
        \\
        \\[[rule]]
        \\id = "no-emoji-in-tool-input"
        \\tool = "*"
        \\message = "m"
        \\[rule.match]
        \\content_chars = ["status_markers"]
    );
    defer result.deinit();
    const rules = result.value.rule;
    try std.testing.expectEqual(rule_mod.Event.Stop, rules[0].event);
    try std.testing.expectEqual(@as(usize, 2), rules[0].match.content_chars.?.len);
    try std.testing.expectEqual(rule_mod.Event.PreToolUse, rules[1].event);
    try std.testing.expectEqualStrings("*", rules[1].tool);
}
```

(Use whatever name `config.zig` already imports `rule.zig` under; it re-exports `Rule` and `Action` at the top of the file. Add `pub const Event = rule_mod.Event;` there if the test needs it.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test`
Expected: compile errors for the missing `Event`, `event`, `content_chars`, `contentFormatFor`, and new error names.

- [ ] **Step 3: Implement the schema**

In `rule.zig`:

```zig
/// The Claude Code hook event a rule applies to.
pub const Event = enum { PreToolUse, Stop };
```

In `MatchConfig`, after `content_contains`:

```zig
    // Character-class matching: the rule matches when the content holds any
    // character from a listed class. Names are `CharClass` fields.
    content_chars: ?[]const []const u8 = null,
```

In `Rule`, after `enabled`:

```zig
    event: Event = .PreToolUse,
```

Change the `tool` doc and `matchesTool`:

```zig
    /// True when this rule applies to `tool_name`. Uses `tool_any` when set,
    /// otherwise the single `tool` field, where `*` matches every tool.
    pub fn matchesTool(self: Rule, tool_name: []const u8) bool {
        if (self.tool_any) |tools| {
            for (tools) |t| {
                if (std.mem.eql(u8, t, tool_name)) return true;
            }
            return false;
        }
        if (std.mem.eql(u8, self.tool, "*")) return true;
        return std.mem.eql(u8, self.tool, tool_name);
    }
```

`fieldsUsed`:

```zig
        .content = m.content_regex != null or m.content_contains != null or m.content_chars != null,
```

`toolFields`:

```zig
pub fn toolFields(tool: []const u8) ?FieldSet {
    if (std.mem.eql(u8, tool, "Bash")) return .{ .command = true, .content = true };

    const content_tools = [_][]const u8{ "ExitPlanMode", "Agent", "SubagentHandback", "AskUserQuestion" };
    for (content_tools) |t| {
        if (std.mem.eql(u8, tool, t)) return .{ .content = true };
    }
    const writing_tools = [_][]const u8{ "Write", "Edit", "NotebookEdit" };
    for (writing_tools) |t| {
        if (std.mem.eql(u8, tool, t)) return .{ .path = true, .content = true };
    }
    const reading_tools = [_][]const u8{ "Read", "Grep", "Glob" };
    for (reading_tools) |t| {
        if (std.mem.eql(u8, tool, t)) return .{ .path = true };
    }
    const web_tools = [_][]const u8{ "WebFetch", "WebSearch" };
    for (web_tools) |t| {
        if (std.mem.eql(u8, tool, t)) return .{};
    }
    return null;
}

/// How a tool's content is written. Tools whose text is addressed to a
/// reader are markdown; file content, commands, and unknown tools are raw.
pub fn contentFormatFor(tool: []const u8) ContentFormat {
    const markdown_tools = [_][]const u8{ "ExitPlanMode", "Agent", "SubagentHandback", "AskUserQuestion" };
    for (markdown_tools) |t| {
        if (std.mem.eql(u8, tool, t)) return .markdown;
    }
    return .raw;
}
```

Add the errors to `ValidationError`:

```zig
    StopRequiresReject,
    ToolOnNonToolEvent,
    UnknownCharClass,
```

Add, above `validate`:

```zig
/// Checks for the `event` field and `content_chars`, shared by `validate`
/// and `veer validate`. Returns the first issue found.
pub fn schemaIssue(rule: Rule) ?ValidationError {
    if (rule.match.content_chars) |names| {
        if (names.len == 0) return ValidationError.UnknownCharClass;
        for (names) |name| {
            if (std.meta.stringToEnum(CharClass, name) == null) return ValidationError.UnknownCharClass;
        }
    }
    const action = rule.effectiveAction();
    if (std.mem.eql(u8, rule.tool, "*") and action == .rewrite) return ValidationError.RewriteRequiresCommand;
    if (rule.event == .Stop) {
        if (action != .reject) return ValidationError.StopRequiresReject;
        if (rule.tool_any != null or !std.mem.eql(u8, rule.tool, "Bash")) return ValidationError.ToolOnNonToolEvent;
        const used = fieldsUsed(rule.match);
        if (used.command or used.path) return ValidationError.MatcherToolMismatch;
    }
    return null;
}

/// User-facing text for the issues `schemaIssue` reports.
pub fn issueText(err: ValidationError) []const u8 {
    return switch (err) {
        ValidationError.StopRequiresReject => "Stop rules must use action = \"reject\"",
        ValidationError.ToolOnNonToolEvent => "Stop rules do not take tool or tool_any",
        ValidationError.UnknownCharClass => "content_chars must list one or more of: emoji, status_markers, emdash",
        ValidationError.RewriteRequiresCommand => "rewrite requires a tool with a command field",
        ValidationError.MatcherToolMismatch => "Stop rules only accept content matchers",
        else => @errorName(err),
    };
}
```

In `validate`, after the `ToolAndToolAny` check and before the action checks:

```zig
        if (schemaIssue(rule)) |err| return err;
```

The existing tool-compatibility block stays as is: a Stop rule has `tool = "Bash"` by default, and Bash now carries content, so a content-only Stop rule passes it.

Add `m.content_chars != null or` to `hasAnyMatch`.

- [ ] **Step 4: Report the new issues from `veer validate`**

In `src/cli/validate_cmd.zig`, in the per-rule message loop, after the `ToolAndToolAny` block:

```zig
        if (rule_mod.schemaIssue(rule)) |err| {
            if (issues_len < issues_buf.len) {
                issues_buf[issues_len] = rule_mod.issueText(err);
                issues_len += 1;
            }
        }
```

In `validateAll`, after the `tool_any` line:

```zig
        if (rule_mod.schemaIssue(rule) != null) count += 1;
```

Add a test mirroring the existing "validate valid config reports OK" test, writing this config and asserting exit 1 and that the output contains `content_chars must list`:

```toml
[[rule]]
id = "bad"
tool = "*"
message = "m"
[rule.match]
content_chars = ["emojis"]
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `just test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
just check
git add src/config/rule.zig src/config/config.zig src/cli/validate_cmd.zig
git commit -m "feat: add event, tool wildcard, and content_chars to the rule schema

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Engine evaluation

**Files:**
- Modify: `src/engine/matcher.zig`
- Modify: `src/engine/engine.zig`

**Interfaces:**
- Consumes: `chars.containsAny`, `chars.ClassSet.fromNames` (Tasks 1-2); `Event`, `ContentFormat` (Task 3).
- Produces:
  - `matcher.matchContent(allocator, rule, content: ?[]const u8, format: ContentFormat) bool`
  - `ToolCall.event: Event = .PreToolUse`, `ToolCall.content_format: ContentFormat = .raw`
  - `CheckResult.content_chars: ?[]const []const u8 = null` (the matched rule's classes, for hit formatting)

- [ ] **Step 1: Write the failing tests in `engine.zig`**

```zig
test "event filtering: Stop rules and PreToolUse rules do not cross" {
    const chars: []const []const u8 = &.{"emoji"};
    const rules = [_]Rule{
        .{ .id = "stop", .event = .Stop, .message = "m", .match = .{ .content_chars = chars } },
        .{ .id = "tool", .tool = "*", .message = "m", .match = .{ .content_contains = "nope" } },
    };
    const on_tool = check(std.testing.allocator, &rules, .{ .tool_name = "Write", .content = "\u{2705}" });
    try std.testing.expect(on_tool.action == null);

    const tool_rules = [_]Rule{
        .{ .id = "tool", .tool = "*", .message = "m", .match = .{ .content_chars = chars } },
    };
    const on_stop = check(std.testing.allocator, &tool_rules, .{ .tool_name = "", .event = .Stop, .content = "\u{2705}", .content_format = .markdown });
    try std.testing.expect(on_stop.action == null);
}

test "Stop rule rejects a reply with emoji outside code spans" {
    const chars: []const []const u8 = &.{ "emoji", "status_markers" };
    const rules = [_]Rule{
        .{ .id = "no-emoji-in-replies", .event = .Stop, .message = "m", .match = .{ .content_chars = chars } },
    };
    const cases = .{
        .{ "Done \u{2705}", true },
        .{ "Run `grep \u{2713}`", false },
    };
    inline for (cases) |c| {
        const result = check(std.testing.allocator, &rules, .{ .tool_name = "", .event = .Stop, .content = c[0], .content_format = .markdown });
        try std.testing.expectEqual(c[1], result.action != null);
        if (c[1]) try std.testing.expectEqual(@as(usize, 2), result.content_chars.?.len);
    }
}

test "tool wildcard content_chars rule checks raw content in full" {
    const rules = [_]Rule{
        .{ .id = "no-emoji", .tool = "*", .message = "m", .match = .{ .content_chars = &.{"emoji"} } },
    };
    const hit = check(std.testing.allocator, &rules, .{ .tool_name = "Write", .content = "echo `\u{2705}`" });
    try std.testing.expectEqual(Action.reject, hit.action.?);
    const clean = check(std.testing.allocator, &rules, .{ .tool_name = "Write", .content = "plain" });
    try std.testing.expect(clean.action == null);
    const no_content = check(std.testing.allocator, &rules, .{ .tool_name = "Grep" });
    try std.testing.expect(no_content.action == null);
}

test "Bash rules without an event still apply to PreToolUse calls" {
    const rules = [_]Rule{.{ .id = "no-python3", .message = "m", .match = .{ .command = "python3" } }};
    const result = check(std.testing.allocator, &rules, .{ .tool_name = "Bash", .command = "python3 x.py", .content = "python3 x.py" });
    try std.testing.expectEqual(Action.reject, result.action.?);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test`
Expected: compile errors for `event`, `content_format`, and `content_chars` on `ToolCall` / `CheckResult`.

- [ ] **Step 3: Implement**

In `matcher.zig`, import `chars` and `ContentFormat`, and extend `matchContent`:

```zig
const chars = @import("chars.zig");
const ContentFormat = @import("../config/rule.zig").ContentFormat;
```

```zig
/// Match a rule's content matchers (content_regex, content_contains,
/// content_chars) against a string. Returns true when all configured content
/// matchers match, and true when the rule has no content matchers at all.
/// `format` decides whether content_chars skips markdown code spans.
///
/// The engine skips any rule whose content matchers have no content to read,
/// so `content` is non-null whenever this has matchers to apply. The null
/// branch is kept as a fail-open guard for direct callers.
///
/// Takes an allocator because content (e.g., a plan file) can be larger than
/// the fixed stack buffer used by the command-line `regexMatch`.
pub fn matchContent(allocator: std.mem.Allocator, rule: Rule, content: ?[]const u8, format: ContentFormat) bool {
    const m = rule.match;
    const has_matchers = m.content_regex != null or m.content_contains != null or m.content_chars != null;
    if (!has_matchers) return true;

    const text = content orelse return false;

    if (m.content_regex) |pattern| {
        if (!regexMatchAlloc(allocator, pattern, text)) return false;
    }
    if (m.content_contains) |needle| {
        if (std.mem.indexOf(u8, text, needle) == null) return false;
    }
    if (m.content_chars) |names| {
        const classes = chars.ClassSet.fromNames(names) orelse return false;
        if (!chars.containsAny(allocator, text, format, classes)) return false;
    }
    return true;
}
```

Add `, .raw` as the last argument to every existing `matchContent(` call in `matcher.zig`'s tests.

In `engine.zig`:

```zig
const Event = @import("../config/rule.zig").Event;
const ContentFormat = @import("../config/rule.zig").ContentFormat;
```

`CheckResult` gets:

```zig
    /// The matched rule's `content_chars`, so callers can list the hits.
    content_chars: ?[]const []const u8 = null,
```

`ToolCall` gets (update its doc comment: `content` is tool-specific text, or the finished reply for a Stop event; `tool_name` is empty for a Stop event):

```zig
    event: Event = .PreToolUse,
    content_format: ContentFormat = .raw,
```

In `check`, replace the tool filter:

```zig
        if (rule.event != call.event) continue;
        if (call.event == .PreToolUse and !rule.matchesTool(call.tool_name)) continue;
```

Pass the format:

```zig
            matched = matcher.matchContent(allocator, rule, call.content, call.content_format);
```

And set `.content_chars = rule.match.content_chars` in both returned `CheckResult` literals (the gate reject and the match).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
just check
git add src/engine/matcher.zig src/engine/engine.zig
git commit -m "feat: evaluate content_chars and filter rules by hook event

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: Hook input for Stop and per-tool content

**Files:**
- Modify: `src/claude/hook.zig`

**Interfaces:**
- Consumes: `Event`, `ContentFormat`, `contentFormatFor` from Task 3.
- Produces:
  - `HookInput.event: Event`, `HookInput.stop_hook_active: bool`, `HookInput.content_format: ContentFormat`
  - `parseInput` returns `error.UnsupportedEvent` for any `hook_event_name` other than `PreToolUse` or `Stop`.
  - `pub fn formatStopFeedback(writer: anytype, rule_id: []const u8, feedback: []const u8) !void`

- [ ] **Step 1: Write the failing tests**

```zig
test "parseInput reads a Stop event" {
    const json =
        \\{"hook_event_name":"Stop","session_id":"s","stop_hook_active":false,"last_assistant_message":"Done \u2705"}
    ;
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);
    try std.testing.expectEqual(rule_mod.Event.Stop, input.event);
    try std.testing.expectEqual(rule_mod.ContentFormat.markdown, input.content_format);
    try std.testing.expectEqualStrings("Done \u{2705}", input.content.?);
    try std.testing.expect(!input.stop_hook_active);
}

test "parseInput reads stop_hook_active" {
    const json =
        \\{"hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"x"}
    ;
    var input = try parseInput(std.testing.allocator, std.testing.io, json);
    defer freeInput(std.testing.allocator, &input);
    try std.testing.expect(input.stop_hook_active);
}

test "parseInput rejects unsupported events" {
    const cases = .{
        \\{"hook_event_name":"MessageDisplay","delta":"x"}
        ,
        \\{"hook_event_name":"SubagentStop","last_assistant_message":"x"}
        ,
    };
    inline for (cases) |json| {
        try std.testing.expectError(error.UnsupportedEvent, parseInput(std.testing.allocator, std.testing.io, json));
    }
}

test "parseInput extracts content per tool" {
    const cases = .{
        .{ \\{"tool_name":"Write","tool_input":{"file_path":"/a/b.md","content":"body"}}
        , @as(?[]const u8, "body"), rule_mod.ContentFormat.raw },
        .{ \\{"tool_name":"Edit","tool_input":{"file_path":"/a","old_string":"old","new_string":"new"}}
        , @as(?[]const u8, "new"), rule_mod.ContentFormat.raw },
        .{ \\{"tool_name":"NotebookEdit","tool_input":{"notebook_path":"/a.ipynb","new_source":"src"}}
        , @as(?[]const u8, "src"), rule_mod.ContentFormat.raw },
        .{ \\{"tool_name":"Bash","tool_input":{"command":"ls -la"}}
        , @as(?[]const u8, "ls -la"), rule_mod.ContentFormat.raw },
        .{ \\{"tool_name":"Agent","tool_input":{"description":"d","prompt":"do it"}}
        , @as(?[]const u8, "do it"), rule_mod.ContentFormat.markdown },
        .{ \\{"tool_name":"SubagentHandback","tool_input":{"message":"report"}}
        , @as(?[]const u8, "report"), rule_mod.ContentFormat.markdown },
        .{ \\{"tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Q?","options":[{"label":"A","description":"a"}]}]}}
        , @as(?[]const u8, "Q?\nA\na"), rule_mod.ContentFormat.markdown },
        .{ \\{"tool_name":"mcp__gh__create_pr","tool_input":{"title":"T","body":"B","path":"/x","draft":true}}
        , @as(?[]const u8, "T\nB"), rule_mod.ContentFormat.raw },
        .{ \\{"tool_name":"Grep","tool_input":{"pattern":"\u2705","path":"src"}}
        , @as(?[]const u8, null), rule_mod.ContentFormat.raw },
        .{ \\{"tool_name":"Read","tool_input":{"file_path":"/a"}}
        , @as(?[]const u8, null), rule_mod.ContentFormat.raw },
        .{ \\{"tool_name":"WebSearch","tool_input":{"query":"q"}}
        , @as(?[]const u8, null), rule_mod.ContentFormat.raw },
    };
    inline for (cases) |c| {
        var input = try parseInput(std.testing.allocator, std.testing.io, c[0]);
        defer freeInput(std.testing.allocator, &input);
        try std.testing.expectEqual(rule_mod.Event.PreToolUse, input.event);
        try std.testing.expectEqual(c[2], input.content_format);
        if (c[1]) |expected| {
            try std.testing.expectEqualStrings(expected, input.content.?);
        } else {
            try std.testing.expect(input.content == null);
        }
    }
}

test "formatStopFeedback emits additionalContext and a reject marker" {
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try formatStopFeedback(&w, "no-emoji", "line one\nline two");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, w.buffered(), .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("[no-emoji] reject", parsed.value.object.get("systemMessage").?.string);
    const hso = parsed.value.object.get("hookSpecificOutput").?.object;
    try std.testing.expectEqualStrings("Stop", hso.get("hookEventName").?.string);
    try std.testing.expectEqualStrings("line one\nline two", hso.get("additionalContext").?.string);
}
```

The AskUserQuestion expected value assumes `std.json.ObjectMap` iterates in insertion order. It does (it is an `ArrayHashMap`); if that assumption fails, compare the lines as a set instead of changing the implementation.

Also update the existing test at `hook.zig:302` ("Bash tool: content is not extracted regardless of transcript_path"): Bash content is now its command, so change its assertion to `expectEqualStrings(<the command>, input.content.?)` and rename it to "Bash tool content is its command".

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test`
Expected: compile errors for `event`, `content_format`, `stop_hook_active`, `formatStopFeedback`.

- [ ] **Step 3: Implement**

At the top of `hook.zig`, update the ABOUTME first line to "Claude Code hook protocol implementation (PreToolUse and Stop)." and add:

```zig
const rule_mod = @import("../config/rule.zig");
```

`HookInput` gets (and its `content` doc becomes: "Text the content matchers read: the tool's written text (see `extractToolContent`), the resolved plan body for ExitPlanMode, or the finished reply for a Stop event. Null when the tool carries none or extraction failed; callers treat null as no match."):

```zig
    event: rule_mod.Event,
    /// Stop only: true when Claude is already continuing because of a Stop hook.
    stop_hook_active: bool,
    content_format: rule_mod.ContentFormat,
```

At the start of `parseInput`, after `root` is checked, add:

```zig
    const event: rule_mod.Event = blk: {
        const val = root.object.get("hook_event_name") orelse break :blk .PreToolUse;
        if (val != .string) return error.InvalidInput;
        break :blk std.meta.stringToEnum(rule_mod.Event, val.string) orelse return error.UnsupportedEvent;
    };

    if (event == .Stop) return parseStopInput(allocator, root);
```

and add:

```zig
fn parseStopInput(allocator: std.mem.Allocator, root: std.json.Value) !HookInput {
    const tool_name = try allocator.dupe(u8, "");
    errdefer allocator.free(tool_name);

    const content: ?[]const u8 = blk: {
        const val = root.object.get("last_assistant_message") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk try allocator.dupe(u8, val.string);
    };
    errdefer if (content) |c| allocator.free(c);

    const session_id: ?[]const u8 = blk: {
        const val = root.object.get("session_id") orelse break :blk null;
        if (val != .string) break :blk null;
        break :blk try allocator.dupe(u8, val.string);
    };

    const active = if (root.object.get("stop_hook_active")) |v| v == .bool and v.bool else false;

    return .{
        .tool_name = tool_name,
        .command = null,
        .session_id = session_id,
        .transcript_path = null,
        .content = content,
        .file_path = null,
        .cwd = null,
        .event = .Stop,
        .stop_hook_active = active,
        .content_format = .markdown,
    };
}
```

Replace the content block in `parseInput` with:

```zig
    // Tool-specific content extraction. Fail-open: any error producing
    // content yields null, which the engine treats as "rule does not match"
    // for content rules. A transient FS or parse glitch must not block the
    // agent from making progress.
    const content: ?[]const u8 = if (std.mem.eql(u8, tool_name, "ExitPlanMode")) blk: {
        const tp = transcript_path orelse break :blk null;
        break :blk resolveExitPlanModeContent(allocator, io, tp) catch null;
    } else blk: {
        const tool_input = root.object.get("tool_input") orelse break :blk null;
        break :blk extractToolContent(allocator, tool_name, tool_input) catch null;
    };
```

and add `.event = .PreToolUse, .stop_hook_active = false, .content_format = rule_mod.contentFormatFor(tool_name),` to its return literal. Add:

```zig
/// The text a tool call writes, for content matchers. Known tools use one
/// field; read-only tools carry none, so searching for a character is never
/// rejected; any other tool (AskUserQuestion, MCP tools) contributes every
/// string in its input except paths, joined by newlines.
fn extractToolContent(allocator: std.mem.Allocator, tool_name: []const u8, tool_input: std.json.Value) !?[]u8 {
    if (tool_input != .object) return null;

    const Single = struct { tool: []const u8, field: []const u8 };
    const single_field = [_]Single{
        .{ .tool = "Bash", .field = "command" },
        .{ .tool = "Write", .field = "content" },
        .{ .tool = "Edit", .field = "new_string" },
        .{ .tool = "NotebookEdit", .field = "new_source" },
        .{ .tool = "Agent", .field = "prompt" },
        .{ .tool = "SubagentHandback", .field = "message" },
    };
    for (single_field) |s| {
        if (!std.mem.eql(u8, tool_name, s.tool)) continue;
        const val = tool_input.object.get(s.field) orelse return null;
        if (val != .string) return null;
        return try allocator.dupe(u8, val.string);
    }

    const read_only = [_][]const u8{ "Read", "Grep", "Glob", "WebFetch", "WebSearch" };
    for (read_only) |t| {
        if (std.mem.eql(u8, tool_name, t)) return null;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    try appendStrings(allocator, &buf, tool_input);
    if (buf.items.len == 0) {
        buf.deinit(allocator);
        return null;
    }
    return try buf.toOwnedSlice(allocator);
}

fn appendStrings(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), value: std.json.Value) !void {
    switch (value) {
        .string => |s| {
            if (buf.items.len > 0) try buf.append(allocator, '\n');
            try buf.appendSlice(allocator, s);
        },
        .array => |a| for (a.items) |item| try appendStrings(allocator, buf, item),
        .object => |o| {
            var it = o.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const is_path = std.mem.eql(u8, key, "file_path") or
                    std.mem.eql(u8, key, "notebook_path") or
                    std.mem.eql(u8, key, "path");
                if (is_path) continue;
                try appendStrings(allocator, buf, entry.value_ptr.*);
            }
        },
        else => {},
    }
}
```

Add the formatter next to `formatRejectMarker`:

```zig
/// Format a Stop rejection for stdout. Claude continues the turn with
/// `feedback` labeled as Stop hook feedback, not as an error. The
/// systemMessage keeps rejects discoverable with the same `[<rule_id>] `
/// prefix grammar as PreToolUse rejects.
pub fn formatStopFeedback(writer: anytype, rule_id: []const u8, feedback: []const u8) !void {
    try writer.writeAll("{\"systemMessage\":\"[");
    try writeJsonEscaped(writer, rule_id);
    try writer.writeAll("] reject\",\"hookSpecificOutput\":{\"hookEventName\":\"Stop\",\"additionalContext\":");
    try writeJsonString(writer, feedback);
    try writer.writeAll("}}");
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test`
Expected: PASS. Fix any other `HookInput{...}` literals the compiler flags by adding the three new fields.

- [ ] **Step 5: Commit**

```bash
just check
git add src/claude/hook.zig
git commit -m "feat: parse Stop hook input and extract content for tools that write text

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `veer check` for Stop and hit lines

**Files:**
- Modify: `src/cli/check.zig`
- Modify: `src/main.zig` (`runCheck` buffers)
- Modify: `Justfile` (smoke test)

**Interfaces:**
- Consumes: `hook.parseInput`, `hook.formatStopFeedback` (Task 5); `engine.check` with `event` / `content_format` and `CheckResult.content_chars` (Task 4); `chars.writeHits` (Task 2).
- Produces: no new public API.

- [ ] **Step 1: Write the failing tests in `check.zig`**

Add a helper at the top of the test section to cut the repeated buffer setup in the new tests:

```zig
const RunOutput = struct {
    code: u8,
    stdout_buf: [2048]u8 = undefined,
    stderr_buf: [2048]u8 = undefined,
    stdout_len: usize = 0,
    stderr_len: usize = 0,

    fn stdout(self: *const RunOutput) []const u8 {
        return self.stdout_buf[0..self.stdout_len];
    }
    fn stderr(self: *const RunOutput) []const u8 {
        return self.stderr_buf[0..self.stderr_len];
    }
};

fn runForTest(rules: []const Rule, input: []const u8) !RunOutput {
    var out = RunOutput{ .code = 0 };
    var stdout_stream = std.Io.Writer.fixed(&out.stdout_buf);
    var stderr_stream = std.Io.Writer.fixed(&out.stderr_buf);
    out.code = try run(std.testing.allocator, std.testing.io, rules, null, null, input, &stdout_stream, &stderr_stream, false);
    out.stdout_len = stdout_stream.buffered().len;
    out.stderr_len = stderr_stream.buffered().len;
    return out;
}

const emoji_classes: []const []const u8 = &.{ "emoji", "status_markers" };

test "Stop reject returns additionalContext with hits and exit 0" {
    const rules = [_]Rule{.{
        .id = "no-emoji-in-replies",
        .event = .Stop,
        .message = "Restate without emoji.",
        .match = .{ .content_chars = emoji_classes },
    }};
    const out = try runForTest(&rules,
        \\{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"ok\n\u2705 done"}
    );
    try std.testing.expectEqual(@as(u8, 0), out.code);
    try std.testing.expectEqual(@as(usize, 0), out.stderr().len);
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, out.stdout(), .{});
    defer parsed.deinit();
    const ctx = parsed.value.object.get("hookSpecificOutput").?.object.get("additionalContext").?.string;
    try std.testing.expect(std.mem.startsWith(u8, ctx, "[no-emoji-in-replies] Restate without emoji.\n"));
    try std.testing.expect(std.mem.indexOf(u8, ctx, "line 2: U+2705") != null);
}

test "Stop with stop_hook_active allows without evaluating" {
    const rules = [_]Rule{.{ .id = "r", .event = .Stop, .message = "m", .match = .{ .content_chars = emoji_classes } }};
    const out = try runForTest(&rules,
        \\{"hook_event_name":"Stop","stop_hook_active":true,"last_assistant_message":"\u2705"}
    );
    try std.testing.expectEqual(@as(u8, 0), out.code);
    try std.testing.expectEqual(@as(usize, 0), out.stdout().len);
}

test "Stop with no Stop rules and unsupported events allow silently" {
    const rules = [_]Rule{.{ .id = "r", .tool = "*", .message = "m", .match = .{ .content_chars = emoji_classes } }};
    const inputs = .{
        \\{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"\u2705"}
        ,
        \\{"hook_event_name":"MessageDisplay","delta":"\u2705","index":0,"final":true}
        ,
    };
    inline for (inputs) |input| {
        const out = try runForTest(&rules, input);
        try std.testing.expectEqual(@as(u8, 0), out.code);
        try std.testing.expectEqual(@as(usize, 0), out.stdout().len);
        try std.testing.expectEqual(@as(usize, 0), out.stderr().len);
    }
}

test "PreToolUse content_chars reject lists hits on stderr" {
    const rules = [_]Rule{.{ .id = "no-emoji", .tool = "*", .message = "No emoji.", .match = .{ .content_chars = emoji_classes } }};
    const out = try runForTest(&rules,
        \\{"tool_name":"Write","tool_input":{"file_path":"/tmp/x.md","content":"a\n\u2713 b"}}
    );
    try std.testing.expectEqual(@as(u8, 2), out.code);
    try std.testing.expect(std.mem.startsWith(u8, out.stderr(), "[no-emoji] No emoji.\n"));
    try std.testing.expect(std.mem.indexOf(u8, out.stderr(), "line 2: U+2713") != null);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test`
Expected: FAIL. The Stop tests get exit 2 with stderr output (or exit 1 for `MessageDisplay`), and the PreToolUse test has no hit lines.

- [ ] **Step 3: Implement in `check.zig`**

Add `const chars = @import("../engine/chars.zig");` and update the ABOUTME second line to "Reads hook JSON from stdin (PreToolUse or Stop), evaluates rules, outputs the result."

Replace the parse block:

```zig
    var input = hook.parseInput(allocator, io, stdin_data) catch |err| switch (err) {
        error.UnsupportedEvent => return hook.ExitCode.allow,
        else => {
            try stderr_writer.print("veer: invalid JSON input\n", .{});
            return 1;
        },
    };
    defer hook.freeInput(allocator, &input);

    // A Stop hook fires again after Claude answers its feedback. Correct a
    // reply once; a second miss in a row allows, so a misfiring rule cannot
    // loop.
    if (input.event == .Stop and input.stop_hook_active) return hook.ExitCode.allow;
```

Pass `.event = input.event, .content_format = input.content_format,` to `engine.check`.

Replace the `.reject, .allow` arm:

```zig
            .reject, .allow => {
                const rid = result.rule_id orelse "";
                const msg = result.message orelse "";
                if (input.event == .Stop) {
                    var feedback: std.Io.Writer.Allocating = .init(allocator);
                    defer feedback.deinit();
                    try feedback.writer.print("[{s}] {s}\n", .{ rid, msg });
                    try writeHitsFor(allocator, &feedback.writer, result, input);
                    try hook.formatStopFeedback(stdout_writer, rid, feedback.written());
                    return hook.ExitCode.allow;
                }
                if (result.message != null) {
                    if (result.rule_id != null) {
                        try stderr_writer.print("[{s}] {s}\n", .{ rid, msg });
                    } else {
                        try stderr_writer.print("{s}\n", .{msg});
                    }
                }
                try writeHitsFor(allocator, stderr_writer, result, input);
                // Emit a stdout marker so the transcript's hook_success
                // record carries rule_id attribution. Claude Code captures
                // stdout on exit 2 even though it doesn't act on it.
                if (result.rule_id) |r| {
                    try hook.formatRejectMarker(stdout_writer, r);
                }
                return hook.ExitCode.reject;
            },
```

Add below `run`:

```zig
const max_listed_hits = 5;

/// List the character-class hits behind a reject, when the matched rule
/// has content_chars.
fn writeHitsFor(allocator: std.mem.Allocator, writer: anytype, result: engine.CheckResult, input: hook.HookInput) !void {
    const names = result.content_chars orelse return;
    const content = input.content orelse return;
    try chars.writeHits(allocator, writer, content, input.content_format, names, max_listed_hits);
}
```

In `src/main.zig` `runCheck`, raise both fixed buffers from `[4096]u8` to `[16384]u8` so a Stop feedback payload with a long rule message fits.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test`
Expected: PASS, including every existing `check.zig` test.

- [ ] **Step 5: Add a smoke test recipe**

Add to `Justfile` after `check-gate`, and add `check-chars` to the `check:` recipe's dependency list:

```just
# Smoke test: content_chars rejects emoji in a Write and in a Stop reply,
# and a Stop reply with emoji only inside a code span passes.
check-chars:
    #!/usr/bin/env bash
    set -euo pipefail
    zig build
    bin="$(pwd)/zig-out/bin/veer"
    cfg=$(mktemp)
    trap 'rm -f "$cfg"' EXIT
    cat > "$cfg" <<'TOML'
    [[rule]]
    id = "no-emoji-in-tool-input"
    tool = "*"
    message = "No emoji."
    [rule.match]
    content_chars = ["emoji", "status_markers", "emdash"]

    [[rule]]
    id = "no-emoji-in-replies"
    event = "Stop"
    message = "No emoji."
    [rule.match]
    content_chars = ["emoji", "status_markers", "emdash"]
    TOML

    set +e
    out=$(echo '{"tool_name":"Write","tool_input":{"file_path":"/tmp/x","content":"done \u2705"}}' | "$bin" check --config "$cfg" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -ne 2 ] || ! grep -q 'U+2705' <<<"$out"; then echo "check-chars write: FAIL (exit $rc: $out)"; exit 1; fi
    echo "check-chars write: PASS"

    out=$(echo '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"done \u2705"}' | "$bin" check --config "$cfg")
    if ! grep -q 'additionalContext' <<<"$out"; then echo "check-chars stop: FAIL ($out)"; exit 1; fi
    echo "check-chars stop: PASS"

    out=$(echo '{"hook_event_name":"Stop","stop_hook_active":false,"last_assistant_message":"run `grep \u2713`"}' | "$bin" check --config "$cfg")
    if [ -n "$out" ]; then echo "check-chars code span: FAIL ($out)"; exit 1; fi
    echo "check-chars code span: PASS"
```

Run: `just check-chars`
Expected: three PASS lines.

- [ ] **Step 6: Commit**

```bash
just check
git add src/cli/check.zig src/main.zig Justfile
git commit -m "feat: answer Stop hooks with feedback and list character-class hits

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: Install and uninstall the Stop hook

**Files:**
- Modify: `src/cli/install.zig`

**Interfaces:**
- Consumes: nothing new.
- Produces: `install` registers `veer check` (or `veer check --verbose`) under `hooks.Stop` in an entry with no `matcher`; `uninstall` removes it.

- [ ] **Step 1: Write the failing tests**

```zig
test "install registers veer under PreToolUse and Stop" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    _ = try install(testing.allocator, std.testing.io, paths, false, &stream);

    const content = try readFileAlloc(testing.allocator, std.testing.io, paths.settings);
    defer testing.allocator.free(content);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, content, .{});
    defer parsed.deinit();
    const hooks = parsed.value.object.get("hooks").?.object;
    const stop = hooks.get("Stop").?.array.items;
    try testing.expectEqual(@as(usize, 1), stop.len);
    try testing.expect(stop[0].object.get("matcher") == null);
    const cmd = stop[0].object.get("hooks").?.array.items[0].object.get("command").?.string;
    try testing.expectEqualStrings("veer check", cmd);
}

test "install preserves an existing non-veer Stop hook and uninstall keeps it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(tmp_root);
    const paths = try testPaths(testing.allocator, tmp_root);
    defer freeTestPaths(testing.allocator, paths);

    try testWriteFile(std.testing.io, paths.settings,
        \\{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"notify-done"}]}]}}
    );

    var buf: [4096]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);
    _ = try install(testing.allocator, std.testing.io, paths, false, &stream);
    {
        const content = try readFileAlloc(testing.allocator, std.testing.io, paths.settings);
        defer testing.allocator.free(content);
        try testing.expect(std.mem.indexOf(u8, content, "notify-done") != null);
        try testing.expect(std.mem.indexOf(u8, content, "veer check") != null);
    }

    stream.end = 0;
    _ = try uninstall(testing.allocator, std.testing.io, paths, &stream);
    const content = try readFileAlloc(testing.allocator, std.testing.io, paths.settings);
    defer testing.allocator.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "notify-done") != null);
    try testing.expect(std.mem.indexOf(u8, content, "veer check") == null);
}
```

Update the existing "install is idempotent (no duplicate veer entries)" test: it now expects exactly 2 occurrences of `veer check` (one under PreToolUse, one under Stop). Change the expected count to 2 and its comment to "one entry per hook event".

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test`
Expected: FAIL: no `Stop` key, and the idempotency test counts 1.

- [ ] **Step 3: Implement**

Add near the hook command constants:

```zig
/// Hook events veer registers for. PreToolUse entries use matcher "*"; Stop
/// takes no matcher.
const HookEvent = struct { name: []const u8, matcher: ?[]const u8 };
const hook_events = [_]HookEvent{
    .{ .name = "PreToolUse", .matcher = "*" },
    .{ .name = "Stop", .matcher = null },
};
```

In `installHook`, replace everything from `// Navigate / create hooks.PreToolUse array.` through the `matcher_hooks.array.append(...)` call with:

```zig
    const hooks_val = try getOrCreateObject(arena, &parsed.value.object, "hooks");
    for (hook_events) |event| {
        try addVeerHook(arena, &hooks_val.object, event, verbose);
    }
```

and add:

```zig
/// Append the veer command to the event's entry whose matcher equals
/// `event.matcher` (or that has no matcher, when it is null), creating the
/// entry if none exists.
fn addVeerHook(arena: std.mem.Allocator, hooks_obj: *std.json.ObjectMap, event: HookEvent, verbose: bool) !void {
    const event_arr = try getOrCreateArray(arena, hooks_obj, event.name);

    const entry: *std.json.Value = blk: {
        for (event_arr.array.items) |*e| {
            if (e.* != .object) continue;
            const m = e.object.get("matcher");
            if (event.matcher) |want| {
                if (m) |v| {
                    if (v == .string and std.mem.eql(u8, v.string, want)) break :blk e;
                }
            } else if (m == null) {
                break :blk e;
            }
        }
        var new_obj: std.json.ObjectMap = .empty;
        if (event.matcher) |want| try new_obj.put(arena, "matcher", .{ .string = want });
        try new_obj.put(arena, "hooks", .{ .array = .init(arena) });
        try event_arr.array.append(.{ .object = new_obj });
        break :blk &event_arr.array.items[event_arr.array.items.len - 1];
    };

    const entry_hooks = try getOrCreateArray(arena, &entry.object, "hooks");
    var hook_obj: std.json.ObjectMap = .empty;
    try hook_obj.put(arena, "type", .{ .string = "command" });
    try hook_obj.put(arena, "command", .{ .string = hookCommandFor(verbose) });
    try entry_hooks.array.append(.{ .object = hook_obj });
}
```

Split `removeVeerEntries` so each registered event is cleaned:

```zig
/// Remove veer entries from every event veer registers for, pruning empty
/// containers. Returns true if anything was removed.
fn removeVeerEntries(root: *std.json.ObjectMap) bool {
    const hooks_val = root.getPtr("hooks") orelse return false;
    if (hooks_val.* != .object) return false;

    var removed_any = false;
    for (hook_events) |event| {
        if (removeFromEvent(&hooks_val.object, event.name)) removed_any = true;
    }
    if (!removed_any) return false;

    if (hooks_val.object.count() == 0) _ = root.swapRemove("hooks");
    return true;
}

/// Walk hooks[event_name][] -> each entry -> hooks[], remove veer entries,
/// drop entries left empty, and drop the event key when it empties.
fn removeFromEvent(hooks_obj: *std.json.ObjectMap, event_name: []const u8) bool {
    const event_val = hooks_obj.getPtr(event_name) orelse return false;
    if (event_val.* != .array) return false;

    var removed_any = false;
    var i: usize = 0;
    while (i < event_val.array.items.len) {
        const entry = &event_val.array.items[i];
        if (entry.* != .object) {
            i += 1;
            continue;
        }
        const entry_hooks = entry.object.getPtr("hooks");
        if (entry_hooks == null or entry_hooks.?.* != .array) {
            i += 1;
            continue;
        }
        var j: usize = 0;
        while (j < entry_hooks.?.array.items.len) {
            if (isVeerHookEntry(&entry_hooks.?.array.items[j])) {
                _ = entry_hooks.?.array.orderedRemove(j);
                removed_any = true;
            } else {
                j += 1;
            }
        }
        // Drop the entry entirely if its hooks[] is now empty.
        if (entry_hooks.?.array.items.len == 0) {
            _ = event_val.array.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    if (!removed_any) return false;
    if (event_val.array.items.len == 0) _ = hooks_obj.swapRemove(event_name);
    return true;
}
```

This is the existing loop from `removeVeerEntries`, with `pretool_val` renamed to `event_val` and `matcher_hooks` to `entry_hooks`.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test`
Expected: PASS, including the existing install and uninstall tests.

- [ ] **Step 5: Commit**

```bash
just check
git add src/cli/install.zig
git commit -m "feat: register veer for the Stop hook on install

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: `veer test --event`, `veer list`, and docs

**Files:**
- Modify: `src/cli/test_cmd.zig`, `src/main.zig` (`runTest`)
- Modify: `src/cli/list.zig`
- Modify: `README.md`, `src/cli/skill_content.md`, `src/cli/install.zig` (sentinel test)

**Interfaces:**
- Consumes: `Event`, `contentFormatFor` (Task 3); `CheckResult.content_chars` (Task 4); `chars.writeHits` (Task 2).
- Produces: `TestOptions.event: Event = .PreToolUse`.

- [ ] **Step 1: Write the failing tests**

In `test_cmd.zig`, mirroring the existing "run with --tool and --path evaluates a non-Bash rule" test (reuse its tmp-file pattern for the content file):

```zig
test "run with --event Stop evaluates a reply file and lists hits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "reply.md", .data = "ok `\u{2713}`\n\u{2705} done" });
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(dir);
    const file = try std.fmt.allocPrint(std.testing.allocator, "{s}/reply.md", .{dir});
    defer std.testing.allocator.free(file);

    const rules = [_]Rule{.{ .id = "no-emoji-in-replies", .event = .Stop, .message = "m", .match = .{ .content_chars = &.{ "emoji", "status_markers" } } }};
    var buf: [1024]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const code = try run(std.testing.allocator, std.testing.io, &rules, null, .{ .event = .Stop, .content_file = file }, &w);
    try std.testing.expectEqual(@as(u8, 0), code);
    const out = w.buffered();
    try std.testing.expect(std.mem.startsWith(u8, out, "REJECT\t2\t"));
    try std.testing.expect(std.mem.indexOf(u8, out, "line 2: U+2705") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "U+2713") == null);
}

test "run with --event Stop requires --content-file" {
    const rules = [_]Rule{};
    var buf: [512]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    const code = try run(std.testing.allocator, std.testing.io, &rules, null, .{ .event = .Stop }, &w);
    try std.testing.expectEqual(@as(u8, 1), code);
    try std.testing.expect(std.mem.indexOf(u8, w.buffered(), "--content-file") != null);
}
```

In `list.zig`, mirroring "list renders tool_any as a comma-joined list": a rule with `.event = .Stop` renders `Stop` in the tool column.

In `install.zig`, a sentinel test:

```zig
test "skill_content documents character classes" {
    try testing.expect(std.mem.indexOf(u8, skill_content, "content_chars") != null);
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test`
Expected: compile error for `TestOptions.event`, then FAIL on the list and sentinel tests.

- [ ] **Step 3: Implement**

`TestOptions` gets:

```zig
    /// Hook event to evaluate. A Stop event reads the reply from --content-file.
    event: rule_mod.Event = .PreToolUse,
```

(import `const rule_mod = @import("../config/rule.zig");` and `const chars = @import("../engine/chars.zig");`).

At the start of `run`, after the sources assert:

```zig
    if (opts.event == .Stop) {
        const cf = opts.content_file orelse {
            try writer.print("veer test: --event Stop requires --content-file\n", .{});
            return 1;
        };
        if (opts.command != null or opts.file_path != null or opts.path != null) {
            try writer.print("veer test: --event Stop only takes --content-file\n", .{});
            return 1;
        }
        const reply = std.Io.Dir.cwd().readFileAlloc(io, cf, allocator, .limited(4 * 1024 * 1024)) catch {
            try writer.print("veer test: cannot read {s}\n", .{cf});
            return 1;
        };
        defer allocator.free(reply);
        return checkCall(allocator, rules, sources, .{
            .tool_name = "",
            .event = .Stop,
            .content = reply,
            .content_format = .markdown,
        }, cf, writer);
    }
```

In the existing non-Bash `checkCall` call at the end of `run`, add `.content_format = rule_mod.contentFormatFor(opts.tool),`.

In `checkCall`'s `.reject, .allow` arm, after the `REJECT` line:

```zig
                if (result.content_chars) |names| {
                    if (call.content) |content| {
                        try chars.writeHits(allocator, writer, content, call.content_format, names, 5);
                    }
                }
```

In `src/main.zig` `runTest`, add the param line `\\    --event <str>         Hook event to evaluate: PreToolUse (default) or Stop.` and:

```zig
    const event: rule_mod.Event = if (res.args.event) |name|
        std.meta.stringToEnum(rule_mod.Event, name) orelse {
            std.debug.print("veer test: unknown --event {s} (expected PreToolUse or Stop)\n", .{name});
            std.process.exit(1);
        }
    else
        .PreToolUse;
```

passing `.event = event` in `TestOptions` (import `rule_mod` in `main.zig` if it is not already).

In `list.zig`, where `tool_str` is computed, show the event for non-tool rules:

```zig
        const tool_str = if (rule.event == .Stop) "Stop" else if (rule.tool_any) |tools| blk: {
```

- [ ] **Step 4: Update the docs**

`README.md`:
- In the match-field TOML example after `content_contains`, add `content_chars = ["emoji", "status_markers", "emdash"]  # Forbid named character classes`.
- In the matcher table, add a `content_chars` row: "Tool text content | Rejects when the content holds a character from any listed class: `emoji` (Unicode emoji presentation), `status_markers` (checkmark, cross, ballot box, warning, and star glyphs), `emdash` (U+2014). Code spans are ignored in markdown content." Change the `content_regex` and `content_contains` rows' "Non-Bash tools only." to "Any tool that carries content; see Content per tool."
- Add a section "Banning emoji and em dashes" containing the two-rule example from the spec's Rule schema section, a short "Content per tool" table copied from the spec, a sentence that `Stop` rules give Claude one non-error correction turn per reply, and a sentence that `veer install` registers veer for both `PreToolUse` and `Stop`.
- Document `veer test --event Stop --content-file <reply.md>`.

`src/cli/skill_content.md`:
- In "Matching non-Bash tools", add a subsection "Banning emoji, status markers, and em dashes" with the two-rule example, one sentence on each class, the note that markdown code spans are ignored, and the note that read-only tools (Read, Grep, Glob) carry no content so searching for a character is never rejected.
- In the matcher table add a `content_chars` row.
- Add `tool = "*"` and `event = "Stop"` to "Rule structure (TOML)" as commented fields.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `just check`
Expected: PASS, including all smoke tests.

- [ ] **Step 6: Commit**

```bash
git add src/cli/test_cmd.zig src/main.zig src/cli/list.zig src/cli/install.zig README.md src/cli/skill_content.md
git commit -m "feat: veer test --event, Stop rules in veer list, and docs for character classes

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

## Self-review notes

- Spec coverage: schema (Task 3), classes and table (Task 1), code spans (Task 2), content per tool (Task 5), PreToolUse hit lines and Stop output (Task 6), install (Task 7), `veer test` and docs (Task 8). MessageDisplay, SubagentStop, opt-out markers, and path exclusion are non-goals.
- Names used across tasks: `ClassSet.fromNames`, `firstHit`, `Scanner`, `containsAny`, `writeHits`, `schemaIssue`, `issueText`, `contentFormatFor`, `ToolCall.event`, `ToolCall.content_format`, `CheckResult.content_chars`, `HookInput.event`, `HookInput.stop_hook_active`, `HookInput.content_format`, `formatStopFeedback`, `TestOptions.event`.
