// ABOUTME: Path resolution and glob matching for veer's path* matchers.
// ABOUTME: Lexical normalization only; no realpath, no stat, no symlinks.

const std = @import("std");

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
    const base = root orelse cwd;

    var joined_buf: [std.fs.max_path_bytes]u8 = undefined;
    const joined: []const u8 = if (raw.len > 0 and raw[0] == '/')
        raw
    else blk: {
        const anchor = cwd orelse base orelse return null;
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

    // +1 skips the separator. Equal-length means the path IS the root, which
    // has no relative form.
    if (absolute.len <= r.len + 1) return .{ .absolute = absolute, .relative = null };
    return .{ .absolute = absolute, .relative = absolute[r.len + 1 ..] };
}

/// True when `path` is `root` itself or lives inside it. Compares whole
/// segments, so /a/proj-other is not inside /a/proj.
fn isUnder(path: []const u8, root: []const u8) bool {
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
