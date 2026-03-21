# Fuzz Testing

Veer includes fuzz test targets for its most critical code paths. These use
Zig's built-in `std.testing.fuzz()` API.

## Fuzz Targets

| Target | File | What it tests |
|--------|------|---------------|
| Shell parser | `src/engine/shell.zig` | Random bytes fed to `shell.parse()`. Exercises tree-sitter C code with untrusted input. |
| Glob matcher | `src/engine/matcher.zig` | Random pattern + text to `globMatch()`. Tests for infinite loops and panics in backtracking. |
| Regex matcher | `src/engine/matcher.zig` | Random pattern + text to `regexMatch()`. Tests POSIX regex C wrapper with garbage patterns. |

## Running Fuzz Tests

### As regular tests (always works)

The fuzz functions run as part of the normal test suite with trivial input:

```bash
just test    # Runs all 135 tests including fuzz functions
```

### In fuzz mode (coverage-guided mutation)

```bash
just fuzz       # Interactive, runs until Ctrl-C
just fuzz-ci 20 # CI mode, runs for 20 seconds
```

## Current Status: Zig 0.15.x Fuzzer Broken

The `zig build test --fuzz` mode crashes due to known bugs in Zig's stdlib:

- [ziglang/zig#25470](https://github.com/ziglang/zig/issues/25470) -- "zig build test --fuzz stopped working in 0.15.1" (our exact crash)
- [ziglang/zig#26040](https://github.com/ziglang/zig/issues/26040) -- multiple fuzz tests segfault
- [ziglang/zig#20986](https://github.com/ziglang/zig/issues/20986) -- macOS not supported
- [ziglang/zig#25883](https://github.com/ziglang/zig/issues/25883) -- fuzz tests ignored if more tests than CPU threads

The crash is in `Build/Fuzz.zig:429` where LLVM coverage instrumentation produces
empty PC address tables. This likely happens because our vendored C code (tree-sitter,
SQLite, regex wrapper) does not get properly instrumented. There is no workaround --
`FuzzInputOptions` only exposes `corpus`, with no way to disable coverage tracking.

The fuzz test functions are correct and compile fine. They run as regular tests via
`just test`. Only the `--fuzz` mode (coverage-guided mutation) is broken at the Zig
toolchain level.

### macOS

On macOS, `just fuzz` shows an advisory message explaining the limitation. The Zig
fuzzer has additional macOS-specific issues (InvalidElfMagic when loading debug info).

### CI

The CI fuzz step is disabled with a comment referencing this bug. When Zig ships a
fix (expected in 0.16+), uncomment the step in `.github/workflows/ci.yml`:

```yaml
- name: Fuzz (20s smoke test)
  run: timeout 20 zig build test --fuzz; test $? -eq 124
```

## Adding New Fuzz Targets

Follow the existing pattern in `matcher.zig`:

```zig
test "fuzz myFunction never panics" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            // Exercise the function with arbitrary input
            _ = myFunction(input);
        }
    }.run, .{});
}
```

The function signature is `fuzz(context, testOneFn, options)` where:
- `context`: passed to the test function (use `{}` for void)
- `testOneFn`: `fn(context, []const u8) anyerror!void`
- `options`: `FuzzInputOptions` with optional `corpus` field
