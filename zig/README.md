# ccq - Zig Port of cc-query

A Zig implementation of cc-query with 100% feature parity with the Node.js version.

## Requirements

- Zig 0.15.2
- libduckdb (automatically linked from `node_modules/@duckdb/node-bindings-linux-x64`)

## Building

```bash
cd zig
zig build
```

The binary is output to `zig-out/bin/ccq`.

For a release build:
```bash
zig build -Doptimize=ReleaseFast
```

## Usage

```bash
# Query all projects
./zig-out/bin/ccq

# Query a specific project
./zig-out/bin/ccq ~/code/my-project

# Filter by session prefix
./zig-out/bin/ccq -s abc123 .

# Use a custom data directory
./zig-out/bin/ccq -d /path/to/jsonl/files

# Piped queries (TSV output)
echo "SELECT count(*) FROM messages;" | ./zig-out/bin/ccq -d /path/to/data

# Show help
./zig-out/bin/ccq --help
```

## Running Tests

```bash
# Run Zig unit tests
cd zig && zig build test

# Run integration tests against test fixtures
cd .. && test/test-zig.sh

# Or use just
just zig-test
```

## Architecture

| Module | Responsibility |
|--------|---------------|
| `main.zig` | CLI parsing, orchestration |
| `types.zig` | Shared type definitions |
| `paths.zig` | Path resolution, slug generation |
| `session_loader.zig` | File discovery, session counting |
| `database.zig` | DuckDB connection wrapper |
| `views.zig` | SQL view definitions |
| `formatter.zig` | Table/TSV output formatting |
| `repl.zig` | Interactive REPL, dot commands |

## Known Limitations

- No readline support (no arrow key navigation in interactive mode)
- History is saved/loaded but no in-session navigation
- Hardcoded libduckdb path (requires node_modules to be present)

## Differences from Node.js Version

The Zig version is functionally identical but:
- Significantly faster startup time
- Smaller binary size
- No Node.js runtime dependency (just libduckdb.so)
