## Commands

```bash
npm run typecheck    # Type-check all JS files with TypeScript (no emit)
```

There is no build step - this is a JavaScript project with JSDoc type annotations checked by TypeScript.

## What This Project Does

cc-query is a CLI tool for querying Claude Code session data using SQL (DuckDB). It reads JSONL files from `~/.claude/projects/` and provides an interactive SQL REPL or accepts piped queries.

## Architecture

The codebase is vanilla JavaScript with JSDoc types, using ES modules.

**Entry points:**
- `bin/cc-query.js` - CLI entry point, parses args (`--session/-s` filter, `--help/-h`)
- `index.js` - Library exports: `QuerySession`

**Core modules:**
- `src/query-session.js` - `QuerySession` class wraps DuckDB, creates SQL views over JSONL files
- `src/session-loader.js` - Discovers session files in `~/.claude/projects/{slug}/`
- `src/repl.js` - Interactive REPL with history (~/.cc_query_history), dot commands, multi-line input
- `src/utils.js` - Path resolution (`~/`, relative paths) and project slug generation

**Data flow:**
1. CLI resolves project path to Claude projects directory (`~/.claude/projects/{slug}`)
2. `getSessionFiles()` builds glob pattern for JSONL files
3. `QuerySession` creates in-memory DuckDB with views (`messages`, `user_messages`, `assistant_messages`, `system_messages`, `human_messages`, `raw_messages`)
4. REPL or piped mode executes SQL queries against views

**Key DuckDB features used:**
- `read_ndjson()` with glob patterns, `filename=true`, `union_by_name=true`
- JSON operators: `->` (JSON access), `->>` (string extract)
- Views created dynamically based on file pattern

## Documentation

`docs/message-schema.md` contains the JSONL message schema reference and example SQL queries for analyzing Claude Code sessions.
