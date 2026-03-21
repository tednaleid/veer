// ABOUTME: Single test entry point that imports all test modules.
// ABOUTME: Needed because individual test files can't cross directory boundaries.

comptime {
    _ = @import("engine/command_info.zig");
    _ = @import("engine/shell.zig");
    _ = @import("engine/matcher.zig");
    _ = @import("engine/engine.zig");
    _ = @import("config/rule.zig");
    _ = @import("config/config.zig");
    _ = @import("claude/hook.zig");
    _ = @import("cli/check.zig");
}
