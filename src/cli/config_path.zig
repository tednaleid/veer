// ABOUTME: Resolve which config file `add`/`remove`/`validate` should target.
// ABOUTME: Maps --local / --global / --config / default to a concrete path with cleanup.

const std = @import("std");
const install_cmd = @import("install.zig");

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

// -- Tests --

const testing = std.testing;

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
