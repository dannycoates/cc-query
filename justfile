# Run type checking (JS)
typecheck:
    npm run typecheck

# Run tests (JS)
test:
    @test/test.sh

# Bump version (patch by default, or major|minor|patch)
bump type="patch":
    @scripts/bump.sh {{type}}

# === Rust (ccq) targets ===

duckdb_version := "v1.4.4"
duckdb_src := "duckdb-static/duckdb"
duckdb_lib := "duckdb-static/lib"
duckdb_include := "duckdb-static/include"

# Build ccq binary (requires DuckDB static lib - run setup-duckdb first if needed)
build:
    cd ccq && \
    DUCKDB_LIB_DIR="$(pwd)/../{{duckdb_lib}}" \
    DUCKDB_INCLUDE_DIR="$(pwd)/../{{duckdb_include}}" \
    DUCKDB_STATIC=1 \
    cargo build --release

# Typecheck Rust
check:
    cd ccq && cargo check

# Run Rust unit tests
test-rust:
    cd ccq && cargo test

# Run e2e tests against ccq binary
test-e2e: build
    CC_QUERY="./ccq/target/release/ccq" ./test/test.sh

# Full validation (JS + Rust unit + e2e)
test-all: test test-rust test-e2e

# Benchmark startup time
bench:
    @echo "=== Startup time ===" && \
    for i in 1 2 3; do \
        /usr/bin/time -f "%e sec" ./ccq/target/release/ccq -d test/fixtures <<< "SELECT 1;" 2>&1 | grep sec; \
    done
    @echo "=== Binary size ===" && ls -lh ./ccq/target/release/ccq
    @echo "=== Dependencies ===" && ldd ./ccq/target/release/ccq | grep -E "duckdb|not found" || echo "No DuckDB .so dependency (good!)"

# === DuckDB static library (one-time setup) ===

# Clone and build DuckDB static library (~10 min first time)
setup-duckdb:
    #!/usr/bin/env bash
    set -euo pipefail

    # Clone if needed
    if [ ! -d "{{duckdb_src}}" ]; then
        git clone -b {{duckdb_version}} --depth 1 https://github.com/duckdb/duckdb.git {{duckdb_src}}
    fi

    # Build with minimal extensions
    cd {{duckdb_src}}
    BUILD_EXTENSIONS='json' \
    ENABLE_EXTENSION_AUTOLOADING=0 \
    ENABLE_EXTENSION_AUTOINSTALL=0 \
    GEN=ninja \
    make bundle-library || {
        # Fallback: manually bundle if vcpkg isn't present
        echo "bundle-library failed, creating bundle manually..."
        cd build/release
        rm -rf bundle && mkdir -p bundle
        cp src/libduckdb_static.a bundle/
        cp third_party/*/libduckdb_*.a bundle/ 2>/dev/null || true
        cp extension/*/lib*_extension.a bundle/ 2>/dev/null || true
        cd bundle
        for a in *.a; do
            mkdir -p "${a}.objects"
            mv "$a" "${a}.objects/"
            (cd "${a}.objects" && ar -x "$a")
        done
        ar -rcs libduckdb_bundle.a */*.o
        echo "Bundle created: $(ls -lh libduckdb_bundle.a)"
    }

    # Copy to output directories
    cd {{justfile_directory()}}
    mkdir -p {{duckdb_lib}} {{duckdb_include}}
    cp {{duckdb_src}}/build/release/bundle/libduckdb_bundle.a {{duckdb_lib}}/libduckdb_static.a
    cp {{duckdb_src}}/src/include/duckdb.h {{duckdb_include}}/
    echo "DuckDB static library ready in {{duckdb_lib}}/"

# Clean DuckDB build artifacts (keeps source)
clean-duckdb:
    rm -rf {{duckdb_src}}/build {{duckdb_lib}} {{duckdb_include}}

# Clean everything including DuckDB source
clean-all: clean-duckdb
    rm -rf {{duckdb_src}} ccq/target
