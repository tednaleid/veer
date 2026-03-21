// ABOUTME: Add a rule to the veer config file via CLI flags.
// ABOUTME: Appends a [[rule]] TOML block to the config file.

const std = @import("std");
const rule_mod = @import("../config/rule.zig");

pub const AddOptions = struct {
    action: ?[]const u8 = null,
    command: ?[]const u8 = null,
    id: ?[]const u8 = null,
    name: ?[]const u8 = null,
    message: ?[]const u8 = null,
    rewrite_to: ?[]const u8 = null,
    priority: ?[]const u8 = null,
    config_path: []const u8 = ".veer/config.toml",
};

/// Run the add command. Appends a rule to the config file.
pub fn run(parent_allocator: std.mem.Allocator, opts: AddOptions, writer: anytype) !u8 {
    var arena = std.heap.ArenaAllocator.init(parent_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const action_str = opts.action orelse {
        try writer.print("veer add: --action is required (rewrite, warn, deny)\n", .{});
        return 1;
    };
    const command = opts.command orelse {
        try writer.print("veer add: --command is required\n", .{});
        return 1;
    };

    // Validate action
    const action = std.meta.stringToEnum(rule_mod.Action, action_str) orelse {
        try writer.print("veer add: invalid action '{s}' (must be rewrite, warn, or deny)\n", .{action_str});
        return 1;
    };

    // Rewrite requires --rewrite-to
    if (action == .rewrite and opts.rewrite_to == null) {
        try writer.print("veer add: --rewrite-to is required for rewrite rules\n", .{});
        return 1;
    }
    // Warn/deny requires --message
    if ((action == .warn or action == .deny) and opts.message == null) {
        try writer.print("veer add: --message is required for warn/deny rules\n", .{});
        return 1;
    }

    // Auto-generate id and name if not provided
    const id = opts.id orelse try autoId(allocator, action_str, command);
    const name_str = opts.name orelse try autoName(allocator, action_str, command);

    // Format TOML block
    var toml_buf = std.ArrayListUnmanaged(u8).empty;
    defer toml_buf.deinit(allocator);
    const w = toml_buf.writer(allocator);

    try w.print("\n[[rule]]\n", .{});
    try w.print("id = \"{s}\"\n", .{id});
    try w.print("name = \"{s}\"\n", .{name_str});
    try w.print("action = \"{s}\"\n", .{action_str});
    if (opts.priority) |p| {
        try w.print("priority = {s}\n", .{p});
    }
    if (opts.message) |m| {
        try w.print("message = \"{s}\"\n", .{m});
    }
    if (opts.rewrite_to) |r| {
        try w.print("rewrite_to = \"{s}\"\n", .{r});
    }
    try w.print("[rule.match]\n", .{});
    try w.print("command = \"{s}\"\n", .{command});

    // Ensure config directory exists
    if (std.mem.lastIndexOfScalar(u8, opts.config_path, '/')) |sep| {
        std.fs.cwd().makePath(opts.config_path[0..sep]) catch {};
    }

    // Append to config file
    const file = std.fs.cwd().createFile(opts.config_path, .{
        .truncate = false,
    }) catch |err| {
        try writer.print("veer add: cannot open {s}: {}\n", .{ opts.config_path, err });
        return 1;
    };
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(toml_buf.items);

    try writer.print("Added rule '{s}' to {s}\n", .{ id, opts.config_path });
    return 0;
}

fn autoId(allocator: std.mem.Allocator, action: []const u8, command: []const u8) ![]const u8 {
    return switch (std.meta.stringToEnum(rule_mod.Action, action) orelse return "custom-rule") {
        .rewrite => try std.fmt.allocPrint(allocator, "use-{s}", .{command}),
        .warn => try std.fmt.allocPrint(allocator, "warn-{s}", .{command}),
        .deny => try std.fmt.allocPrint(allocator, "no-{s}", .{command}),
    };
}

fn autoName(allocator: std.mem.Allocator, action: []const u8, command: []const u8) ![]const u8 {
    return switch (std.meta.stringToEnum(rule_mod.Action, action) orelse return "Custom rule") {
        .rewrite => try std.fmt.allocPrint(allocator, "Redirect {s}", .{command}),
        .warn => try std.fmt.allocPrint(allocator, "Warn about {s}", .{command}),
        .deny => try std.fmt.allocPrint(allocator, "Block {s}", .{command}),
    };
}

// -- Tests --

test "add rewrite rule appends TOML" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{path});
    defer std.testing.allocator.free(config_path);

    var buf: [1024]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const exit_code = try run(std.testing.allocator, .{
        .action = "rewrite",
        .command = "pytest",
        .rewrite_to = "just test",
        .message = "Use just test.",
        .config_path = config_path,
    }, stream.writer());

    try std.testing.expectEqual(@as(u8, 0), exit_code);

    // Verify TOML was written
    const file = try std.fs.cwd().openFile(config_path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(std.testing.allocator, 4096);
    defer std.testing.allocator.free(content);

    try std.testing.expect(std.mem.indexOf(u8, content, "[[rule]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "pytest") != null);
    try std.testing.expect(std.mem.indexOf(u8, content, "rewrite") != null);
}

test "add without required action fails" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const exit_code = try run(std.testing.allocator, .{
        .command = "pytest",
    }, stream.writer());

    try std.testing.expectEqual(@as(u8, 1), exit_code);
}

test "add rewrite without rewrite-to fails" {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const exit_code = try run(std.testing.allocator, .{
        .action = "rewrite",
        .command = "pytest",
    }, stream.writer());

    try std.testing.expectEqual(@as(u8, 1), exit_code);
}
