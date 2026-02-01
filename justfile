# Run type checking
typecheck:
    npm run typecheck

# Run tests
test:
    @test/test.sh

# Bump version (patch by default, or major|minor|patch)
bump type="patch":
    @scripts/bump.sh {{type}}

# Build Zig version
zig-build:
    cd zig && zig build

# Run Zig tests
zig-test: zig-build
    @test/test-zig.sh

# Build Zig release version
zig-release:
    cd zig && zig build -Doptimize=ReleaseFast

# Run all tests (Node.js and Zig)
test-all: test zig-test
