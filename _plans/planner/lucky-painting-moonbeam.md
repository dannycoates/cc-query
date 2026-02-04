# Rust Port Plan: cc-query → ccq

## Overview

Port cc-query (Node.js CLI for querying Claude Code session data with DuckDB) to Rust as `ccq`, in a `ccq/` subdirectory for side-by-side development.

**Key Decisions:**
- Binary name: `ccq`
- Location: `ccq/` subdirectory (standalone crate, not workspace)
- Dependencies: `duckdb`, `clap`, `rustyline`, `thiserror`, `anyhow`
- Testing: Native Rust tests + adapted bash test suite
- Scope: CLI binary with internal library structure
- **External interface must match Node.js exactly** (CLI args, output format, behavior)
- **Internal code should be idiomatic modern Rust** (lib/bin split, derives, clippy, etc.)

---

## Rust Idioms Applied

| Pattern | Application |
|---------|-------------|
| **lib.rs + main.rs split** | Library code testable independently, thin CLI wrapper |
| **Custom error type** | `thiserror` for structured errors, `Error` enum in `error.rs` |
| **Derive macros** | `#[derive(Debug, Clone)]` on all public types |
| **`#[non_exhaustive]`** | On enums to allow future variants without breaking changes |
| **Named structs over tuples** | `ResolvedProject` instead of `(PathBuf, PathBuf)` |
| **Accessor methods** | Private fields with `pub fn field(&self)` getters |
| **Doc comments** | `///` on all public items |
| **Clippy lints** | `pedantic` + `nursery` for strict code quality |
| **`impl Display`** | For types that need string representation |
| **`?` operator** | Ergonomic error propagation with custom `Result<T>` |
| **No `unwrap()`** | Proper error handling throughout |

---

## Directory Structure

```
cc-query/
├── ccq/                      # NEW: Rust implementation
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs            # Library root, public API, module declarations
│   │   ├── main.rs           # Thin CLI wrapper, clap parsing only
│   │   ├── error.rs          # Custom error types with thiserror
│   │   ├── query_session.rs  # DuckDB wrapper, 11 SQL views
│   │   ├── session_loader.rs # File discovery, glob patterns
│   │   ├── repl.rs           # Interactive REPL, dot commands
│   │   ├── formatter.rs      # Table/TSV output formatting
│   │   └── utils.rs          # Path resolution, slug generation
│   └── tests/
│       └── integration.rs    # Rust integration tests
├── test/                     # Existing bash test suite (reused)
├── src/                      # Existing Node.js (reference)
└── ...
```

---

## Implementation Phases

### Phase 1: Project Setup

1. Create `ccq/` directory with `Cargo.toml`:
   ```toml
   [package]
   name = "ccq"
   version = "0.1.0"
   edition = "2024"
   description = "SQL REPL for querying Claude Code session data"
   license = "MIT"

   [lib]
   name = "ccq"
   path = "src/lib.rs"

   [[bin]]
   name = "ccq"
   path = "src/main.rs"

   [dependencies]
   duckdb = "1.4"
   clap = { version = "4", features = ["derive"] }
   rustyline = "17"
   dirs = "6"
   anyhow = "1"
   thiserror = "2"
   chrono = "0.4"
   walkdir = "2"

   [dev-dependencies]
   tempfile = "3"

   [lints.rust]
   unsafe_code = "forbid"

   [lints.clippy]
   all = "warn"
   pedantic = "warn"
   nursery = "warn"
   # Allow these common patterns
   module_name_repetitions = "allow"
   must_use_candidate = "allow"
   ```

2. Create `src/lib.rs` (library root with module declarations):
   ```rust
   //! cc-query library for querying Claude Code session data with DuckDB.

   pub mod error;
   pub mod formatter;
   pub mod query_session;
   pub mod repl;
   pub mod session_loader;
   pub mod utils;

   pub use error::{Error, Result};
   pub use query_session::QuerySession;
   pub use session_loader::SessionInfo;
   ```

3. Create `src/main.rs` (thin CLI wrapper):
   ```rust
   //! CLI entry point for ccq.

   use std::io::IsTerminal;
   use std::path::PathBuf;
   use std::process::ExitCode;

   use clap::Parser;

   /// SQL REPL for querying Claude Code session data
   #[derive(Debug, Parser)]
   #[command(name = "ccq", version, about)]
   struct Cli {
       /// Path to project (omit for all projects)
       project_path: Option<PathBuf>,

       /// Filter to sessions matching ID prefix
       #[arg(short, long)]
       session: Option<String>,

       /// Use directory directly as JSONL data source
       #[arg(short, long = "data-dir")]
       data_dir: Option<PathBuf>,
   }

   fn main() -> ExitCode {
       if let Err(e) = run() {
           eprintln!("Error: {e}");
           ExitCode::FAILURE
       } else {
           ExitCode::SUCCESS
       }
   }

   fn run() -> ccq::Result<()> {
       let cli = Cli::parse();

       let session = ccq::QuerySession::create(
           cli.project_path.as_deref(),
           cli.session.as_deref(),
           cli.data_dir.as_deref(),
       )?;

       if std::io::stdin().is_terminal() {
           ccq::repl::start_interactive(session)
       } else {
           ccq::repl::run_piped(session)
       }
   }
   ```

4. Create `src/error.rs` (custom error types):
   ```rust
   //! Error types for ccq.

   use std::path::PathBuf;

   /// Custom error type for ccq operations.
   #[derive(Debug, thiserror::Error)]
   pub enum Error {
       /// Must match: "Error: No JSONL files found in {path}"
       #[error("No JSONL files found in {}", path.display())]
       NoSessions { path: PathBuf },

       #[error("No Claude Code data found for project: {}", path.display())]
       NoProjectData { path: PathBuf },

       #[error("Directory not found: {}", path.display())]
       DirectoryNotFound { path: PathBuf },

       #[error("Database error: {0}")]
       Database(#[from] duckdb::Error),

       #[error("IO error: {0}")]
       Io(#[from] std::io::Error),

       #[error("Readline error: {0}")]
       Readline(#[from] rustyline::error::ReadlineError),
   }

   /// Result type alias for ccq operations.
   pub type Result<T> = std::result::Result<T, Error>;
   ```

5. Create stub files for remaining modules with doc comments

### Phase 2: Path Utilities (`src/utils.rs`)

Port from `/home/danny/code/cc-query/src/utils.js`:

```rust
//! Path resolution and project slug utilities.

use std::path::PathBuf;

/// Resolved project paths.
#[derive(Debug, Clone)]
pub struct ResolvedProject {
    /// Absolute path to the project directory
    pub project_path: PathBuf,
    /// Path to Claude Code data directory (~/.claude/projects/{slug}/)
    pub claude_data_dir: PathBuf,
}

/// Returns the base Claude projects directory (~/.claude/projects).
pub fn claude_projects_base() -> PathBuf {
    dirs::home_dir()
        .expect("No home directory found")
        .join(".claude")
        .join("projects")
}

/// Resolve a project path with tilde expansion and relative path handling.
///
/// - `~/...` expands to home directory
/// - Relative paths resolve against `CLAUDE_PROJECT_DIR` env var or cwd
pub fn resolve_project_path(path: &str) -> PathBuf {
    // Implementation
}

/// Generate a project slug from a path.
///
/// Replaces `/` and `.` with `-` to create a filesystem-safe identifier.
pub fn get_project_slug(path: &std::path::Path) -> String {
    path.to_string_lossy().replace(['/', '.'], "-")
}

/// Resolve a project path and return both the original and Claude data directory.
pub fn resolve_project_dir(path: &str) -> ResolvedProject {
    let project_path = resolve_project_path(path);
    let slug = get_project_slug(&project_path);
    let claude_data_dir = claude_projects_base().join(slug);
    ResolvedProject { project_path, claude_data_dir }
}
```

### Phase 3: Session Loader (`src/session_loader.rs`)

Port from `/home/danny/code/cc-query/src/session-loader.js`:

```rust
//! Session file discovery and glob pattern generation.

use std::path::Path;
use crate::{Error, Result};

/// Pattern for DuckDB to read JSONL files.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum FilePattern {
    /// Single glob pattern
    Single(String),
    /// Multiple glob patterns (for filtered sessions with agents)
    Multiple(Vec<String>),
}

impl std::fmt::Display for FilePattern {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Single(p) => write!(f, "'{p}'"),
            Self::Multiple(ps) => {
                let joined = ps.iter().map(|p| format!("'{p}'")).collect::<Vec<_>>().join(", ");
                write!(f, "[{joined}]")
            }
        }
    }
}

/// Information about discovered session files.
#[derive(Debug, Clone)]
pub struct SessionInfo {
    session_count: usize,
    agent_count: usize,
    project_count: usize,
    file_pattern: FilePattern,
}

impl SessionInfo {
    /// Number of session files found.
    pub fn session_count(&self) -> usize { self.session_count }

    /// Number of agent files found.
    pub fn agent_count(&self) -> usize { self.agent_count }

    /// Number of projects scanned.
    pub fn project_count(&self) -> usize { self.project_count }

    /// File pattern for DuckDB to read.
    pub fn file_pattern(&self) -> &FilePattern { &self.file_pattern }
}

/// Discover session files and generate glob patterns for DuckDB.
pub fn get_session_files(
    project_dir: Option<&Path>,
    session_filter: Option<&str>,
    data_dir: Option<&Path>,
) -> Result<SessionInfo> {
    // Implementation using walkdir for directory traversal
}
```

**Three modes to support:**
1. Direct `--data-dir`: use provided directory
2. Specific project: use `~/.claude/projects/{slug}/`
3. All projects (no args): scan all `~/.claude/projects/*/`

**File categorization (use `walkdir` for traversal):**
- Session files: `{uuid}.jsonl` (top-level, not agent-prefixed)
- Agent files: `{uuid}/subagents/agent-{id}.jsonl`

### Phase 4: Output Formatting (`src/formatter.rs`)

Port from `/home/danny/code/cc-query/src/query-session.js` (lines 16-113).

```rust
//! Output formatting for query results.

use duckdb::types::{TimeUnit, Value};
use chrono::{TimeZone, Utc};

/// Convert a DuckDB value to a display string.
///
/// Handles special formatting for NULL and timestamps to match
/// the Node.js implementation output exactly.
/// UUIDs come through as Text(String) already formatted - no conversion needed!
pub fn value_to_string(val: &Value) -> String {
    match val {
        Value::Null => "NULL".into(),
        Value::Boolean(b) => b.to_string(),
        Value::TinyInt(n) => n.to_string(),
        Value::SmallInt(n) => n.to_string(),
        Value::Int(n) => n.to_string(),
        Value::BigInt(n) => n.to_string(),
        Value::HugeInt(n) => n.to_string(),
        Value::Float(n) => n.to_string(),
        Value::Double(n) => n.to_string(),
        Value::Text(s) => s.clone(),  // UUIDs come here, already formatted
        Value::Timestamp(unit, val) => format_timestamp(*unit, *val),
        Value::Date32(days) => format_date(*days),
        Value::Blob(bytes) => format!("<{} bytes>", bytes.len()),
        // JSON comes as Text, List/Struct need serialization
        _ => format!("{val:?}"),  // Fallback for unhandled types
    }
}

/// Format a date (days since Unix epoch) to "YYYY-MM-DD"
fn format_date(days: i32) -> String {
    chrono::NaiveDate::from_num_days_from_ce_opt(days + 719_163)  // Unix epoch offset
        .map(|d| d.format("%Y-%m-%d").to_string())
        .unwrap_or_else(|| "INVALID_DATE".into())
}

/// Format a timestamp to match Node.js output: "YYYY-MM-DD HH:MM:SS.mmm"
fn format_timestamp(unit: TimeUnit, value: i64) -> String {
    let micros = match unit {
        TimeUnit::Second => value * 1_000_000,
        TimeUnit::Millisecond => value * 1_000,
        TimeUnit::Microsecond => value,
        TimeUnit::Nanosecond => value / 1_000,
    };

    Utc.timestamp_micros(micros)
        .single()
        .map(|dt| dt.format("%Y-%m-%d %H:%M:%S%.3f").to_string())
        .unwrap_or_else(|| "INVALID_TIMESTAMP".into())
}

/// Format results as a table with Unicode box-drawing characters.
///
/// Format matches Node.js exactly:
/// ```text
/// ┌──────────┬───────┐
/// │ column1  │ col2  │
/// ├──────────┼───────┤
/// │ value1   │ val2  │
/// └──────────┴───────┘
/// (N rows)
/// ```
pub fn format_table(columns: &[String], rows: &[Vec<String>]) -> String {
    if rows.is_empty() {
        // Special case: header only with "(0 rows)"
        return format!("{}\n(0 rows)", columns.join(" | "));
    }

    // Calculate column widths (max of header and data)
    let widths: Vec<usize> = columns.iter().enumerate()
        .map(|(i, name)| {
            let max_data = rows.iter().map(|r| r.get(i).map_or(0, String::len)).max().unwrap_or(0);
            name.len().max(max_data)
        })
        .collect();

    // Build with box-drawing: ┌─┬┐ │ ├┼┤ └┴┘
    // Header row padded, data rows padded
    // Footer: "(N row)" or "(N rows)"
}

/// Format results as tab-separated values.
pub fn format_tsv(columns: &[String], rows: &[Vec<String>]) -> String {
    let mut lines = Vec::with_capacity(rows.len() + 1);
    lines.push(columns.join("\t"));
    for row in rows {
        lines.push(row.join("\t"));
    }
    lines.join("\n")
}
```

**Value conversion - RESOLVED:**

| Type | Node.js Returns | duckdb-rs Returns | Rust Handling |
|------|-----------------|-------------------|---------------|
| Timestamp | `{micros: bigint}` | `Timestamp(TimeUnit::Microsecond, i64)` | Convert micros to DateTime |
| UUID | `{hugeint: string}` (needs bit manipulation) | `Text(String)` (already formatted!) | Just use the string directly |

**Key finding:** UUIDs are returned as formatted strings in duckdb-rs ([PR #44](https://github.com/duckdb/duckdb-rs/issues/35)). No bit manipulation needed - this is simpler than Node.js!

**Timestamp handling:** DuckDB stores timestamps as [microseconds since Unix epoch](https://duckdb.org/docs/stable/sql/data_types/timestamp). Use `TimeUnit::Microsecond`.

### Phase 5: Query Session (`src/query_session.rs`)

Port from `/home/danny/code/cc-query/src/query-session.js`:

```rust
//! DuckDB query session management.

use std::path::Path;
use duckdb::Connection;
use crate::{session_loader::{self, SessionInfo}, formatter, Error, Result};

/// Query result with column names and row data.
#[derive(Debug, Clone)]
pub struct QueryResult {
    columns: Vec<String>,
    rows: Vec<Vec<String>>,
}

impl QueryResult {
    /// Column names from the query.
    pub fn columns(&self) -> &[String] { &self.columns }

    /// Row data as strings.
    pub fn rows(&self) -> &[Vec<String>] { &self.rows }

    /// Number of rows returned.
    pub fn row_count(&self) -> usize { self.rows.len() }

    /// Format as a table with Unicode box-drawing characters.
    pub fn to_table(&self) -> String {
        formatter::format_table(&self.columns, &self.rows)
    }

    /// Format as tab-separated values.
    pub fn to_tsv(&self) -> String {
        formatter::format_tsv(&self.columns, &self.rows)
    }
}

/// DuckDB session with pre-configured views over JSONL session data.
pub struct QuerySession {
    conn: Connection,
    info: SessionInfo,
}

impl QuerySession {
    /// Create a new query session.
    ///
    /// # Errors
    /// Returns error if no sessions are found or database setup fails.
    pub fn create(
        project_dir: Option<&Path>,
        session_filter: Option<&str>,
        data_dir: Option<&Path>,
    ) -> Result<Self> {
        let info = session_loader::get_session_files(project_dir, session_filter, data_dir)?;

        if info.session_count() == 0 {
            return Err(Error::NoSessions {
                path: data_dir
                    .map(Path::to_path_buf)
                    .unwrap_or_else(|| project_dir.map(Path::to_path_buf).unwrap_or_default()),
            });
        }

        let conn = Connection::open_in_memory()?;
        let sql = Self::build_create_views_sql(info.file_pattern());
        conn.execute_batch(&sql)?;

        Ok(Self { conn, info })
    }

    /// Session information (counts, patterns).
    pub fn info(&self) -> &SessionInfo { &self.info }

    /// Execute a SQL query and return results.
    pub fn query(&self, sql: &str) -> Result<QueryResult> {
        // Execute query, convert DuckDB types to strings
    }

    /// Generate SQL to create all 11 views.
    fn build_create_views_sql(pattern: &crate::session_loader::FilePattern) -> String {
        // Return the CREATE VIEW statements
    }
}
```

**11 SQL Views to create (copy SQL exactly from Node.js):**

1. `messages` - Base view with 30+ columns, derived fields (file, isAgent, agentId, project, rownum)
2. `user_messages` - Filtered to type='user'
3. `human_messages` - User messages with human-typed content only (filters tool results, meta)
4. `assistant_messages` - Filtered to type='assistant'
5. `system_messages` - Filtered to type='system'
6. `raw_messages` - Full JSON per UUID
7. `tool_uses` - LATERAL UNNEST of content array for tool_use blocks
8. `tool_results` - LATERAL UNNEST for tool_result blocks with duration_ms
9. `token_usage` - Pre-cast token counts from usage field
10. `bash_commands` - Bash tool calls with extracted command
11. `file_operations` - Read/Write/Edit/Glob/Grep with file paths

**Key DuckDB features:**
- `read_ndjson({pattern}, filename=true, ignore_errors=true, columns={...})`
- `WITH ORDINALITY` for row numbers
- `LATERAL UNNEST(CAST(... AS JSON[]))` for array expansion
- `regexp_extract()` for derived fields

### Phase 6: REPL (`src/repl.rs`)

Port from `/home/danny/code/cc-query/src/repl.js`:

```rust
//! Interactive REPL and piped query execution.

use std::io::{self, Read, Write};
use rustyline::{DefaultEditor, error::ReadlineError};
use crate::{QuerySession, Result};

const HISTORY_FILE: &str = ".cc_query_history";
const HISTORY_SIZE: usize = 100;
const PROMPT: &str = "ccq> ";
const CONTINUATION_PROMPT: &str = "  -> ";

/// Dot command result.
enum DotCommandResult {
    /// Continue REPL
    Continue,
    /// Exit REPL
    Exit,
}

/// Start an interactive REPL session.
pub fn start_interactive(session: QuerySession) -> Result<()> {
    let history_path = dirs::home_dir()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "No home directory"))?
        .join(HISTORY_FILE);

    let mut editor = DefaultEditor::new()?;
    let _ = editor.load_history(&history_path);  // Ignore missing file

    print_banner(&session);

    let result = run_repl_loop(&mut editor, &session);

    // Always try to save history, ignore errors
    let _ = editor.save_history(&history_path);

    result
}

fn print_banner(session: &QuerySession) {
    let info = session.info();
    println!(
        "Loaded {} session(s), {} agent file(s) from {} project(s)",
        info.session_count(),
        info.agent_count(),
        info.project_count()
    );
    println!("Type \".help\" for usage hints.\n");
}

fn run_repl_loop(editor: &mut DefaultEditor, session: &QuerySession) -> Result<()> {
    let mut multiline_buffer = String::new();

    loop {
        let prompt = if multiline_buffer.is_empty() { PROMPT } else { CONTINUATION_PROMPT };

        match editor.readline(prompt) {
            Ok(line) => {
                if let Some(result) = process_line(&line, &mut multiline_buffer, session, editor)? {
                    if matches!(result, DotCommandResult::Exit) {
                        break;
                    }
                }
            }
            Err(ReadlineError::Interrupted | ReadlineError::Eof) => break,
            Err(e) => return Err(e.into()),
        }
    }

    println!("Goodbye!");
    Ok(())
}

/// Execute piped queries from stdin.
pub fn run_piped(session: QuerySession) -> Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;

    let mut is_first = true;
    for statement in input.split(';').map(str::trim).filter(|s| !s.is_empty()) {
        if !is_first {
            println!("---");
        }
        is_first = false;

        if statement.starts_with('.') {
            handle_dot_command(statement, &session)?;
        } else {
            match session.query(statement) {
                Ok(result) => print!("{}", result.to_tsv()),
                Err(e) => eprintln!("Error: {e}"),
            }
        }
    }

    Ok(())
}
```

**Features to implement:**
- Multi-line input: accumulate lines until semicolon at end of trimmed line
- Dot commands: `.quit/.exit/.q`, `.help/.h`, `.schema/.s [view]`
- History: persist to `~/.cc_query_history`, max 100 entries
- Help text: list views, example queries, JSON access syntax

---

## Testing Strategy

### Native Rust Tests (`ccq/tests/integration.rs`)

```rust
use std::process::Command;

fn run_ccq(query: &str) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_ccq"))
        .args(["-d", "../test/fixtures"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .spawn()
        .expect("Failed to start ccq");

    // Write query to stdin, collect stdout
    // ...
}

#[test]
fn test_count_messages() {
    let output = run_ccq("SELECT count(*) FROM messages;");
    // Verify against expected count from fixtures
    assert!(output.contains("count_star()"));
}

#[test]
fn test_all_views_exist() {
    for view in ["messages", "user_messages", "tool_uses", /* ... */] {
        let output = run_ccq(&format!("SELECT 1 FROM {} LIMIT 1;", view));
        assert!(!output.contains("Error"), "View {} should exist", view);
    }
}
```

### Adapt Bash Test Suite

1. Modify `/home/danny/code/cc-query/test/test.sh` line 10:
   ```bash
   # Before:
   CC_QUERY="$SCRIPT_DIR/../bin/cc-query.js"

   # After:
   CC_QUERY="${CC_QUERY:-$SCRIPT_DIR/../bin/cc-query.js}"
   ```

2. Remove or skip the `help` test in `/home/danny/code/cc-query/test/test-cases.sh`:
   ```bash
   # Comment out or remove:
   # run_command_test "help" "$CC_QUERY" --help
   ```
   Help text format doesn't need to match between implementations.

Then run against Rust binary:
```bash
CC_QUERY="./ccq/target/release/ccq" ./test/test.sh
```

Remaining 43 test cases validate both implementations.

---

## Justfile Updates

Add to existing justfile:

```just
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
```

---

## Critical Implementation Details

### UUID Handling - RESOLVED

**Node.js** requires complex bit manipulation because its DuckDB binding returns UUIDs as `{hugeint: string}`.

**Rust** is simpler! duckdb-rs returns UUIDs as `Text(String)` already formatted (e.g., `"550e8400-e29b-41d4-a716-446655440000"`).

```rust
// In value_to_string(), UUIDs just work:
Value::Text(s) => s.clone(),  // UUIDs come through here, already formatted
```

No bit manipulation needed. This was resolved in [duckdb-rs PR #44](https://github.com/duckdb/duckdb-rs/pull/44) (April 2022).

### Timestamp Handling - RESOLVED

DuckDB stores timestamps as [microseconds since Unix epoch](https://duckdb.org/docs/stable/sql/data_types/timestamp). The `Value::Timestamp` variant will use `TimeUnit::Microsecond`.

**Node.js:**
```javascript
const ms = Number(val.micros) / 1000;
return new Date(ms).toISOString().replace("T", " ").replace("Z", "");
// Output: "2024-01-15 10:30:45.123"
```

**Rust (using chrono):**
```rust
use chrono::{TimeZone, Utc};
use duckdb::types::TimeUnit;

fn format_timestamp(unit: TimeUnit, value: i64) -> String {
    // DuckDB TIMESTAMP columns use microseconds
    let micros = match unit {
        TimeUnit::Second => value * 1_000_000,
        TimeUnit::Millisecond => value * 1_000,
        TimeUnit::Microsecond => value,  // Expected for TIMESTAMP
        TimeUnit::Nanosecond => value / 1_000,
    };

    Utc.timestamp_micros(micros)
        .single()
        .map(|dt| dt.format("%Y-%m-%d %H:%M:%S%.3f").to_string())
        .unwrap_or_else(|| "INVALID_TIMESTAMP".into())
}
```

**Note:** Format must match Node.js exactly: `"YYYY-MM-DD HH:MM:SS.mmm"` (space separator, 3 decimal places, no timezone).

### File Pattern for DuckDB

Single pattern: `'path/to/*.jsonl'`
Multiple patterns: `['pattern1', 'pattern2']`

---

## Verification Checklist

1. [ ] `ccq --help` runs without error (format doesn't need to match Node.js)
2. [ ] Basic query: `SELECT count(*) FROM messages;` returns correct count
3. [ ] All 11 views exist and have correct schemas (`.schema`)
4. [ ] UUID values match between Node.js and Rust outputs
5. [ ] Timestamp formatting matches exactly (no T, no Z, 3 decimal places)
6. [ ] Multi-line input works in REPL
7. [ ] History persists between sessions
8. [ ] Piped mode outputs TSV with `---` separators
9. [ ] Session filter (`-s prefix`) works correctly
10. [ ] All 43 bash tests pass with Rust binary (help test removed)

---

## Files to Reference During Implementation

| Purpose | File |
|---------|------|
| SQL views, value conversion | `/home/danny/code/cc-query/src/query-session.js` |
| File discovery logic | `/home/danny/code/cc-query/src/session-loader.js` |
| REPL, dot commands, help text | `/home/danny/code/cc-query/src/repl.js` |
| Path utilities | `/home/danny/code/cc-query/src/utils.js` |
| CLI args, help text | `/home/danny/code/cc-query/bin/cc-query.js` |
| Test cases (feature spec) | `/home/danny/code/cc-query/test/test-cases.sh` |
| Test fixtures | `/home/danny/code/cc-query/test/fixtures/` |

---

## Additional Implementation Details

### Help Text

**CLI `--help`** - Use clap's default format. Remove the `help` test from bash test suite since help text doesn't need to match exactly.

**REPL `.help`** - Copy content from `/home/danny/code/cc-query/src/repl.js` lines 52-108. Update examples to use `ccq` instead of `cc-query`.

### SQL Views (~250 lines)

The SQL view definitions are in `/home/danny/code/cc-query/src/query-session.js` lines 243-498.
Key details:
- Explicit column schema with 30+ fields and types
- `read_ndjson()` with `columns={...}` for type safety
- Derived fields: `file`, `isAgent`, `agentId`, `project`, `rownum`

During implementation, copy the SQL verbatim or refactor into a `sql/` directory with `.sql` files embedded via `include_str!()`.

### Argument Precedence

When both `--data-dir` and `project_path` are provided:
- `--data-dir` takes precedence (matches Node.js behavior)
- `project_path` is ignored

### Intentional Differences from Node.js

| Aspect | Node.js | Rust | Reason |
|--------|---------|------|--------|
| REPL prompt | `cc-query> ` | `ccq> ` | Matches binary name |
| Binary name | `cc-query` | `ccq` | Shorter, distinct |

These differences don't affect bash tests (which use piped mode, not interactive prompts).

### Error Message Format

The bash test checks exact error message format:
```
Error: No JSONL files found in /nonexistent/path/that/does/not/exist
```

Our `Error::NoSessions` must produce this exact format, or we update the expected test output.

### Edge Cases to Handle

1. **Empty query results** - Output header row with "(0 rows)" footer
2. **Semicolon in string literals** - Simple split on `;` (matches Node.js behavior, doesn't parse SQL)
3. **Very large stdin** - Read all into memory (matches Node.js)
4. **Malformed JSONL** - DuckDB's `ignore_errors=true` skips bad lines

---

## Resolved Questions

1. ✅ **UUID format from duckdb-rs**: Returns `Text(String)` - already formatted, no bit manipulation needed!
2. ✅ **Timestamp TimeUnit**: DuckDB uses `TimeUnit::Microsecond` for TIMESTAMP columns
3. ✅ **CLI help format**: Remove help test from bash suite - use clap's default format

## Remaining Considerations

- **Error messages**: Must match Node.js for test parity (e.g., `"No JSONL files found in {path}"`)
- **Timestamp format**: Verify chrono's `%.3f` produces exactly 3 decimal places (not variable)
