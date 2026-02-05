# Plan: Build DuckDB as Static Library for Rust CCQ

## Goal
Replace the slow `bundled` DuckDB build with a pre-built `libduckdb_bundle.a` static library to achieve faster startup while maintaining single-binary distribution.

**Current state**: Bundled build = 35MB binary, 75ms/360ms CPU startup
**Target**: Match external .so performance (~29ms startup) with static linking

---

## Why This Should Work

The performance difference is due to **how** DuckDB is compiled:

| Build Method | Build Tool | Startup | CPU Time |
|--------------|------------|---------|----------|
| libduckdb-sys `bundled` | cc crate | 75ms | 360ms |
| Official releases (.so) | CMake + ninja | 29ms | 23ms |

The `cc` crate builds each source file individually without CMake's project-wide optimization knowledge, cross-module inlining, or sophisticated build configuration.

**`make bundle-library` uses CMake**, so our static build should have the same performance as the official .so releases.

---

## Extensions Analysis

cc-query only uses these DuckDB features:
- **`read_ndjson()`** - core function (not an extension)
- **JSON operators** (`->`, `->>`, `json_extract_string`) - requires `json` extension
- Standard SQL (aggregates, window functions, CTEs, etc.) - core

**Not used**: parquet, icu, httpfs, autocomplete, tpch, etc.

**Minimal build flags**:
```bash
BUILD_EXTENSIONS='json'           # Only json extension
ENABLE_EXTENSION_AUTOLOADING=0    # No runtime extension loading
ENABLE_EXTENSION_AUTOINSTALL=0    # No auto-install attempts
```

This should produce a smaller, faster binary than the default build.

---

## Directory Structure

```
/home/danny/code/cc-query/rusty/
├── ccq/                    # Rust project
├── duckdb-static/          # NEW: Static library build
│   ├── duckdb/             # DuckDB source (cloned)
│   ├── lib/                # Built libduckdb_static.a
│   └── include/            # duckdb.h header
└── justfile
```

---

## Implementation Steps

### 1. Update Cargo.toml
**File**: `/home/danny/code/cc-query/rusty/ccq/Cargo.toml`

Remove `bundled` feature:
```toml
# Change from:
duckdb = { version = "1.4", features = ["bundled"] }
# To:
duckdb = "1.4"
```

Then clean the cargo cache to remove bundled build artifacts:
```bash
cd ccq && cargo clean
```

### 2. Create build.rs for Linker Flags
**File**: `/home/danny/code/cc-query/rusty/ccq/build.rs` (NEW)

```rust
fn main() {
    if std::env::var("DUCKDB_STATIC").is_ok() {
        println!("cargo:rustc-link-lib=stdc++");
        println!("cargo:rustc-link-lib=pthread");
        println!("cargo:rustc-link-lib=dl");
        println!("cargo:rustc-link-lib=m");
        println!("cargo:rustc-link-lib=z");
    }
}
```

### 3. Add justfile Targets
**File**: `/home/danny/code/cc-query/rusty/justfile`

Add these targets:

```just
# === DuckDB static library targets ===

duckdb_version := "v1.4.4"
duckdb_static_dir := "duckdb-static"
duckdb_src := duckdb_static_dir / "duckdb"
duckdb_lib := duckdb_static_dir / "lib"
duckdb_include := duckdb_static_dir / "include"

# Clone DuckDB source (one-time)
setup-duckdb:
    @if [ ! -d "{{duckdb_src}}" ]; then \
        git clone -b {{duckdb_version}} --depth 1 https://github.com/duckdb/duckdb.git {{duckdb_src}}; \
    fi

# Build libduckdb_bundle.a from source (minimal: json only, no autoload)
build-duckdb: setup-duckdb
    cd {{duckdb_src}} && \
    BUILD_EXTENSIONS='json' \
    ENABLE_EXTENSION_AUTOLOADING=0 \
    ENABLE_EXTENSION_AUTOINSTALL=0 \
    GEN=ninja \
    make bundle-library
    mkdir -p {{duckdb_lib}} {{duckdb_include}}
    cp {{duckdb_src}}/build/release/libduckdb_bundle.a {{duckdb_lib}}/libduckdb_static.a
    cp {{duckdb_src}}/src/include/duckdb.h {{duckdb_include}}/

# Build Rust with static DuckDB (requires build-duckdb first)
build-rust-static:
    cd ccq && \
    DUCKDB_LIB_DIR="$(pwd)/../{{duckdb_lib}}" \
    DUCKDB_INCLUDE_DIR="$(pwd)/../{{duckdb_include}}" \
    DUCKDB_STATIC=1 \
    cargo build --release

# Full static build (DuckDB + Rust)
build-static: build-duckdb build-rust-static

# Test static build
test-static: build-rust-static
    CC_QUERY="./ccq/target/release/ccq" ./test/test.sh

# Benchmark startup
bench-startup:
    @echo "=== Startup time ===" && \
    for i in 1 2 3; do \
        /usr/bin/time -f "%e sec" ./ccq/target/release/ccq -d test/fixtures <<< "SELECT 1;" 2>&1 | grep sec; \
    done
    @echo "=== Binary size ===" && ls -lh ./ccq/target/release/ccq
    @echo "=== Dependencies ===" && ldd ./ccq/target/release/ccq | grep -E "duckdb|not found" || echo "No DuckDB .so dependency (good!)"

# Clean DuckDB artifacts
clean-duckdb:
    rm -rf {{duckdb_src}}/build {{duckdb_lib}} {{duckdb_include}}
```

### 4. Update .gitignore
**File**: `/home/danny/code/cc-query/rusty/.gitignore`

Add:
```
duckdb-static/duckdb/
duckdb-static/lib/
duckdb-static/include/
```

---

## Key Details

### Library Naming
libduckdb-sys expects `libduckdb_static.a` but DuckDB produces `libduckdb_bundle.a`.
**Solution**: Rename during copy: `cp libduckdb_bundle.a libduckdb_static.a`

### Required System Libraries
Static linking needs: `stdc++`, `pthread`, `dl`, `m`, `z` (handled by build.rs)

### Build Time
First DuckDB build: 10-30 minutes (uses ninja for speed)
Subsequent Rust builds: Normal cargo speed (library cached)

---

## Verification

After implementation, run:

```bash
# 1. Build everything (first time only for DuckDB)
just build-static

# 2. Run e2e tests
just test-static

# 3. Check performance
just bench-startup

# 4. Verify no .so dependency
ldd ./ccq/target/release/ccq | grep duckdb  # Should be empty
```

### Expected Results
- Binary size: ~10-15MB (minimal build with json only, vs 35MB bundled)
- Startup: Should approach 29ms (vs 75ms bundled) - faster due to:
  - CMake build (vs cc crate)
  - No autoload extension scanning
  - Minimal extension set
- `ldd` shows no libduckdb.so dependency

---

## Risk Assessment

### High Confidence: CMake Build Will Be Fast
Based on research, the slow startup is caused by the `cc` crate's compilation approach, not static vs dynamic linking. Building with CMake (`make bundle-library`) uses the same toolchain as official releases.

### Potential Issues
1. **Missing system libraries**: Static linking requires stdc++, pthread, dl, m, z
2. **Version mismatch**: DuckDB version (v1.4.4) must match libduckdb-sys (1.4.4)
3. **Build time**: First DuckDB build takes 10-30 minutes

### Fallback
If static startup is still slow, we can investigate DuckDB's CMake options:
- `DISABLE_THREADS=TRUE` - disable multithreading entirely
- `CMAKE_LTO=full` - enable link-time optimization

---

## Files to Modify

| File | Action |
|------|--------|
| `ccq/Cargo.toml` | Remove `bundled` feature |
| `ccq/build.rs` | Create new file for linker flags |
| `justfile` | Add DuckDB build targets |
| `.gitignore` | Add duckdb-static exclusions |
