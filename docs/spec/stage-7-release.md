# Implementation Spec: veer - Stage 7: Benchmarks + Release Infrastructure

**Contract**: `docs/spec/contract.md`
**References**: `docs/spec/veer-prd.md` (performance targets), `docs/spec/veer-spec.md` (bench.zig, cross-compilation, CLAUDE.md)
**Depends on**: All previous stages
**Estimated Effort**: M

## Technical Approach

This stage validates performance targets, sets up cross-compilation, CI, documentation, and distribution. It's the final stage before veer is ready for real use.

The benchmark harness (`bench.zig`) runs the check pipeline against a representative set of commands and configs, measuring latency per check. CI enforces that benchmarks don't regress.

## Feedback Strategy

**Inner-loop command**: `zig build bench`
**Playground**: Benchmark harness output + CI pipeline
**Why this approach**: Performance validation requires running the actual benchmark. CI setup is verified by pushing and observing the pipeline.

## File Changes

### New Files

| File Path | Purpose |
|-----------|---------|
| `src/bench.zig` | Benchmark harness: measures check latency and throughput |
| `.github/workflows/ci.yml` | GitHub Actions: test, benchmark, cross-compile |
| `README.md` | Project documentation |
| `LICENSE` | License file (MIT or similar) |
| `.gitignore` | Ignore zig-out/, zig-cache/, .zig-cache/, .veer/ |

### Modified Files

| File Path | Changes |
|-----------|---------|
| `build.zig` | Add benchmark executable and `zig build bench` step. Add cross-compilation step. |
| `CLAUDE.md` | Update with all commands, architecture, and conventions (final version) |
| `Justfile` | Add all convenience recipes (bench, cross, dev-check, vendor-sqlite) |

## Implementation Details

### Benchmark Harness (src/bench.zig)

Follow `docs/spec/veer-spec.md` lines 619-673.

```zig
const std = @import("std");
const Engine = @import("engine/engine.zig").Engine;
const Config = @import("config/config.zig");
const shell = @import("engine/shell.zig");
const MemoryStore = @import("store/memory_store.zig").MemoryStore;

pub fn main() !void {
    const config = try loadBenchConfig(); // Embedded config with ~10-20 rules
    var mem_store = MemoryStore.init(std.heap.page_allocator);
    var engine = Engine.init(std.heap.page_allocator, config);
    engine.store = mem_store.store();

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

    const iterations = 100_000;
    var timer = try std.time.Timer.start();

    for (0..iterations) |_| {
        for (commands) |cmd| {
            _ = engine.check(.{
                .tool_name = "Bash",
                .tool_input = makeToolInput(cmd),
                .session_id = null,
            }) catch {};
        }
    }

    const elapsed_ns = timer.read();
    const total_checks = iterations * commands.len;
    const per_check_ns = elapsed_ns / total_checks;
    const per_check_us = per_check_ns / 1000;

    const stdout = std.io.getStdOut().writer();
    try stdout.print(
        \\Benchmark: {d} checks in {d}ms
        \\Per check: {d}ns ({d}us)
        \\
        \\Targets:
        \\  < 2,000us (2ms) for 10 rules: {s}
        \\  < 5,000us (5ms) for 50 rules: (run separate bench)
        \\
    , .{
        total_checks,
        elapsed_ns / 1_000_000,
        per_check_ns,
        per_check_us,
        if (per_check_us < 2000) "PASS" else "FAIL",
    });

    if (per_check_us >= 2000) std.process.exit(1);
}
```

**Performance targets** (from contract):
- `veer check` with 10 rules: < 2ms
- `veer check` with 50 rules: < 5ms
- Binary size (ReleaseSmall): < 2MB
- JSONL parse rate: > 50,000 lines/sec

### Cross-Compilation (build.zig additions)

From `docs/spec/veer-spec.md` lines 387-407:

```zig
const cross_step = b.step("cross", "Build for all release targets");
const targets: []const std.Target.Query = &.{
    .{ .cpu_arch = .aarch64, .os_tag = .macos },
    .{ .cpu_arch = .x86_64, .os_tag = .macos },
    .{ .cpu_arch = .aarch64, .os_tag = .linux, .abi = .musl },
    .{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl },
};
```

Linux targets use musl for fully static binaries.

### GitHub Actions CI (.github/workflows/ci.yml)

```yaml
name: CI
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
        with:
          version: master  # or specific stable version
      - run: zig build test
      - run: zig build bench
      - name: Check binary size
        run: |
          zig build -Doptimize=ReleaseSmall
          size=$(stat -c%s zig-out/bin/veer 2>/dev/null || stat -f%z zig-out/bin/veer)
          echo "Binary size: $size bytes"
          if [ "$size" -gt 2097152 ]; then echo "FAIL: > 2MB"; exit 1; fi

  cross:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: goto-bus-stop/setup-zig@v2
      - run: zig build cross
```

### README.md

Cover:
- What veer is (one paragraph)
- Installation (Homebrew, direct download, build from source)
- Quick start (install hook, add first rule, see it work)
- Configuration (link to config format, example config)
- Commands (brief description of each)
- Performance (benchmark results)
- License

### Justfile (final version)

From `docs/spec/veer-spec.md` lines 437-475:

```justfile
default: test

test:
    zig build test

build:
    zig build

release:
    zig build -Doptimize=ReleaseSmall

cross:
    zig build cross

bench:
    zig build bench

dev-check:
    echo '{"tool_name":"Bash","tool_input":{"command":"pytest tests/ -v"}}' | zig build run -- check

clean:
    rm -rf zig-out/ zig-cache/ .zig-cache/
```

### CLAUDE.md (final version)

Update with complete information per `docs/spec/veer-spec.md` lines 989-1033. Include all build commands, architecture overview, key conventions, and just recipes.

### .gitignore

```
zig-out/
zig-cache/
.zig-cache/
.veer/veer.db
```

## Testing Requirements

### Benchmark Tests
- Benchmark completes without errors
- Per-check latency < 2ms (10 rules) -- CI enforces this
- Binary size < 2MB (ReleaseSmall) -- CI enforces this

### Cross-Compilation Tests
- `zig build cross` succeeds for all 4 targets
- Produced binaries are valid (correct architecture headers)

### Manual Testing
- [ ] Build release binary: `zig build -Doptimize=ReleaseSmall`
- [ ] Verify binary size: `ls -la zig-out/bin/veer`
- [ ] Run full workflow: install -> add rule -> check (via piped JSON) -> list -> stats -> remove -> uninstall
- [ ] Cross-compile: `zig build cross`
- [ ] Run benchmark: `zig build bench`

## Error Handling

| Scenario | Handling |
|----------|----------|
| Benchmark exceeds target | Exit 1 (CI failure) |
| Cross-compilation failure | CI reports which target failed |
| Binary size exceeds 2MB | CI failure |

## Validation Commands

```bash
# Run all tests
zig build test

# Run benchmarks
zig build bench

# Build optimized
zig build -Doptimize=ReleaseSmall

# Check binary size
ls -la zig-out/bin/veer

# Cross-compile
zig build cross

# Full integration test
echo '{"tool_name":"Bash","tool_input":{"command":"pytest tests/"}}' | ./zig-out/bin/veer check
```

## Open Items

- [ ] Homebrew formula -- create a tap repository or submit to homebrew-core
- [ ] Release automation -- GitHub Actions workflow for creating releases with cross-compiled binaries
- [ ] License choice (MIT recommended for CLI tools)
