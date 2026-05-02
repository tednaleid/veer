// ABOUTME: Resolve which config file `add`/`remove`/`validate` should target.
// ABOUTME: Maps --global / --config / default to a concrete path with cleanup.

const std = @import("std");
const install_cmd = @import("install.zig");

pub const ResolveError = error{
    /// Both --global and --config <path> were set.
    MutuallyExclusive,
    /// --global was set but $HOME is not in the environment.
    NoHome,
    OutOfMemory,
};

/// Resolved config path plus any allocations the caller needs to free.
/// `path` is borrowed from one of: a clap argument, a static literal, or
/// `paths_handle` (only when `--global`). Always call `deinit` to release
/// the allocation when `--global` was used.
pub const Resolved = struct {
    path: []const u8,
    /// Non-null only when `--global` was used; holds the heap-allocated
    /// path strings produced by `install_cmd.resolvePaths(.global)`.
    paths_handle: ?install_cmd.Paths = null,

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        if (self.paths_handle) |p| install_cmd.freePaths(allocator, p, .global);
    }
};

/// Pick the config file an `add`/`remove`/`validate` invocation should
/// touch. Precedence: explicit `--config` wins, then `--global` (resolves
/// to the same path that `veer install --global` writes to), otherwise
/// the per-repo `.veer/config.toml`.
pub fn resolve(allocator: std.mem.Allocator, global: bool, config_arg: ?[]const u8) ResolveError!Resolved {
    if (global and config_arg != null) return error.MutuallyExclusive;
    if (config_arg) |p| return .{ .path = p };
    if (global) {
        const paths = install_cmd.resolvePaths(allocator, .global) catch |err| switch (err) {
            error.NoHome => return error.NoHome,
            error.OutOfMemory => return error.OutOfMemory,
        };
        return .{ .path = paths.config, .paths_handle = paths };
    }
    return .{ .path = ".veer/config.toml" };
}

// -- Tests --

const testing = std.testing;

test "resolve defaults to per-repo .veer/config.toml" {
    var resolved = try resolve(testing.allocator, false, null);
    defer resolved.deinit(testing.allocator);
    try testing.expectEqualStrings(".veer/config.toml", resolved.path);
    try testing.expect(resolved.paths_handle == null);
}

test "resolve honors explicit --config path" {
    var resolved = try resolve(testing.allocator, false, "custom/foo.toml");
    defer resolved.deinit(testing.allocator);
    try testing.expectEqualStrings("custom/foo.toml", resolved.path);
    try testing.expect(resolved.paths_handle == null);
}

test "resolve --global yields ~/.config/veer/config.toml" {
    var resolved = try resolve(testing.allocator, true, null);
    defer resolved.deinit(testing.allocator);
    try testing.expect(std.mem.endsWith(u8, resolved.path, "/.config/veer/config.toml"));
    try testing.expect(resolved.paths_handle != null);
}

test "resolve rejects --global combined with --config" {
    try testing.expectError(error.MutuallyExclusive, resolve(testing.allocator, true, "foo.toml"));
}
