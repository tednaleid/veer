// ABOUTME: Path resolution and glob matching for veer's path* matchers.
// ABOUTME: Lexical normalization only; no realpath, no stat, no symlinks.

const std = @import("std");
const matcher = @import("matcher.zig");

/// A tool call's target path in both the forms a pattern can match against.
/// `relative` is a slice into `absolute` and is null when the path is not
/// inside `root`, which is what makes a relative pattern unable to reach
/// outside the project.
pub const Resolved = struct {
    absolute: []const u8,
    relative: ?[]const u8,
};

/// Normalize `raw` into `buf` and locate it relative to `root`.
///
/// Lexical only: `.` and `..` are resolved textually and symlinks are left
/// alone. Write creates files that do not exist yet, so realpath would fail
/// on exactly the calls most worth catching, and syscalls do not belong in
/// the hot path.
///
/// Returns null when the result does not fit in `buf`, or when `raw` is
/// relative and both `cwd` and `root` are null.
pub fn resolve(
    raw: []const u8,
    cwd: ?[]const u8,
    root: ?[]const u8,
    buf: []u8,
) ?Resolved {
    // `cwd` and `root` arrive as raw strings from the hook envelope and the
    // discovered project directory -- neither is guaranteed to be free of a
    // trailing separator. Normalizing them here keeps the prefix comparison
    // in `isUnder` and the relative slice below aligned on segment
    // boundaries regardless of how they were spelled.
    var cwd_norm_buf: [std.fs.max_path_bytes]u8 = undefined;
    var root_norm_buf: [std.fs.max_path_bytes]u8 = undefined;
    const norm_cwd: ?[]const u8 = if (cwd) |c| normalize(c, &cwd_norm_buf) orelse return null else null;
    const norm_root: ?[]const u8 = if (root) |r| normalize(r, &root_norm_buf) orelse return null else null;

    const base = norm_root orelse norm_cwd;

    var joined_buf: [std.fs.max_path_bytes]u8 = undefined;
    const joined: []const u8 = if (raw.len > 0 and raw[0] == '/')
        raw
    else blk: {
        const anchor = norm_cwd orelse base orelse return null;
        const need = anchor.len + 1 + raw.len;
        if (need > joined_buf.len) return null;
        @memcpy(joined_buf[0..anchor.len], anchor);
        joined_buf[anchor.len] = '/';
        @memcpy(joined_buf[anchor.len + 1 ..][0..raw.len], raw);
        break :blk joined_buf[0..need];
    };

    const absolute = normalize(joined, buf) orelse return null;

    const r = base orelse return .{ .absolute = absolute, .relative = null };
    if (!isUnder(absolute, r)) return .{ .absolute = absolute, .relative = null };
    return .{ .absolute = absolute, .relative = relativeTo(absolute, r) };
}

/// The portion of `path` after `root`, or null when `path` is `root` itself
/// (which has no relative form). Both must already be normalized: no
/// trailing separator, except `root` may be exactly `/`. Callers must check
/// `isUnder(path, root)` first.
fn relativeTo(path: []const u8, root: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, "/")) {
        // root has no separator of its own to skip; path is already "/..."
        if (path.len <= 1) return null;
        return path[1..];
    }
    // +1 skips the separator. Equal-length means the path IS the root, which
    // has no relative form.
    if (path.len <= root.len + 1) return null;
    return path[root.len + 1 ..];
}

/// True when `path` is `root` itself or lives inside it. Compares whole
/// segments, so /a/proj-other is not inside /a/proj. Both must already be
/// normalized: no trailing separator, except `root` may be exactly `/`, in
/// which case every absolute `path` is under it by definition.
fn isUnder(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, root, "/")) return true;
    if (!std.mem.startsWith(u8, path, root)) return false;
    if (path.len == root.len) return true;
    return path[root.len] == '/';
}

/// Collapse repeated separators and resolve `.` and `..` textually. Writes
/// into `buf` and returns the slice, or null if it does not fit.
fn normalize(path: []const u8, buf: []u8) ?[]const u8 {
    var stack: [128][]const u8 = undefined;
    var depth: usize = 0;

    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (depth > 0) depth -= 1;
            continue;
        }
        if (depth >= stack.len) return null;
        stack[depth] = seg;
        depth += 1;
    }

    var len: usize = 0;
    for (stack[0..depth]) |seg| {
        if (len + 1 + seg.len > buf.len) return null;
        buf[len] = '/';
        len += 1;
        @memcpy(buf[len..][0..seg.len], seg);
        len += seg.len;
    }
    if (len == 0) {
        if (buf.len < 1) return null;
        buf[0] = '/';
        len = 1;
    }
    return buf[0..len];
}

/// Maximum segments in a pattern or a path. Deeper inputs do not match.
const max_segments = 128;

/// How a pattern's leading and trailing syntax changes what it is matched
/// against. `body` is a slice of the original pattern with `./` stripped and
/// a trailing `/` trimmed.
pub const PathPattern = struct {
    body: []const u8,
    /// Matched against the absolute path rather than the root-relative one.
    absolute: bool = false,
    /// `body` is relative to $HOME.
    home_relative: bool = false,
    /// Prepend an implicit `**` segment: the pattern matches at any depth.
    any_depth: bool = false,
    /// Append an implicit `**` segment: the pattern matches a directory's
    /// contents.
    dir_contents: bool = false,
};

/// Classify a pattern by its leading and trailing syntax. A trailing `/` is
/// handled first, then the leading form decides anchoring.
pub fn classifyPattern(pattern: []const u8) PathPattern {
    var result = PathPattern{ .body = pattern };
    var body = pattern;

    if (body.len > 1 and body[body.len - 1] == '/') {
        body = body[0 .. body.len - 1];
        result.dir_contents = true;
    }

    if (std.mem.startsWith(u8, body, "~/")) {
        result.absolute = true;
        result.home_relative = true;
        body = body[2..];
    } else if (body.len > 0 and body[0] == '/') {
        result.absolute = true;
        body = body[1..];
    } else if (std.mem.startsWith(u8, body, "./")) {
        body = body[2..];
    } else if (std.mem.indexOfScalar(u8, body, '/') == null) {
        result.any_depth = true;
    }

    result.body = body;
    return result;
}

/// Match a classified pattern against a resolved path. `home` is $HOME, used
/// only for `~/` patterns; pass null to make them never match.
pub fn matches(pattern: []const u8, resolved: Resolved, home: ?[]const u8) bool {
    const pp = classifyPattern(pattern);

    const target: []const u8 = if (pp.absolute) blk: {
        if (!pp.home_relative) break :blk stripLeadingSlash(resolved.absolute);
        const h = home orelse return false;
        if (!isUnder(resolved.absolute, h)) return false;
        if (resolved.absolute.len <= h.len + 1) return false;
        break :blk resolved.absolute[h.len + 1 ..];
    } else resolved.relative orelse return false;

    return matchWithImplicit(pp, target);
}

fn stripLeadingSlash(s: []const u8) []const u8 {
    return if (s.len > 0 and s[0] == '/') s[1..] else s;
}

fn matchWithImplicit(pp: PathPattern, target: []const u8) bool {
    var pat_buf: [max_segments][]const u8 = undefined;
    var n: usize = 0;

    if (pp.any_depth) {
        pat_buf[n] = "**";
        n += 1;
    }
    n = appendSegments(pp.body, &pat_buf, n) orelse return false;
    if (pp.dir_contents) {
        if (n >= pat_buf.len) return false;
        pat_buf[n] = "**";
        n += 1;
    }

    var path_buf: [max_segments][]const u8 = undefined;
    const path_n = appendSegments(target, &path_buf, 0) orelse return false;

    return matchSegments(pat_buf[0..n], path_buf[0..path_n]);
}

/// Split `s` on `/` into `out` starting at `n`, returning the new count.
/// Empty segments are dropped, and a `**` immediately following another `**`
/// is dropped so `a/**/**/b` cannot make the matcher backtrack exponentially.
fn appendSegments(s: []const u8, out: *[max_segments][]const u8, start: usize) ?usize {
    var n = start;
    var iter = std.mem.splitScalar(u8, s, '/');
    while (iter.next()) |seg| {
        if (seg.len == 0) continue;
        if (std.mem.eql(u8, seg, "**") and n > 0 and std.mem.eql(u8, out[n - 1], "**")) continue;
        if (n >= out.len) return null;
        out[n] = seg;
        n += 1;
    }
    return n;
}

/// Bounds a (pattern_index, path_index) memo: both indices can reach their
/// slice's length (the "consumed everything" state), so each dimension
/// needs max_segments + 1 slots.
const MemoSet = std.StaticBitSet((max_segments + 1) * (max_segments + 1));

fn matchSegments(pat: []const []const u8, path: []const []const u8) bool {
    var memo = MemoSet.initEmpty();
    return matchFrom(pat, 0, path, 0, &memo);
}

/// Match `pat[pi..]` against `path[pj..]`, memoizing failed states so a
/// `**` is not re-explored from the same position twice. Without this, two
/// non-adjacent `**` segments each try every split point, and their
/// combinations grow exponentially with the number of `**` in the pattern.
/// `memo` records only failures: a match short-circuits the whole search
/// via its `true` return, so successes never need to be cached.
fn matchFrom(
    pat: []const []const u8,
    pi: usize,
    path: []const []const u8,
    pj: usize,
    memo: *MemoSet,
) bool {
    if (pi == pat.len) return pj == path.len;

    const key = pi * (max_segments + 1) + pj;
    if (memo.isSet(key)) return false;

    const found = blk: {
        if (std.mem.eql(u8, pat[pi], "**")) {
            var i = pj;
            while (i <= path.len) : (i += 1) {
                if (matchFrom(pat, pi + 1, path, i, memo)) break :blk true;
            }
            break :blk false;
        }
        if (pj == path.len) break :blk false;
        if (!matcher.globMatch(pat[pi], path[pj])) break :blk false;
        break :blk matchFrom(pat, pi + 1, path, pj + 1, memo);
    };

    if (!found) memo.set(key);
    return found;
}

/// Match a raw pattern against a raw path, both split on `/`. Exposed for
/// testing the segment semantics without going through classification.
pub fn pathMatch(pattern: []const u8, path: []const u8) bool {
    var pat_buf: [max_segments][]const u8 = undefined;
    var path_buf: [max_segments][]const u8 = undefined;
    const pat_n = appendSegments(pattern, &pat_buf, 0) orelse return false;
    const path_n = appendSegments(path, &path_buf, 0) orelse return false;
    return matchSegments(pat_buf[0..pat_n], path_buf[0..path_n]);
}

// -- Tests --

test "resolve makes a relative path absolute against cwd" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("src/App.vue", "/home/me/proj", "/home/me/proj", &buf).?;
    try std.testing.expectEqualStrings("/home/me/proj/src/App.vue", r.absolute);
    try std.testing.expectEqualStrings("src/App.vue", r.relative.?);
}

test "resolve collapses dot and dot-dot segments" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/apps/../apps/./x.ts", null, "/home/me/proj", &buf).?;
    try std.testing.expectEqualStrings("/home/me/proj/apps/x.ts", r.absolute);
    try std.testing.expectEqualStrings("apps/x.ts", r.relative.?);
}

test "resolve leaves a path outside root with no relative form" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/tmp/scratch.txt", null, "/home/me/proj", &buf).?;
    try std.testing.expectEqualStrings("/tmp/scratch.txt", r.absolute);
    try std.testing.expect(r.relative == null);
}

test "resolve does not treat a sibling directory as inside root" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj-other/x.ts", null, "/home/me/proj", &buf).?;
    try std.testing.expect(r.relative == null);
}

test "resolve falls back to cwd when root is null" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/a.ts", "/home/me/proj", null, &buf).?;
    try std.testing.expectEqualStrings("a.ts", r.relative.?);
}

test "resolve treats a trailing slash on root the same as no trailing slash" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/src/a.ts", null, "/home/me/proj/", &buf).?;
    try std.testing.expectEqualStrings("/home/me/proj/src/a.ts", r.absolute);
    try std.testing.expectEqualStrings("src/a.ts", r.relative.?);
}

test "resolve treats a trailing slash on cwd the same as no trailing slash" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/src/a.ts", "/home/me/proj/", null, &buf).?;
    try std.testing.expectEqualStrings("src/a.ts", r.relative.?);
}

test "resolve treats root as the whole filesystem" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/src/a.ts", null, "/", &buf).?;
    try std.testing.expectEqualStrings("/home/me/proj/src/a.ts", r.absolute);
    try std.testing.expectEqualStrings("home/me/proj/src/a.ts", r.relative.?);
}

test "resolve treats cwd as the whole filesystem" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/src/a.ts", "/", null, &buf).?;
    try std.testing.expectEqualStrings("home/me/proj/src/a.ts", r.relative.?);
}

test "resolve at exactly root itself has no relative form" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/", null, "/", &buf).?;
    try std.testing.expectEqualStrings("/", r.absolute);
    try std.testing.expect(r.relative == null);
}

test "pathMatch segment semantics" {
    const cases = .{
        // pattern, path, expected
        .{ "src/*", "src/App.vue", true },
        .{ "src/*", "src/ui/Button.vue", false },
        .{ "src/**", "src/App.vue", true },
        .{ "src/**", "src/ui/Button.vue", true },
        .{ "a/**/b", "a/b", true },
        .{ "a/**/b", "a/x/b", true },
        .{ "a/**/b", "a/x/y/b", true },
        .{ "a/**/b", "a/x/y/c", false },
        .{ "**/dist/**", "apps/web/dist/index.js", true },
        .{ "**/dist/**", "dist/index.js", true },
        .{ "**/*.env", "apps/web/.env", true },
        .{ "src/**/*.{ts,vue}", "src/ui/Button.vue", true },
        .{ "src/**/*.{ts,vue}", "src/ui/Button.css", false },
        .{ "a/**/**/**/b", "a/x/y/z/b", true },
    };
    inline for (cases) |c| {
        try std.testing.expectEqual(c[2], pathMatch(c[0], c[1]));
    }
}

test "matchSegments does not backtrack exponentially on many non-adjacent wildcards" {
    // (**/a/)*6 zzz against 60 "a" segments: every "**" can split at every
    // remaining position, and none of them are adjacent so appendSegments'
    // consecutive-"**" collapse does not help. Without memoization this
    // pattern takes seconds; memoized it should be effectively instant.
    var pattern_buf: [256]u8 = undefined;
    var pattern_len: usize = 0;
    var n: usize = 0;
    while (n < 6) : (n += 1) {
        const group = "**/a/";
        @memcpy(pattern_buf[pattern_len..][0..group.len], group);
        pattern_len += group.len;
    }
    const tail = "zzz";
    @memcpy(pattern_buf[pattern_len..][0..tail.len], tail);
    pattern_len += tail.len;
    const pattern = pattern_buf[0..pattern_len];

    var path_buf: [256]u8 = undefined;
    var path_len: usize = 0;
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        if (i > 0) {
            path_buf[path_len] = '/';
            path_len += 1;
        }
        path_buf[path_len] = 'a';
        path_len += 1;
    }
    const path = path_buf[0..path_len];

    var timer = try std.time.Timer.start();
    // The path is all "a" segments and the pattern requires a trailing
    // "zzz" segment, so this can never match.
    try std.testing.expect(!pathMatch(pattern, path));
    const elapsed_ns = timer.read();

    // The unmemoized matcher takes several seconds on this input; a
    // memoized matcher finishes in well under a second.
    try std.testing.expect(elapsed_ns < 1 * std.time.ns_per_s);
}

test "classifyPattern" {
    const abs = classifyPattern("/etc/**");
    try std.testing.expect(abs.absolute);
    try std.testing.expectEqualStrings("etc/**", abs.body);

    const home = classifyPattern("~/.ssh/**");
    try std.testing.expect(home.absolute);
    try std.testing.expect(home.home_relative);

    const anchored = classifyPattern("./.env");
    try std.testing.expect(!anchored.absolute);
    try std.testing.expect(!anchored.any_depth);
    try std.testing.expectEqualStrings(".env", anchored.body);

    const slashed = classifyPattern("src/**");
    try std.testing.expect(!slashed.any_depth);

    const bare = classifyPattern(".env");
    try std.testing.expect(bare.any_depth);

    const dir = classifyPattern("node_modules/");
    try std.testing.expect(dir.dir_contents);
    try std.testing.expectEqualStrings("node_modules", dir.body);
}

test "matches applies classification to a resolved path" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/home/me/proj/apps/web/.env", null, "/home/me/proj", &buf).?;

    try std.testing.expect(matches(".env", r, null));
    try std.testing.expect(!matches("./.env", r, null));
    try std.testing.expect(matches("apps/**", r, null));
    try std.testing.expect(!matches("/etc/**", r, null));

    var out_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside = resolve("/tmp/scratch.txt", null, "/home/me/proj", &out_buf).?;
    // A relative pattern never reaches outside the root, not even via basename.
    try std.testing.expect(!matches("*", outside, null));
    try std.testing.expect(matches("/tmp/**", outside, null));
}

test "node_modules needs a slash form" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const r = resolve("/p/node_modules/left-pad/index.js", null, "/p", &buf).?;
    // Documented limitation: a no-slash pattern matches file names only.
    try std.testing.expect(!matches("node_modules", r, null));
    try std.testing.expect(matches("node_modules/", r, null));
    try std.testing.expect(matches("node_modules/**", r, null));
}
