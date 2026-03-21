// ABOUTME: Claude Code settings.json reader for permission classification.
// ABOUTME: Classifies commands as allowed/denied/prompt based on allowedTools/deniedTools.

const std = @import("std");
const globMatch = @import("../engine/matcher.zig").globMatch;

pub const Permission = enum {
    allowed,
    denied,
    prompt,
};

pub const SettingsReader = struct {
    allowed_tools: []const []const u8,
    denied_tools: []const []const u8,
    allocator: std.mem.Allocator,

    /// Load settings from a JSON file.
    pub fn loadFile(allocator: std.mem.Allocator, path: []const u8) !SettingsReader {
        const content = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch {
            return error.FileNotFound;
        };
        defer allocator.free(content);
        return loadString(allocator, content);
    }

    /// Load settings from a JSON string.
    pub fn loadString(allocator: std.mem.Allocator, content: []const u8) !SettingsReader {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, content, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return error.InvalidSettings;

        const allowed = try extractStringArray(allocator, root, "allowedTools");
        const denied = try extractStringArray(allocator, root, "deniedTools");

        return .{
            .allowed_tools = allowed,
            .denied_tools = denied,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *SettingsReader) void {
        for (self.allowed_tools) |t| self.allocator.free(t);
        self.allocator.free(self.allowed_tools);
        for (self.denied_tools) |t| self.allocator.free(t);
        self.allocator.free(self.denied_tools);
    }

    /// Classify a Bash command against permission rules.
    pub fn classify(self: SettingsReader, command: []const u8) Permission {
        // Check denied first
        for (self.denied_tools) |pattern| {
            if (matchToolPattern(pattern, "Bash", command)) return .denied;
        }

        // Then allowed
        for (self.allowed_tools) |pattern| {
            if (matchToolPattern(pattern, "Bash", command)) return .allowed;
        }

        return .prompt;
    }
};

/// Match a tool permission pattern like "Bash(grep:*)" or "Bash(just *)" against
/// a tool name and command.
/// Match a tool permission pattern against a tool name and full command string.
fn matchToolPattern(pattern: []const u8, tool_name: []const u8, command: []const u8) bool {
    // Patterns can be: "Read", "Bash(grep:*)", "Bash(just *)", etc.

    // Check for "ToolName(glob)" format
    if (std.mem.indexOfScalar(u8, pattern, '(')) |paren_start| {
        const pat_tool = pattern[0..paren_start];
        if (!std.mem.eql(u8, pat_tool, tool_name)) return false;

        if (std.mem.lastIndexOfScalar(u8, pattern, ')')) |paren_end| {
            if (paren_end <= paren_start) return false;
            const glob_pattern = pattern[paren_start + 1 .. paren_end];

            // Claude Code patterns use "cmd:*" or "cmd *" format
            // "grep:*" means base command is grep -- match first word
            if (std.mem.indexOfScalar(u8, glob_pattern, ':')) |colon| {
                const cmd_part = glob_pattern[0..colon];
                var iter = std.mem.splitScalar(u8, command, ' ');
                const base_cmd = iter.first();
                return globMatch(cmd_part, base_cmd);
            }

            // "just *" -- match against the full command string
            return globMatch(glob_pattern, command);
        }
    }

    // Bare tool name like "Read" -- matches the tool, not specific commands
    return std.mem.eql(u8, pattern, tool_name);
}

fn extractStringArray(allocator: std.mem.Allocator, root: std.json.Value, key: []const u8) ![]const []const u8 {
    const val = root.object.get(key) orelse return &.{};
    if (val != .array) return &.{};

    var result = std.ArrayListUnmanaged([]const u8).empty;
    for (val.array.items) |item| {
        if (item == .string) {
            try result.append(allocator, try allocator.dupe(u8, item.string));
        }
    }
    return try result.toOwnedSlice(allocator);
}

// -- Tests --

test "classify command against permissive settings" {
    const content = "{\"allowedTools\": [\"Bash(grep:*)\", \"Bash(cat:*)\", \"Bash(just *)\", \"Bash(ls:*)\", \"Read\"], \"deniedTools\": []}";
    var reader = try SettingsReader.loadString(std.testing.allocator, content);
    defer reader.deinit();

    try std.testing.expectEqual(Permission.allowed, reader.classify("grep -r TODO"));
    try std.testing.expectEqual(Permission.allowed, reader.classify("just test"));
    try std.testing.expectEqual(Permission.allowed, reader.classify("ls -la"));
    try std.testing.expectEqual(Permission.prompt, reader.classify("python3 script.py"));
}

test "classify command against restrictive settings" {
    const content = "{\"allowedTools\": [\"Bash(just *)\", \"Read\"], \"deniedTools\": [\"Bash(python3:*)\", \"Bash(rm:*)\", \"Bash(pytest:*)\"]}";
    var reader = try SettingsReader.loadString(std.testing.allocator, content);
    defer reader.deinit();

    try std.testing.expectEqual(Permission.denied, reader.classify("python3 script.py"));
    try std.testing.expectEqual(Permission.denied, reader.classify("rm -rf /tmp"));
    try std.testing.expectEqual(Permission.denied, reader.classify("pytest tests/"));
    try std.testing.expectEqual(Permission.allowed, reader.classify("just test"));
    try std.testing.expectEqual(Permission.prompt, reader.classify("grep TODO"));
}

test "matchToolPattern" {
    try std.testing.expect(matchToolPattern("Bash(grep:*)", "Bash", "grep -r TODO"));
    try std.testing.expect(matchToolPattern("Bash(just *)", "Bash", "just test"));
    try std.testing.expect(!matchToolPattern("Bash(grep:*)", "Bash", "cat file"));
    try std.testing.expect(!matchToolPattern("Bash(grep:*)", "Read", "grep"));
    try std.testing.expect(matchToolPattern("Read", "Read", "anything"));
}

test "empty settings classifies everything as prompt" {
    var reader = try SettingsReader.loadString(std.testing.allocator,
        \\{"allowedTools": [], "deniedTools": []}
    );
    defer reader.deinit();

    try std.testing.expectEqual(Permission.prompt, reader.classify("anything"));
}
