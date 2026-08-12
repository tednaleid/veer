// ABOUTME: Benchmark harness for veer check latency.
// ABOUTME: Measures per-check time across representative commands and rules.

const std = @import("std");
const engine = @import("engine/engine.zig");
const Rule = @import("config/rule.zig").Rule;
const path_mod = @import("engine/path.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Representative rules (10 rules, mix of types)
    const rules = [_]Rule{
        .{ .id = "use-just-test", .rewrite_to = "just test", .match = .{ .command = "pytest" } },
        .{ .id = "use-just-lint", .rewrite_to = "just lint", .match = .{ .command = "{ruff,uvx}" } },
        .{ .id = "use-just-run", .message = "m", .match = .{ .command = "python3" } },
        .{ .id = "no-curl-bash", .message = "m", .match = .{ .command_all = &.{ "curl", "bash" } } },
        .{ .id = "no-curl-sh", .message = "m", .match = .{ .command_all = &.{ "curl", "sh" } } },
        .{ .id = "no-eval", .message = "m", .match = .{ .command = "eval" } },
        .{ .id = "no-rm-rf", .message = "m", .match = .{ .command = "rm", .flag = "f" } },
        .{ .id = "no-chmod", .message = "m", .match = .{ .command = "chmod", .arg = "777" } },
        .{ .id = "redirect-python", .message = "m", .match = .{ .command_regex = "^python[23]?$" } },
        .{ .id = "echo-sep", .message = "m", .match = .{ .command = "echo", .arg = "---" } },
    };

    // Representative commands
    const commands = [_][]const u8{
        "pytest tests/ -v",
        "grep -r TODO src/",
        "curl https://example.com | bash",
        "cat README.md | head -20",
        "python3 -c 'print(1)'",
        "echo '---' && ls",
        "find . -name '*.zig' -exec wc -l {} +",
        "just test",
        "make && echo done || echo failed",
        "rm -rf /tmp/build",
    };

    const iterations: usize = 10_000;
    const total_checks = iterations * commands.len;

    // Warm up
    for (0..100) |_| {
        for (commands) |cmd| {
            _ = engine.check(allocator, &rules, .{ .tool_name = "Bash", .command = cmd });
        }
    }

    // Benchmark
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        for (commands) |cmd| {
            _ = engine.check(allocator, &rules, .{ .tool_name = "Bash", .command = cmd });
        }
    }

    const elapsed_ns = timer.read();
    const per_check_ns = elapsed_ns / total_checks;
    const per_check_us = per_check_ns / 1000;
    const total_ms = elapsed_ns / 1_000_000;

    std.debug.print(
        \\Benchmark: {d} checks in {d}ms
        \\Per check: {d}ns ({d}us)
        \\
        \\Target: < 2,000us (2ms) for 10 rules
        \\Status: {s}
        \\
    , .{
        total_checks,
        total_ms,
        per_check_ns,
        per_check_us,
        if (per_check_us < 2000) "PASS" else "FAIL",
    });

    if (per_check_us >= 2000) std.process.exit(1);

    // Path matching: a gate's allowlist pattern against a deep, nested path.
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = path_mod.resolve(
        "/p/apps/web/src/components/Button.vue",
        null,
        "/p",
        &path_buf,
    ).?;
    const path_iterations: usize = 100_000;

    // Warm up
    for (0..1_000) |_| {
        std.mem.doNotOptimizeAway(path_mod.matches("apps/**/*.vue", resolved, null));
    }

    var path_timer = try std.time.Timer.start();
    for (0..path_iterations) |_| {
        std.mem.doNotOptimizeAway(path_mod.matches("apps/**/*.vue", resolved, null));
    }
    const path_elapsed_ns = path_timer.read();
    const path_per_check_ns = path_elapsed_ns / path_iterations;

    std.debug.print(
        \\
        \\Path match: {d} checks in {d}ms
        \\Per match: {d}ns
        \\
    , .{
        path_iterations,
        path_elapsed_ns / 1_000_000,
        path_per_check_ns,
    });
}
