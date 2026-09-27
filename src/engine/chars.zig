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

/// A byte range [start, end) of `text` holding one class member, and the
/// 1-based line it starts on.
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
