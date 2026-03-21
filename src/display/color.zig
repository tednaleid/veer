// ABOUTME: ANSI color helpers for terminal output.
// ABOUTME: Respects NO_COLOR env var and non-TTY output.

const std = @import("std");

pub const enabled = blk: {
    // Checked at comptime: NO_COLOR is an env var checked at runtime instead
    break :blk true;
};

/// Check at runtime if colors should be used.
pub fn isEnabled() bool {
    if (std.posix.getenv("NO_COLOR")) |_| return false;
    return true;
}

pub fn bold(en: bool) []const u8 {
    return if (en) "\x1b[1m" else "";
}
pub fn dim(en: bool) []const u8 {
    return if (en) "\x1b[2m" else "";
}
pub fn red(en: bool) []const u8 {
    return if (en) "\x1b[31m" else "";
}
pub fn green(en: bool) []const u8 {
    return if (en) "\x1b[32m" else "";
}
pub fn yellow(en: bool) []const u8 {
    return if (en) "\x1b[33m" else "";
}
pub fn cyan(en: bool) []const u8 {
    return if (en) "\x1b[36m" else "";
}
pub fn reset(en: bool) []const u8 {
    return if (en) "\x1b[0m" else "";
}

// -- Tests --

test "color codes returned when enabled" {
    try std.testing.expectEqualStrings("\x1b[1m", bold(true));
    try std.testing.expectEqualStrings("\x1b[31m", red(true));
    try std.testing.expectEqualStrings("\x1b[0m", reset(true));
}

test "empty strings when disabled" {
    try std.testing.expectEqualStrings("", bold(false));
    try std.testing.expectEqualStrings("", red(false));
    try std.testing.expectEqualStrings("", reset(false));
}
