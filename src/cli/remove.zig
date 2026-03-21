// ABOUTME: Remove a rule by ID from the veer config file.
// ABOUTME: Line-based removal to preserve TOML comments and formatting.

const std = @import("std");

/// Run the remove command. Removes a [[rule]] block with matching id.
pub fn run(allocator: std.mem.Allocator, rule_id: []const u8, config_path: []const u8, writer: anytype) !u8 {
    const content = std.fs.cwd().readFileAlloc(allocator, config_path, 1024 * 1024) catch {
        try writer.print("veer remove: cannot read {s}\n", .{config_path});
        return 1;
    };
    defer allocator.free(content);

    // Find the [[rule]] block with matching id and remove it
    var result = std.ArrayListUnmanaged(u8).empty;
    defer result.deinit(allocator);
    const w = result.writer(allocator);

    var in_target_rule = false;
    var found = false;

    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");

        if (std.mem.eql(u8, trimmed, "[[rule]]")) {
            if (in_target_rule) {
                // End of target rule, start of new rule -- keep this line
                in_target_rule = false;
            }
            // Look ahead: check if the next few lines contain our rule_id
            // We'll handle this by marking when we see the id line
        }

        if (in_target_rule) continue; // Skip lines in the target rule

        // Check if this is the start of our target rule
        if (std.mem.eql(u8, trimmed, "[[rule]]")) {
            // Peek at upcoming lines to see if this rule has the target ID
            var peek = lines;
            var is_target = false;
            var peek_count: usize = 0;
            while (peek.next()) |peek_line| {
                peek_count += 1;
                if (peek_count > 20) break; // Don't look too far ahead
                const pt = std.mem.trim(u8, peek_line, " \t\r");
                if (std.mem.startsWith(u8, pt, "id = ")) {
                    // Extract the id value
                    const id_val = extractTomlString(pt["id = ".len..]);
                    if (std.mem.eql(u8, id_val, rule_id)) {
                        is_target = true;
                    }
                    break;
                }
                if (std.mem.eql(u8, pt, "[[rule]]")) break; // Hit another rule
            }

            if (is_target) {
                in_target_rule = true;
                found = true;
                continue; // Skip the [[rule]] line
            }
        }

        try w.print("{s}\n", .{line});
    }

    if (!found) {
        try writer.print("veer remove: rule '{s}' not found in {s}\n", .{ rule_id, config_path });
        return 1;
    }

    // Write back
    const file = try std.fs.cwd().createFile(config_path, .{});
    defer file.close();
    try file.writeAll(result.items);

    try writer.print("Removed rule '{s}' from {s}\n", .{ rule_id, config_path });
    return 0;
}

fn extractTomlString(s: []const u8) []const u8 {
    // Extract string value from TOML: "value" -> value
    const trimmed = std.mem.trim(u8, s, " \t");
    if (trimmed.len >= 2 and trimmed[0] == '"' and trimmed[trimmed.len - 1] == '"') {
        return trimmed[1 .. trimmed.len - 1];
    }
    return trimmed;
}

// -- Tests --

test "remove existing rule" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{path});
    defer std.testing.allocator.free(config_path);

    // Write a config with two rules
    const config_content =
        \\[settings]
        \\stats = true
        \\
        \\[[rule]]
        \\id = "keep-this"
        \\name = "Keep"
        \\action = "warn"
        \\message = "kept"
        \\[rule.match]
        \\command = "foo"
        \\
        \\[[rule]]
        \\id = "remove-this"
        \\name = "Remove"
        \\action = "deny"
        \\message = "removed"
        \\[rule.match]
        \\command = "bar"
    ;
    const file = try std.fs.cwd().createFile(config_path, .{});
    try file.writeAll(config_content);
    file.close();

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const exit_code = try run(std.testing.allocator, "remove-this", config_path, stream.writer());
    try std.testing.expectEqual(@as(u8, 0), exit_code);

    // Verify the rule was removed
    const result = try std.fs.cwd().readFileAlloc(std.testing.allocator, config_path, 4096);
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "keep-this") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "remove-this") == null);
}

test "remove nonexistent rule fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(path);
    const config_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config.toml", .{path});
    defer std.testing.allocator.free(config_path);

    const file = try std.fs.cwd().createFile(config_path, .{});
    try file.writeAll("[settings]\nstats = true\n");
    file.close();

    var buf: [512]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);

    const exit_code = try run(std.testing.allocator, "nonexistent", config_path, stream.writer());
    try std.testing.expectEqual(@as(u8, 1), exit_code);
}
