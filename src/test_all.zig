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
    _ = @import("store/store.zig");
    _ = @import("store/memory_store.zig");
    _ = @import("store/sqlite_store.zig");
    _ = @import("display/color.zig");
    _ = @import("display/table.zig");
    _ = @import("cli/install.zig");
    _ = @import("cli/list.zig");
    _ = @import("cli/add.zig");
    _ = @import("cli/remove.zig");
    _ = @import("cli/stats.zig");
    _ = @import("cli/scan.zig");
    _ = @import("claude/transcript.zig");
    _ = @import("claude/settings.zig");
}
