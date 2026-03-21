const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -- Dependencies --

    const ts_dep = b.dependency("zig-tree-sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });

    // -- Main executable --

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    exe_mod.addImport("tree_sitter", ts_dep.module("tree_sitter"));
    exe_mod.addImport("toml", toml_dep.module("toml"));

    const exe = b.addExecutable(.{
        .name = "veer",
        .root_module = exe_mod,
    });

    // SQLite amalgamation (vendored)
    exe.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/sqlite3.c"),
        .flags = &.{
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_WAL_SYNCHRONOUS=1",
            "-DSQLITE_THREADSAFE=1",
            "-DSQLITE_TEMP_STORE=3",
            "-DSQLITE_OMIT_LOAD_EXTENSION=1",
            "-DSQLITE_OMIT_DEPRECATED=1",
            "-DSQLITE_OMIT_TRACE=1",
            "-DSQLITE_OMIT_SHARED_CACHE",
        },
    });
    exe.addIncludePath(b.path("vendor/sqlite3"));

    // tree-sitter-bash grammar (vendored C sources)
    exe.addCSourceFiles(.{
        .root = b.path("vendor/tree-sitter-bash/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{"-std=c11"},
    });
    exe.addIncludePath(b.path("vendor/tree-sitter-bash/src"));

    // POSIX regex wrapper (vendored C, avoids opaque regex_t issue on Linux)
    exe.addCSourceFile(.{
        .file = b.path("vendor/regex/veer_regex.c"),
        .flags = &.{},
    });
    exe.addIncludePath(b.path("vendor/regex"));

    b.installArtifact(exe);

    // -- Run command --

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run veer");
    run_step.dependOn(&run_cmd.step);

    // -- Tests --

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/test_all.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    test_mod.addImport("tree_sitter", ts_dep.module("tree_sitter"));
    test_mod.addImport("toml", toml_dep.module("toml"));

    const t = b.addTest(.{ .root_module = test_mod });

    t.addCSourceFile(.{
        .file = b.path("vendor/sqlite3/sqlite3.c"),
        .flags = &.{ "-DSQLITE_DQS=0", "-DSQLITE_THREADSAFE=1" },
    });
    t.addIncludePath(b.path("vendor/sqlite3"));

    t.addCSourceFiles(.{
        .root = b.path("vendor/tree-sitter-bash/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{"-std=c11"},
    });
    t.addIncludePath(b.path("vendor/tree-sitter-bash/src"));

    t.addCSourceFile(.{
        .file = b.path("vendor/regex/veer_regex.c"),
        .flags = &.{},
    });
    t.addIncludePath(b.path("vendor/regex"));

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(t).step);

    // -- Benchmarks --

    const bench_mod = b.createModule(.{
        .root_source_file = b.path("src/bench.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    bench_mod.addImport("tree_sitter", ts_dep.module("tree_sitter"));

    const bench_exe = b.addExecutable(.{
        .name = "veer-bench",
        .root_module = bench_mod,
    });

    bench_exe.addCSourceFiles(.{
        .root = b.path("vendor/tree-sitter-bash/src"),
        .files = &.{ "parser.c", "scanner.c" },
        .flags = &.{"-std=c11"},
    });
    bench_exe.addIncludePath(b.path("vendor/tree-sitter-bash/src"));

    bench_exe.addCSourceFile(.{
        .file = b.path("vendor/regex/veer_regex.c"),
        .flags = &.{},
    });
    bench_exe.addIncludePath(b.path("vendor/regex"));

    const bench_run = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Run benchmarks");
    bench_step.dependOn(&bench_run.step);
}
