## Commands

```bash
just typecheck       # Type-check all JS files with TypeScript (no emit)
just test            # Run tests against fixtures
just test-rust       # Run Rust unit tests
just test-e2e        # Build ccq and run e2e tests
just build           # Build ccq release binary
just bump [type]     # Bump version (patch by default, or major|minor|patch)
```

## What This Project Does

cc-query is a CLI tool for querying Claude Code session data using SQL (DuckDB). It reads JSONL files from `~/.claude/projects/` and provides an interactive SQL REPL or accepts piped queries.

## Architecture

The primary implementation is Rust (`ccq/`). A legacy JavaScript implementation (`src/`, `bin/cc-query.js`) also exists.

**Entry points:**
- `bin/cc-query` - Bash wrapper that invokes the `ccq` Rust binary
- `ccq/src/main.rs` - Rust CLI entry point, parses args (`--session/-s` filter, `--help/-h`)

**Rust core modules (`ccq/src/`):**
- `query_session.rs` - `QuerySession` struct wraps DuckDB, creates SQL views over JSONL files
- `session_loader.rs` - Discovers session files in `~/.claude/projects/{slug}/`
- `repl.rs` - Interactive REPL with history (~/.cc_query_history), dot commands, multi-line input
- `formatter.rs` - Table/TSV output formatting, `ValueRef` display
- `utils.rs` - Path resolution (`~/`, relative paths) and project slug generation
- `error.rs` - Error types

**Data flow:**
1. CLI resolves project path to Claude projects directory (`~/.claude/projects/{slug}`)
2. `get_session_files()` builds glob pattern for JSONL files
3. `QuerySession` creates in-memory DuckDB with views (`messages`, `user_messages`, `assistant_messages`, `system_messages`, `human_messages`, `raw_messages`, `tool_uses`, `tool_results`, `token_usage`, `bash_commands`, `file_operations`)
4. REPL or piped mode executes SQL queries against views

**Key DuckDB features used:**
- `read_ndjson()` with glob patterns, `filename=true`, `ignore_errors=true`
- JSON operators: `->` (JSON access), `->>` (string extract)
- Views created dynamically based on file pattern

## Documentation

`docs/message-schema.md` contains the JSONL message schema reference and example SQL queries for analyzing Claude Code sessions.
