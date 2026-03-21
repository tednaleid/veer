// ABOUTME: Shell command parser using tree-sitter-bash.
// ABOUTME: Parses shell strings into structured CommandInfo for rule matching.

const std = @import("std");
const ts = @import("tree_sitter");
const CommandInfo = @import("command_info.zig").CommandInfo;
const SingleCommand = @import("command_info.zig").SingleCommand;

extern fn tree_sitter_bash() callconv(.c) *const ts.Language;

/// Parse a shell command string into structured CommandInfo.
/// The returned CommandInfo borrows slices from `command` -- caller
/// must keep `command` alive while using the result.
pub fn parse(allocator: std.mem.Allocator, command: []const u8) !CommandInfo {
    if (command.len == 0) return CommandInfo{ .raw = command };

    const parser = ts.Parser.create();
    defer parser.destroy();
    try parser.setLanguage(tree_sitter_bash());

    const tree = parser.parseString(command, null) orelse return error.ParseFailed;
    defer tree.destroy();

    var info = CommandInfo{ .raw = command };
    errdefer info.deinit(allocator);

    try walkNode(allocator, tree.rootNode(), &info, command, 0, false);
    return info;
}

fn walkNode(
    allocator: std.mem.Allocator,
    node: ts.Node,
    info: *CommandInfo,
    source: []const u8,
    depth: u32,
    in_pipeline: bool,
) !void {
    const kind = node.kind();

    if (std.mem.eql(u8, kind, "pipeline")) {
        var stage_count: u32 = 0;
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            const child = node.child(i) orelse continue;
            const child_kind = child.kind();
            if (std.mem.eql(u8, child_kind, "command") or
                std.mem.eql(u8, child_kind, "redirected_statement"))
            {
                stage_count += 1;
            }
        }
        info.pipeline_length = @max(info.pipeline_length, stage_count);

        // Recurse into pipeline children
        i = 0;
        while (i < node.childCount()) : (i += 1) {
            const child = node.child(i) orelse continue;
            try walkNode(allocator, child, info, source, depth + 1, true);
        }
        return;
    }

    if (std.mem.eql(u8, kind, "command")) {
        const cmd = try extractCommand(allocator, node, source);
        if (std.mem.eql(u8, cmd.name, "eval")) {
            info.has_eval = true;
        }
        try info.commands.append(allocator, cmd);
        if (in_pipeline) {
            const pipeline_cmd = try extractCommand(allocator, node, source);
            try info.pipeline_stages.append(allocator, pipeline_cmd);
        }
        // Still recurse into children to find nested constructs
        // (command_substitution, process_substitution, etc.)
        var ci: u32 = 0;
        while (ci < node.childCount()) : (ci += 1) {
            const child = node.child(ci) orelse continue;
            try walkNode(allocator, child, info, source, depth + 1, false);
        }
        return;
    }

    if (std.mem.eql(u8, kind, "command_substitution")) {
        info.has_command_subst = true;
    } else if (std.mem.eql(u8, kind, "subshell")) {
        info.has_subshell = true;
    } else if (std.mem.eql(u8, kind, "process_substitution")) {
        info.has_process_subst = true;
    } else if (std.mem.eql(u8, kind, "redirected_statement")) {
        info.has_redirection = true;
    } else if (std.mem.eql(u8, kind, "file_redirect") or
        std.mem.eql(u8, kind, "heredoc_redirect"))
    {
        info.has_redirection = true;
    } else if (std.mem.eql(u8, kind, "list")) {
        var i: u32 = 0;
        while (i < node.childCount()) : (i += 1) {
            const child = node.child(i) orelse continue;
            const child_kind = child.kind();
            if (std.mem.eql(u8, child_kind, "&&") or std.mem.eql(u8, child_kind, "||")) {
                try info.logical_operators.append(allocator, child_kind);
            }
        }
    } else if (std.mem.eql(u8, kind, "&")) {
        info.has_background_job = true;
    }

    info.max_nesting_depth = @max(info.max_nesting_depth, depth);

    // Recurse into children
    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const child = node.child(i) orelse continue;
        try walkNode(allocator, child, info, source, depth + 1, in_pipeline);
    }
}

fn extractCommand(allocator: std.mem.Allocator, node: ts.Node, source: []const u8) !SingleCommand {
    var cmd = SingleCommand{ .name = "" };
    var found_name = false;

    var i: u32 = 0;
    while (i < node.childCount()) : (i += 1) {
        const child = node.child(i) orelse continue;
        const child_kind = child.kind();

        // tree-sitter-bash wraps the command name in a "command_name" node
        if (!found_name and std.mem.eql(u8, child_kind, "command_name")) {
            cmd.name = nodeText(child, source);
            found_name = true;
            continue;
        }

        // Fallback: bare "word" as command name (some AST shapes)
        if (!found_name and std.mem.eql(u8, child_kind, "word")) {
            cmd.name = nodeText(child, source);
            found_name = true;
            continue;
        }

        if (!found_name) continue;

        // Arguments: words and string literals after the command name
        if (std.mem.eql(u8, child_kind, "word") or
            std.mem.eql(u8, child_kind, "string") or
            std.mem.eql(u8, child_kind, "raw_string") or
            std.mem.eql(u8, child_kind, "string_content") or
            std.mem.eql(u8, child_kind, "concatenation") or
            std.mem.eql(u8, child_kind, "number"))
        {
            const text = nodeText(child, source);
            try cmd.args.append(allocator, text);

            if (text.len > 0 and text[0] == '-') {
                try cmd.flags.append(allocator, text);
            } else {
                try cmd.positional.append(allocator, text);
            }
        }
    }

    if (!found_name) {
        cmd.name = nodeText(node, source);
    }

    return cmd;
}

fn nodeText(node: ts.Node, source: []const u8) []const u8 {
    const start = node.startByte();
    const end = node.endByte();
    if (start >= source.len or end > source.len or start >= end) return "";
    return source[start..end];
}

// -- Tests --

test "parse simple command" {
    var info = try parse(std.testing.allocator, "grep -r TODO src/");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), info.commands.items.len);
    try std.testing.expectEqualStrings("grep", info.commands.items[0].name);
    try std.testing.expect(info.commands.items[0].hasFlag("-r"));
    try std.testing.expectEqual(@as(usize, 2), info.commands.items[0].positional.items.len);
}

test "parse bare command" {
    var info = try parse(std.testing.allocator, "ls");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), info.commands.items.len);
    try std.testing.expectEqualStrings("ls", info.commands.items[0].name);
    try std.testing.expectEqual(@as(usize, 0), info.commands.items[0].flags.items.len);
}

test "parse pipeline" {
    var info = try parse(std.testing.allocator, "cat file.txt | grep TODO | wc -l");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), info.commands.items.len);
    try std.testing.expectEqualStrings("cat", info.commands.items[0].name);
    try std.testing.expectEqualStrings("grep", info.commands.items[1].name);
    try std.testing.expectEqualStrings("wc", info.commands.items[2].name);
    try std.testing.expectEqual(@as(u32, 3), info.pipeline_length);
    try std.testing.expectEqual(@as(usize, 3), info.pipeline_stages.items.len);
}

test "parse logical operators" {
    var info = try parse(std.testing.allocator, "make && echo done || echo failed");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), info.commands.items.len);
    try std.testing.expectEqualStrings("make", info.commands.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), info.logical_operators.items.len);
}

test "parse command substitution" {
    var info = try parse(std.testing.allocator, "echo $(rm -rf /)");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.has_command_subst);
    try std.testing.expectEqual(@as(usize, 2), info.commands.items.len);
    try std.testing.expectEqualStrings("echo", info.commands.items[0].name);
    try std.testing.expectEqualStrings("rm", info.commands.items[1].name);
}

test "parse subshell" {
    var info = try parse(std.testing.allocator, "(cd /tmp && ls)");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.has_subshell);
}

test "parse redirection" {
    var info = try parse(std.testing.allocator, "echo hello > out.txt");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.has_redirection);
}

test "parse eval" {
    var info = try parse(std.testing.allocator, "eval 'echo hello'");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.has_eval);
    try std.testing.expectEqualStrings("eval", info.commands.items[0].name);
}

test "parse empty command" {
    var info = try parse(std.testing.allocator, "");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), info.commands.items.len);
}

test "parse nested pipeline in command substitution" {
    var info = try parse(std.testing.allocator, "echo $(cat f | grep x)");
    defer info.deinit(std.testing.allocator);

    try std.testing.expect(info.has_command_subst);
    try std.testing.expectEqual(@as(usize, 3), info.commands.items.len);
}

test "parse curl pipe bash" {
    var info = try parse(std.testing.allocator, "curl https://x.com | bash");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), info.commands.items.len);
    try std.testing.expectEqualStrings("curl", info.commands.items[0].name);
    try std.testing.expectEqualStrings("bash", info.commands.items[1].name);
    try std.testing.expectEqual(@as(u32, 2), info.pipeline_length);
    try std.testing.expectEqual(@as(usize, 2), info.pipeline_stages.items.len);
}

test "parse command with flag" {
    var info = try parse(std.testing.allocator, "rm -rf /tmp/build");
    defer info.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), info.commands.items.len);
    try std.testing.expect(info.commands.items[0].hasFlag("-rf"));
}

test "fuzz shell parser never panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            // Feed arbitrary bytes to the parser -- must not panic.
            var info = parse(std.testing.allocator, input) catch return;
            info.deinit(std.testing.allocator);
        }
    }.run, .{});
}
