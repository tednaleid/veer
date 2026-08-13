// ABOUTME: Add a rule to the veer config file via CLI flags.
// ABOUTME: Appends a [[rule]] TOML block to the config file.

const std = @import("std");
const rule_mod = @import("../config/rule.zig");

pub const AddOptions = struct {
    action: ?[]const u8 = null,
    command: ?[]const u8 = null,
    path: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    message: ?[]const u8 = null,
    rewrite_to: ?[]const u8 = null,
    config_path: []const u8 = ".veer/config.toml",
};

/// Run the add command. Appends a rule to the config file.
pub fn run(parent_allocator: std.mem.Allocator, io: std.Io, opts: AddOptions, writer: anytype) !u8 {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const action_str = opts.action orelse {
        try writer.print("veer add: --action is required (allow, reject, rewrite)\n", .{});
        return 1;
    };

    // Validate action
    const action = std.meta.stringToEnum(rule_mod.Action, action_str) orelse {
        try writer.print("veer add: invalid action '{s}' (must be allow, reject, or rewrite)\n", .{action_str});
        return 1;
    };

    if (opts.command != null and opts.path != null) {
        try writer.print("veer add: --command and --path are mutually exclusive\n", .{});
        return 1;
    }
    if (opts.command == null and opts.path == null) {
        try writer.print("veer add: --command or --path is required\n", .{});
        return 1;
    }
    // allow's match block is an allowlist; it never accepts a command
    // matcher (see rule_mod.ValidationError.AllowRequiresPathOrContent).
    if (action == .allow and opts.command != null) {
        try writer.print("veer add: allow rules take a path (--path), not a command -- allow only matches path or content, never command\n", .{});
        return 1;
    }
    // rewrite replaces a Bash command; --path targets tools that carry no
    // command field (see rule_mod.ValidationError.RewriteRequiresCommand).
    if (action == .rewrite and opts.path != null) {
        try writer.print("veer add: rewrite rules take a command (--command), not a path -- rewrite only applies to tools with a command field\n", .{});
        return 1;
    }

    // Rewrite requires --rewrite-to
    if (action == .rewrite and opts.rewrite_to == null) {
        try writer.print("veer add: --rewrite-to is required for rewrite rules\n", .{});
        return 1;
    }
    // Reject and allow require --message
    if ((action == .reject or action == .allow) and opts.message == null) {
        try writer.print("veer add: --message is required for reject and allow rules\n", .{});
        return 1;
    }

    // Auto-generate id and name if not provided
    const id = opts.id orelse try autoId(allocator, action, opts.command, opts.path);
    const name_str = opts.name orelse try autoName(allocator, action, opts.command, opts.path);

    // Format TOML block
    var toml_buf: std.Io.Writer.Allocating = .init(allocator);
    defer toml_buf.deinit();
    const w = &toml_buf.writer;

    try w.print("\n[[rule]]\n", .{});
    try w.print("id = \"{s}\"\n", .{id});
    try w.print("name = \"{s}\"\n", .{name_str});
    try w.print("action = \"{s}\"\n", .{action_str});
    if (opts.message) |m| {
        try w.print("message = \"{s}\"\n", .{m});
    }
    if (opts.rewrite_to) |r| {
        try w.print("rewrite_to = \"{s}\"\n", .{r});
    }
    if (opts.tool) |t| {
        try w.print("tool = \"{s}\"\n", .{t});
    } else if (opts.path != null) {
        // Bash (the struct default) carries no path field, so a --path rule
        // needs an explicit tool. Write and Edit are the two tools most
        // likely to need a path gate; --tool reaches anything else.
        try w.print("tool_any = [\"Write\", \"Edit\"]\n", .{});
    }
    try w.print("[rule.match]\n", .{});
    if (opts.command) |c| {
        try w.print("command = \"{s}\"\n", .{c});
    } else if (opts.path) |p| {
        try w.print("path = \"{s}\"\n", .{p});
    }

    // Ensure config directory exists
    if (std.mem.lastIndexOfScalar(u8, opts.config_path, '/')) |sep| {
        std.Io.Dir.cwd().createDirPath(io, opts.config_path[0..sep]) catch {};
    }

    // Append to config file
    const file = std.Io.Dir.cwd().createFile(io, opts.config_path, .{
        .truncate = false,
    }) catch |err| {
        try writer.print("veer add: cannot open {s}: {}\n", .{ opts.config_path, err });
        return 1;
    };
    defer file.close(io);
    const end = (try file.stat(io)).size;
    try file.writePositionalAll(io, toml_buf.written(), end);

    try writer.print("Added rule '{s}' to {s}\n", .{ id, opts.config_path });
    return 0;
}

fn actionIdPrefix(action: rule_mod.Action) []const u8 {
    return switch (action) {
        .rewrite => "use",
        .reject => "reject",
        .allow => "allow",
    };
}

fn actionVerb(action: rule_mod.Action) []const u8 {
    return switch (action) {
        .rewrite => "Redirect",
        .reject => "Reject",
        .allow => "Allow",
    };
}

/// `command` and `path` are mutually exclusive per `run`'s validation, but
/// both are threaded through here so a path rule gets a slugified id instead
/// of one built from an unsanitized glob.
fn autoId(allocator: std.mem.Allocator, action: rule_mod.Action, command: ?[]const u8, path: ?[]const u8) ![]const u8 {
    const prefix = actionIdPrefix(action);
    if (path) |p| {
        const slug = try slugify(allocator, p);
        return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, slug });
    }
    return try std.fmt.allocPrint(allocator, "{s}-{s}", .{ prefix, command.? });
}

fn autoName(allocator: std.mem.Allocator, action: rule_mod.Action, command: ?[]const u8, path: ?[]const u8) ![]const u8 {
    const verb = actionVerb(action);
    const target = path orelse command.?;
    return try std.fmt.allocPrint(allocator, "{s} {s}", .{ verb, target });
}

/// Reduce a path glob to an identifier-safe slug: word characters pass
/// through, runs of everything else (`/`, `*`, `.`, `{`, `,`, `}`, ...)
/// collapse to a single `-`, and leading/trailing `-` are trimmed. Falls
/// back to "path" when nothing word-like survives (e.g. a bare "**").
fn slugify(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf = std.ArrayListUnmanaged(u8).empty;
    defer buf.deinit(allocator);
    for (s) |c| {
        const is_word = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        if (is_word) {
            try buf.append(allocator, c);
        } else if (buf.items.len > 0 and buf.items[buf.items.len - 1] != '-') {
            try buf.append(allocator, '-');
        }
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == '-') _ = buf.pop();
    if (buf.items.len == 0) return try allocator.dupe(u8, "path");
    return try buf.toOwnedSlice(allocator);
}

// -- Tests --

test "add rewrite rule appends TOML" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{path});
    defer std.testing.allocator.free(config_path);

    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const exit_code = try run(std.testing.allocator, std.testing.io, .{
        .action = "rewrite",
        .command = "pytest",
        .rewrite_to = "just test",
        .message = "Use just test.",
        .config_path = config_path,
    }, &stream);

    try std.testing.expectEqual(@as(u8, 0), exit_code);

    // Verify TOML was written
    const content = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, config_path, std.testing.allocator, .limited(4096));
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "[[rule]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "pytest") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "rewrite") != null);
}

test "add without required action fails" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const exit_code = try run(std.testing.allocator, std.testing.io, .{
        .command = "pytest",
    }, &stream);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
}

test "add rewrite without rewrite-to fails" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const exit_code = try run(std.testing.allocator, std.testing.io, .{
        .action = "rewrite",
        .command = "pytest",
    }, &stream);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
}

const config_mod = @import("../config/config.zig");

test "add allow rule with --path produces a config that loads and validates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{path});
    defer std.testing.allocator.free(config_path);

    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const exit_code = try run(std.testing.allocator, std.testing.io, .{
        .action = "allow",
        .path = "src/**",
        .message = "Stay under src.",
        .config_path = config_path,
    }, &stream);

    try std.testing.expectEqual(@as(u8, 0), exit_code);

    // loadFile runs the same rule_mod.validate the "veer validate" and
    // "veer check" commands do -- a load error here reproduces the bug.
    var parsed = try config_mod.loadFile(std.testing.allocator, std.testing.io, config_path);
    defer parsed.deinit();

    try std.testing.expectEqual(@as(usize, 1), parsed.value.rule.len);
    const rule = parsed.value.rule[0];
    try std.testing.expectEqual(rule_mod.Action.allow, rule.action.?);
    try std.testing.expectEqualStrings("src/**", rule.match.path.?);
    try std.testing.expectEqualStrings("Write", rule.tool_any.?[0]);
    try std.testing.expectEqualStrings("Edit", rule.tool_any.?[1]);
}

test "add allow rule with --command fails with a clear message and writes nothing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{path});
    defer std.testing.allocator.free(config_path);

    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const exit_code = try run(std.testing.allocator, std.testing.io, .{
        .action = "allow",
        .command = "git",
        .message = "only git",
        .config_path = config_path,
    }, &stream);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    const output = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "allow rules take a path") != null);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, config_path, .{}));
}

test "add with --command and --path together fails" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const exit_code = try run(std.testing.allocator, std.testing.io, .{
        .action = "reject",
        .command = "git",
        .path = "src/**",
        .message = "m",
    }, &stream);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    const output = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "mutually exclusive") != null);
}

test "add rewrite rule with --path fails, since rewrite needs a command matcher" {
    var buf: [256]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const exit_code = try run(std.testing.allocator, std.testing.io, .{
        .action = "rewrite",
        .path = "src/**",
        .rewrite_to = "noop",
    }, &stream);

    try std.testing.expectEqual(@as(u8, 1), exit_code);
    const output = stream.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "rewrite rules take a command") != null);
}

test "add with --path and no --tool defaults id to a slug of the path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{path});
    defer std.testing.allocator.free(config_path);

    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    _ = try run(std.testing.allocator, std.testing.io, .{
        .action = "allow",
        .path = "src/**",
        .message = "m",
        .config_path = config_path,
    }, &stream);

    try std.testing.expect(std.mem.indexOf(u8, stream.buffered(), "Added rule 'allow-src' to ") != null);
}

test "add with --path and --tool overrides the default tool_any" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{path});
    defer std.testing.allocator.free(config_path);

    var buf: [1024]u8 = undefined;
    var stream = std.Io.Writer.fixed(&buf);

    const exit_code = try run(std.testing.allocator, std.testing.io, .{
        .action = "reject",
        .path = "**/*.env",
        .tool = "Read",
        .message = "m",
        .config_path = config_path,
    }, &stream);
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    var parsed = try config_mod.loadFile(std.testing.allocator, std.testing.io, config_path);
    defer parsed.deinit();
    const rule = parsed.value.rule[0];
    try std.testing.expectEqualStrings("Read", rule.tool);
    try std.testing.expect(rule.tool_any == null);
}
