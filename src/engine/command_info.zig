// ABOUTME: Core data structures for shell command AST extraction.
// ABOUTME: CommandInfo and SingleCommand are what rules match against.

const std = @import("std");

/// Structured representation of a parsed shell command.
/// All string slices are borrowed from the original command string
/// via tree-sitter byte offsets -- CommandInfo does NOT own them.
/// Valid only while the source command string lives.
pub const CommandInfo = struct {
    raw: []const u8,
    commands: std.ArrayListUnmanaged(SingleCommand) = .empty,
    pipeline_stages: std.ArrayListUnmanaged(SingleCommand) = .empty,
    pipeline_length: u32 = 0,
    has_subshell: bool = false,
    has_command_subst: bool = false,
    has_process_subst: bool = false,
    has_redirection: bool = false,
    has_background_job: bool = false,
    has_eval: bool = false,
    logical_operators: std.ArrayListUnmanaged([]const u8) = .empty,
    max_nesting_depth: u32 = 0,

    pub fn deinit(self: *CommandInfo, allocator: std.mem.Allocator) void {
        for (self.commands.items) |*cmd| cmd.deinit(allocator);
        self.commands.deinit(allocator);
        for (self.pipeline_stages.items) |*cmd| cmd.deinit(allocator);
        self.pipeline_stages.deinit(allocator);
        self.logical_operators.deinit(allocator);
    }
};

/// A single command within a shell expression.
/// For "grep -r TODO src/", name="grep", flags=["-r"], positional=["TODO", "src/"].
pub const SingleCommand = struct {
    name: []const u8,
    args: std.ArrayListUnmanaged([]const u8) = .empty,
    flags: std.ArrayListUnmanaged([]const u8) = .empty,
    positional: std.ArrayListUnmanaged([]const u8) = .empty,

    pub fn deinit(self: *SingleCommand, allocator: std.mem.Allocator) void {
        self.args.deinit(allocator);
        self.flags.deinit(allocator);
        self.positional.deinit(allocator);
    }

    pub fn hasFlag(self: SingleCommand, flag: []const u8) bool {
        for (self.flags.items) |f| {
            if (std.mem.eql(u8, f, flag)) return true;
        }
        return false;
    }
};

// -- Tests --

test "SingleCommand.hasFlag returns true when present" {
    var cmd = SingleCommand{ .name = "grep" };
    defer cmd.deinit(std.testing.allocator);
    try cmd.flags.append(std.testing.allocator, "-r");
    try cmd.flags.append(std.testing.allocator, "--color");

    try std.testing.expect(cmd.hasFlag("-r"));
    try std.testing.expect(cmd.hasFlag("--color"));
    try std.testing.expect(!cmd.hasFlag("-v"));
}

test "CommandInfo.deinit frees all memory" {
    var info = CommandInfo{ .raw = "ls -la" };
    defer info.deinit(std.testing.allocator);

    var cmd = SingleCommand{ .name = "ls" };
    try cmd.flags.append(std.testing.allocator, "-la");
    try info.commands.append(std.testing.allocator, cmd);
}
