default: test

# Run all tests
test:
    zig build test

# Build debug binary
build:
    zig build

# Clean build artifacts
clean:
    rm -rf zig-out/ zig-cache/ .zig-cache/
