default: test

# Run all tests
test:
    zig build test

# Run all tests with summary
test-summary:
    zig build test --summary all

# Build debug binary
build:
    zig build

# Clean build artifacts
clean:
    rm -rf zig-out/ zig-cache/ .zig-cache/
