# Run type checking
typecheck:
    npm run typecheck

# Run tests
test:
    @test/test.sh

# Bump version (patch by default, or major|minor|patch)
bump type="patch":
    @scripts/bump.sh {{type}}

# === Rust (ccq) targets ===

# Build Rust binary
build-rust:
    cd ccq && cargo build --release

# Typecheck Rust
typecheck-rust:
    cd ccq && cargo check

# Run Rust unit tests
test-rust:
    cd ccq && cargo test

# Run bash e2e tests against Rust binary
test-rust-e2e: build-rust
    CC_QUERY="./ccq/target/release/ccq" ./test/test.sh

# Full validation of both implementations
test-all: test test-rust test-rust-e2e
