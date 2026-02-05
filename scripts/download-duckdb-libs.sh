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
