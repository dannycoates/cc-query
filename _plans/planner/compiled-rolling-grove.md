# Plan: Cross-Compilation with GoReleaser and Cargo-Zigbuild

## Goal
Set up automated multi-platform releases for ccq using GoReleaser + cargo-zigbuild, with cached pre-built DuckDB static libraries.

**Target platforms**: linux-amd64, linux-arm64, macos-amd64, macos-arm64

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                 GitHub Actions Workflow                      │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  1. build-duckdb-libs (runs rarely, manual or on version)  │
│     ├── linux-amd64:  Docker manylinux_2_28_x86_64        │
│     ├── linux-arm64:  Docker manylinux_2_28_aarch64       │
│     ├── macos-amd64:  macos-latest + OSX_BUILD_ARCH       │
│     └── macos-arm64:  macos-latest + OSX_BUILD_ARCH       │
│     └─→ Upload to GitHub Release (duckdb-libs-v1.4.4)     │
│                                                             │
│  2. release (on tag push)                                   │
│     ├── Download cached DuckDB libs                         │
│     ├── GoReleaser + cargo-zigbuild                         │
│     │   └── Builds for all 4 targets                        │
│     └─→ GitHub Release with binaries                        │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Why two workflows?**
- DuckDB takes 10-30 min to build per target (40-120 min total)
- DuckDB version changes rarely (months apart)
- Separating them: release workflow is fast (5-10 min), DuckDB rebuild is manual

---

## Key Challenge: Cross-Compiling DuckDB with Zig

**Problem**: cargo-zigbuild uses Zig as the C/C++ compiler for Rust code, but DuckDB is a pre-built static library. If DuckDB was compiled with GCC/Clang for one architecture, we can't link it against Rust code targeting a different architecture.

**Solution**: Build DuckDB natively on each target platform (not via Zig cross-compilation).
- Linux builds: Use `manylinux_2_28` Docker images (same as DuckDB's CI)
- macOS builds: Use `macos-latest` with `OSX_BUILD_ARCH` (same as DuckDB's CI)

**Why not Zig for DuckDB?**: DuckDB's CMake build system is complex with many C++ dependencies. Zig cross-compilation of large C++ projects is experimental and unreliable. Native builds are proven.

---

## Implementation Steps

### 1. Create DuckDB Static Library Build Workflow

**File**: `/home/danny/code/cc-query/rusty/.github/workflows/build-duckdb-libs.yml`

This workflow:
- Builds DuckDB with minimal extensions (`json` only) for all 4 targets
- Uploads artifacts to a GitHub Release tagged `duckdb-libs-v{version}`
- Runs manually (`workflow_dispatch`) or when DuckDB version changes

```yaml
name: Build DuckDB Static Libraries

on:
  workflow_dispatch:
    inputs:
      duckdb_version:
        description: 'DuckDB version tag (e.g., v1.4.4)'
        required: true
        default: 'v1.4.4'

env:
  DUCKDB_VERSION: ${{ inputs.duckdb_version }}

jobs:
  build-linux:
    strategy:
      matrix:
        include:
          - arch: amd64
            runner: ubuntu-latest
            docker_arch: x86_64
            rust_target: x86_64-unknown-linux-gnu
          - arch: arm64
            runner: ubuntu-24.04-arm
            docker_arch: aarch64
            rust_target: aarch64-unknown-linux-gnu
    runs-on: ${{ matrix.runner }}
    steps:
      - uses: actions/checkout@v4

      - name: Build DuckDB in Docker
        run: |
          docker run --rm -v $PWD:/work -w /work \
            -e DUCKDB_VERSION="${{ env.DUCKDB_VERSION }}" \
            quay.io/pypa/manylinux_2_28_${{ matrix.docker_arch }} \
            bash -c '
              yum install -y git ninja-build
              git clone -b $DUCKDB_VERSION --depth 1 https://github.com/duckdb/duckdb.git
              cd duckdb
              BUILD_EXTENSIONS="json" \
              ENABLE_EXTENSION_AUTOLOADING=0 \
              ENABLE_EXTENSION_AUTOINSTALL=0 \
              GEN=ninja \
              make bundle-library
            '

          mkdir -p dist/${{ matrix.rust_target }}
          cp duckdb/build/release/bundle/libduckdb_bundle.a dist/${{ matrix.rust_target }}/libduckdb_static.a
          cp duckdb/src/include/duckdb.h dist/${{ matrix.rust_target }}/

      - uses: actions/upload-artifact@v4
        with:
          name: duckdb-${{ matrix.rust_target }}
          path: dist/${{ matrix.rust_target }}

  build-macos:
    strategy:
      matrix:
        include:
          - arch: amd64
            osx_arch: x86_64
            rust_target: x86_64-apple-darwin
          - arch: arm64
            osx_arch: arm64
            rust_target: aarch64-apple-darwin
    # macos-latest is arm64; OSX_BUILD_ARCH handles cross-compilation
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Ninja
        run: brew install ninja

      - name: Build DuckDB
        run: |
          git clone -b ${{ env.DUCKDB_VERSION }} --depth 1 https://github.com/duckdb/duckdb.git
          cd duckdb
          OSX_BUILD_ARCH=${{ matrix.osx_arch }} \
          BUILD_EXTENSIONS='json' \
          ENABLE_EXTENSION_AUTOLOADING=0 \
          ENABLE_EXTENSION_AUTOINSTALL=0 \
          GEN=ninja \
          make bundle-library

          cd ..
          mkdir -p dist/${{ matrix.rust_target }}
          cp duckdb/build/release/bundle/libduckdb_bundle.a dist/${{ matrix.rust_target }}/libduckdb_static.a
          cp duckdb/src/include/duckdb.h dist/${{ matrix.rust_target }}/

      - uses: actions/upload-artifact@v4
        with:
          name: duckdb-${{ matrix.rust_target }}
          path: dist/${{ matrix.rust_target }}

  create-release:
    needs: [build-linux, build-macos]
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/download-artifact@v4
        with:
          path: duckdb-libs
          pattern: duckdb-*
          merge-multiple: false

      - name: Create zip archives
        run: |
          cd duckdb-libs
          for dir in duckdb-*/; do
            target=$(basename "$dir")
            zip -rj "${target}.zip" "$dir"
          done

      - name: Create Release
        uses: softprops/action-gh-release@v2
        with:
          tag_name: duckdb-libs-${{ env.DUCKDB_VERSION }}
          name: DuckDB Static Libraries ${{ env.DUCKDB_VERSION }}
          files: duckdb-libs/*.zip
          body: |
            Pre-built DuckDB static libraries for ccq cross-compilation.
            - Minimal build: json extension only
            - No autoloading/autoinstall
```

### 2. Create GoReleaser Configuration

**File**: `/home/danny/code/cc-query/rusty/.goreleaser.yml`

```yaml
version: 2

project_name: ccq

before:
  hooks:
    # Download pre-built DuckDB static libraries
    - bash scripts/download-duckdb-libs.sh

builds:
  - id: ccq
    builder: rust
    dir: ccq
    binary: ccq
    targets:
      - x86_64-unknown-linux-gnu
      - aarch64-unknown-linux-gnu
      - x86_64-apple-darwin
      - aarch64-apple-darwin
    # .Target contains the Rust triple (e.g., "x86_64-unknown-linux-gnu")
    # This lets us point to the right DuckDB lib for each target
    env:
      - "DUCKDB_LIB_DIR={{.Env.PWD}}/duckdb-libs/{{.Target}}"
      - "DUCKDB_INCLUDE_DIR={{.Env.PWD}}/duckdb-libs/{{.Target}}"
      - DUCKDB_STATIC=1

archives:
  - id: default
    format: tar.gz
    name_template: "{{.ProjectName}}_{{.Version}}_{{.Os}}_{{.Arch}}"

checksum:
  name_template: 'checksums.txt'

changelog:
  sort: asc
  filters:
    exclude:
      - '^docs:'
      - '^test:'
      - '^chore:'

release:
  github:
    owner: danny  # Update with actual owner
    name: cc-query
```

### 3. Create DuckDB Library Download Script

**File**: `/home/danny/code/cc-query/rusty/scripts/download-duckdb-libs.sh`

```bash
#!/usr/bin/env bash
set -euo pipefail

# Configuration
DUCKDB_LIBS_VERSION="${DUCKDB_LIBS_VERSION:-v1.4.4}"
DUCKDB_LIBS_DIR="${DUCKDB_LIBS_DIR:-duckdb-libs}"
REPO="${GITHUB_REPOSITORY:-danny/cc-query}"  # Update with actual repo

TARGETS=(
  "x86_64-unknown-linux-gnu"
  "aarch64-unknown-linux-gnu"
  "x86_64-apple-darwin"
  "aarch64-apple-darwin"
)

mkdir -p "$DUCKDB_LIBS_DIR"

for target in "${TARGETS[@]}"; do
  if [ -f "$DUCKDB_LIBS_DIR/$target/libduckdb_static.a" ]; then
    echo "DuckDB lib for $target already exists, skipping"
    continue
  fi

  echo "Downloading DuckDB lib for $target..."
  mkdir -p "$DUCKDB_LIBS_DIR/$target"

  gh release download "duckdb-libs-$DUCKDB_LIBS_VERSION" \
    --repo "$REPO" \
    --pattern "duckdb-$target.zip" \
    --dir "$DUCKDB_LIBS_DIR"

  unzip -o "$DUCKDB_LIBS_DIR/duckdb-$target.zip" -d "$DUCKDB_LIBS_DIR/$target"
  rm "$DUCKDB_LIBS_DIR/duckdb-$target.zip"
done

echo "DuckDB libraries ready in $DUCKDB_LIBS_DIR/"
```

### 4. Create Release Workflow

**File**: `/home/danny/code/cc-query/rusty/.github/workflows/release.yml`

```yaml
name: Release

on:
  push:
    tags:
      - 'v*'

permissions:
  contents: write

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0

      - name: Setup Rust
        uses: dtolnay/rust-toolchain@stable

      - name: Install Zig
        uses: goto-bus-stop/setup-zig@v2

      - name: Install cargo-zigbuild
        run: cargo install --locked cargo-zigbuild

      - name: Add Rust targets
        run: |
          rustup target add x86_64-unknown-linux-gnu
          rustup target add aarch64-unknown-linux-gnu
          rustup target add x86_64-apple-darwin
          rustup target add aarch64-apple-darwin

      - name: Download DuckDB libs
        env:
          GH_TOKEN: ${{ github.token }}
          DUCKDB_LIBS_VERSION: v1.4.4
        run: |
          chmod +x scripts/download-duckdb-libs.sh
          ./scripts/download-duckdb-libs.sh

      - name: Run GoReleaser
        uses: goreleaser/goreleaser-action@v6
        with:
          distribution: goreleaser
          version: '~> v2'
          args: release --clean
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          # PWD is used by .goreleaser.yml to construct per-target paths
          PWD: ${{ github.workspace }}
```

### 5. Update build.rs for Cross-Platform Linking

**File**: `/home/danny/code/cc-query/rusty/ccq/build.rs`

The current build.rs needs updates for cross-platform linking:

```rust
fn main() {
    if std::env::var("DUCKDB_STATIC").is_ok() {
        // Common libraries
        println!("cargo:rustc-link-lib=pthread");
        println!("cargo:rustc-link-lib=m");

        // Platform-specific libraries
        let target = std::env::var("TARGET").unwrap_or_default();

        if target.contains("linux") {
            println!("cargo:rustc-link-lib=stdc++");
            println!("cargo:rustc-link-lib=dl");
            println!("cargo:rustc-link-lib=z");
        } else if target.contains("darwin") || target.contains("apple") {
            println!("cargo:rustc-link-lib=c++");
            println!("cargo:rustc-link-lib=z");
        }
    }
}
```

### 6. Update .gitignore

**File**: `/home/danny/code/cc-query/rusty/.gitignore`

Add:
```
duckdb-libs/
```

### 7. Add justfile Targets for Local Testing

**File**: `/home/danny/code/cc-query/rusty/justfile`

Add these targets:

```just
# === Cross-compilation targets ===

# Download pre-built DuckDB libs (requires gh auth)
download-duckdb-libs:
    DUCKDB_LIBS_VERSION=v1.4.4 ./scripts/download-duckdb-libs.sh

# Build for a specific target (requires duckdb-libs)
build-target target:
    cd ccq && \
    DUCKDB_LIB_DIR="$(pwd)/../duckdb-libs/{{target}}" \
    DUCKDB_INCLUDE_DIR="$(pwd)/../duckdb-libs/{{target}}" \
    DUCKDB_STATIC=1 \
    cargo zigbuild --release --target {{target}}

# Test goreleaser config
goreleaser-check:
    goreleaser check

# Dry-run release (no publish)
release-dry:
    goreleaser release --snapshot --clean
```

---

## Files to Create/Modify

| File | Action |
|------|--------|
| `.github/workflows/build-duckdb-libs.yml` | Create - DuckDB build workflow |
| `.github/workflows/release.yml` | Create - Release workflow |
| `.goreleaser.yml` | Create - GoReleaser config |
| `scripts/download-duckdb-libs.sh` | Create - Download helper |
| `ccq/build.rs` | Modify - Cross-platform linking |
| `.gitignore` | Modify - Add duckdb-libs/ |
| `justfile` | Modify - Add cross-compile targets |

---

## Usage Flow

### Initial Setup (one-time)
```bash
# 1. Build DuckDB static libs (takes 40-120 min)
#    Go to GitHub Actions > "Build DuckDB Static Libraries" > Run workflow
#    This creates a release: duckdb-libs-v1.4.4

# 2. Test locally
just download-duckdb-libs
just build-target x86_64-unknown-linux-gnu
```

### Making a Release
```bash
# 1. Update version and tag
git tag v0.1.0
git push origin v0.1.0

# 2. Release workflow runs automatically:
#    - Downloads cached DuckDB libs
#    - Builds for all 4 targets with cargo-zigbuild
#    - Creates GitHub release with binaries
```

### Updating DuckDB Version
```bash
# 1. Update justfile: duckdb_version := "v1.5.0"
# 2. Update DUCKDB_LIBS_VERSION in scripts and workflows
# 3. Run "Build DuckDB Static Libraries" workflow with new version
# 4. Make a new release
```

---

## Verification

After implementation, verify with:

```bash
# 1. Check goreleaser config
just goreleaser-check

# 2. Dry-run release (builds all targets locally)
just release-dry

# 3. Check that binaries were created for all targets
ls dist/

# 4. Test a built binary
./dist/ccq_linux_amd64_v1/ccq --version
```

---

## Risks & Mitigations

| Risk | Mitigation |
|------|------------|
| macOS cross-compile from Linux may fail | cargo-zigbuild handles this; fallback: use macOS runner |
| DuckDB libs version mismatch | Pin version in both workflows, document upgrade process |
| Large CI cache usage | DuckDB libs are ~40-60MB per target; acceptable for release assets |
| cargo-zigbuild limitations | Linux/macOS only; Windows would need separate approach |

---

## References

- [GoReleaser Rust docs](https://goreleaser.com/customization/builds/rust/)
- [cargo-zigbuild](https://github.com/rust-cross/cargo-zigbuild)
- [DuckDB BundleStaticLibs.yml](https://github.com/duckdb/duckdb/blob/main/.github/workflows/BundleStaticLibs.yml)
- [duckdb-go-bindings](https://github.com/duckdb/duckdb-go-bindings) - similar approach for Go
