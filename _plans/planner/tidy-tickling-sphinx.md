# Zig Port of cc-query - Updated for Zig 0.15.2

## Overview

Port cc-query from Node.js to Zig with 100% feature parity. The Zig version will live in `zig/` subdirectory and produce a binary named `ccq`.

**Target Zig version:** 0.15.2

---

## Key Changes from Original Plan (Zig 0.14 → 0.15.2)

### Breaking Changes Addressed

| Change | Impact | Migration |
|--------|--------|-----------|
| ArrayList API overhaul | All ArrayList usage | Use `ArrayListUnmanaged`, pass allocator to each method |
| Reader/Writer overhaul ("Writergate") | All I/O code | Use new `std.Io.Writer`/`Reader` with explicit buffers, call `.flush()` |
| `std.io.getStdOut().writer()` deprecated | stdout/stderr writing | Use `std.fs.File.stdout().writer(&buffer)` |
| linenoize incompatible with 0.15 | REPL library | **Manual stdin reading** (pure Zig, no external deps) |
| Format method signature changed | Custom format impls | New `format(self, writer: *std.Io.Writer)` signature |

### Dependencies Updated

| Dependency | Status | Notes |
|------------|--------|-------|
| zuckdb.zig | **Compatible** | Updated for Zig 0.15 (commit Aug 21, 2025) |
| linenoize | **Removed** | Not compatible with 0.15, replaced with manual stdin |

### Critical API Changes Verified

| Old Pattern (0.14) | New Pattern (0.15.2) |
|--------------------|----------------------|
| `std.ArrayList(T).init(alloc)` | `std.ArrayListUnmanaged(T){}` (empty struct literal) |
| `list.append(item)` | `list.append(allocator, item)` |
| `stdout.writer()` | `stdout.writer(&buf).interface` (pointer to interface) |
| `reader.readUntilDelimiter(&buf, '\n')` | `reader.takeDelimiterExclusive('\n')` + `reader.toss(1)` |
| `.name = .@"ccq"` (build.zig.zon) | `.name = "ccq"` (simple string) |

---

## Key Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Binary name | `ccq` | Short, unix-like, help text refers to "cc-query" for compatibility |
| DuckDB integration | [zuckdb.zig](https://github.com/karlseguin/zuckdb.zig) | Well-tested, updated for Zig 0.15 |
| REPL library | **Manual stdin** | Pure Zig, no external deps, linenoize incompatible with 0.15 |
| Architecture | Modular (split query-session.js into 3 modules) | Better separation of concerns |
| ArrayList pattern | `ArrayListUnmanaged{}` | Zig 0.15 pattern: `.{}` init, allocator passed to methods |
| I/O pattern | Explicit buffered I/O | Required by Zig 0.15 Writergate changes |
| Testing | Shared bash tests via `CC_QUERY` env var | Single source of truth |

---

## Directory Structure

```
cc-query/
├── zig/
│   ├── build.zig              # Build configuration
│   ├── build.zig.zon          # Dependencies (zuckdb only)
│   ├── src/
│   │   ├── main.zig           # CLI entry point, arg parsing, orchestration
│   │   ├── types.zig          # Shared types: Config, SessionInfo, FilePattern, errors
│   │   ├── paths.zig          # Path resolution, slug generation, ~ expansion
│   │   ├── session_loader.zig # File discovery, counting (pure functions)
│   │   ├── database.zig       # DuckDB connection wrapper (owns connection only)
│   │   ├── views.zig          # SQL view definitions (pure functions → SQL strings)
│   │   ├── formatter.zig      # Value conversion, table/TSV output formatting
│   │   └── repl.zig           # REPL state machine, piped mode, dot commands
│   ├── tests/                 # Unit tests
│   │   ├── paths_test.zig
│   │   ├── formatter_test.zig
│   │   └── session_loader_test.zig
│   └── README.md              # Build instructions
├── test/
│   ├── test.sh                # Modified: respect CC_QUERY env var
│   └── test-zig.sh            # NEW: Zig-specific test runner
└── justfile                   # Updated with Zig commands
```

---

## Module Responsibilities

| Module | Responsibility | Owns |
|--------|---------------|------|
| `main.zig` | CLI parsing, error display, orchestration | Process lifecycle, I/O buffers |
| `types.zig` | Type definitions, error sets | Nothing (pure types) |
| `paths.zig` | Path resolution, slug generation | Nothing (pure functions) |
| `session_loader.zig` | File discovery, session/agent counting | Nothing (pure functions) |
| `database.zig` | DuckDB connection lifecycle | `zuckdb.DB`, `zuckdb.Conn` |
| `views.zig` | SQL view generation | Nothing (returns SQL strings) |
| `formatter.zig` | Value→string, result→table/TSV | Nothing (pure functions) |
| `repl.zig` | User interaction, history, state machine | History file, input buffer |

---

## Core Types (`types.zig`)

```zig
const std = @import("std");
const Allocator = std.mem.Allocator;

/// CLI configuration - owns nothing, just references
pub const Config = struct {
    session_filter: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    project_path: ?[]const u8 = null,
    help: bool = false,
};

/// File pattern for DuckDB read_ndjson()
pub const FilePattern = union(enum) {
    single: []const u8,
    multiple: []const []const u8,

    /// Zig 0.15: Use ArrayListUnmanaged, pass allocator to methods
    pub fn format(self: FilePattern, allocator: Allocator) ![]const u8 {
        return switch (self) {
            .single => |p| std.fmt.allocPrint(allocator, "'{s}'", .{p}),
            .multiple => |ps| blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};  // Empty struct literal
                defer buf.deinit(allocator);
                try buf.append(allocator, '[');
                for (ps, 0..) |p, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    // Zig 0.15: Use std.fmt.allocPrint, append result
                    const formatted = try std.fmt.allocPrint(allocator, "'{s}'", .{p});
                    try buf.appendSlice(allocator, formatted);
                }
                try buf.append(allocator, ']');
                break :blk try buf.toOwnedSlice(allocator);
            },
        };
    }

    pub fn deinit(self: *FilePattern, allocator: Allocator) void {
        switch (self.*) {
            .single => |s| allocator.free(s),
            .multiple => |ps| {
                for (ps) |p| allocator.free(p);
                allocator.free(ps);
            },
        }
    }
};

/// Session discovery results
pub const SessionInfo = struct {
    session_count: usize,
    agent_count: usize,
    project_count: usize,
    file_pattern: FilePattern,  // Owned, must call deinit
};

/// Errors specific to cc-query
pub const Error = error{
    NoSessions,
    NoJsonlFiles,
    NoHomeDir,
    InvalidPath,
    DatabaseError,
    OutOfMemory,
};

/// REPL state machine
pub const ReplState = enum {
    ready,
    accumulating,  // Multi-line query in progress
};
```

---

## Zig 0.15.2 I/O Patterns

### Standard Output (Writergate)

**Old pattern (0.14) - DEPRECATED:**
```zig
const stdout = std.io.getStdOut().writer();
try stdout.print("Hello {s}\n", .{"world"});
```

**New pattern (0.15.2) - REQUIRED:**
```zig
const stdout_file = std.fs.File.stdout();
var stdout_buf: [4096]u8 = undefined;
var stdout_writer = stdout_file.writer(&stdout_buf);
const stdout = &stdout_writer.interface;  // CRITICAL: Use .interface pointer
defer stdout.flush() catch {};

try stdout.print("Hello {s}\n", .{"world"});
// CRITICAL: Must flush before exit or output may be lost
```

### Standard Error
```zig
const stderr_file = std.fs.File.stderr();
var stderr_buf: [4096]u8 = undefined;
var stderr_writer = stderr_file.writer(&stderr_buf);
const stderr = &stderr_writer.interface;
defer stderr.flush() catch {};

try stderr.print("Error: {s}\n", .{msg});
```

### Standard Input
```zig
const stdin_file = std.fs.File.stdin();
var stdin_buf: [4096]u8 = undefined;
var stdin_reader = stdin_file.reader(&stdin_buf);
const stdin = &stdin_reader.interface;

// Read a line (until newline) - NEW API in 0.15.2
const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
    error.EndOfStream => null,
    else => return err,
};
// MUST toss the delimiter for next read
if (line != null) try stdin.toss(1);
```

### TTY Detection (unchanged)
```zig
const stdin_file = std.fs.File.stdin();
const is_tty = stdin_file.isTty();
```

---

## ArrayList Migration (0.14 → 0.15.2)

### Old pattern (0.14) - DEPRECATED:
```zig
var list = std.ArrayList(u8).init(allocator);
defer list.deinit();
try list.append('x');
try list.appendSlice("hello");
```

### New pattern (0.15.2) - REQUIRED:
```zig
var list: std.ArrayListUnmanaged(u8) = .{};  // Empty struct literal
defer list.deinit(allocator);
try list.append(allocator, 'x');
try list.appendSlice(allocator, "hello");
const slice = try list.toOwnedSlice(allocator);
```

**Key differences:**
- Initialize with `.{}` (empty struct literal) instead of `.init(allocator)`
- Pass `allocator` to every mutating method
- `deinit(allocator)` instead of `deinit()`

---

## Memory Management Strategy

**Allocator pattern:** Use arena allocators for query-scoped allocations:

```zig
// Per-query arena - all results freed together when query completes
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();
const result = try qs.query(arena.allocator(), sql);
// Print result... arena.deinit() frees everything
```

**Ownership model:**

| Data | Lifetime | Allocator | Owner |
|------|----------|-----------|-------|
| `Config` | Process | Stack | `main.zig` |
| `SessionInfo.file_pattern` | Session | GPA | `main.zig` (call `deinit`) |
| SQL view strings | Session | Arena | `main.zig` |
| Query result strings | Per-query | Arena | REPL loop (reset after output) |
| History entries | REPL session | GPA | `repl.zig` |
| I/O buffers | Process | Stack | `main.zig` (fixed-size arrays) |

**Critical: zuckdb.zig value lifetime**
- Values from `row.get()` are only valid until the next `rows.next()` call
- ALL string values must be copied immediately: `try allocator.dupe(u8, str)`

---

## Error Handling Strategy (Zig 0.15.2)

### Key Zig 0.15.2 Error Facts

- `std.Io.Writer.Error` is essentially `anyerror` (the global error set)
- CLI apps should return errors from `main()` - Zig exits with code 1 automatically
- Use `errdefer` for cleanup when errors occur
- Use `std.debug.print()` for error messages (writes to stderr)

### Error Message Parity

Must match Node exactly:
- `"Error: No JSONL files found in {path}"` (for --data-dir)
- `"Error: No Claude Code data found for {path}"` (for project path)
- `"Error: No Claude Code sessions found"` (for all projects)

### CLI Error Handling Pattern

```zig
pub fn main() !void {
    // ... setup ...
    run() catch |err| {
        // Use std.debug.print for errors (writes to stderr, no buffering needed)
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run() !void {
    // Flush can use catch {} in defers (defer runs even on error paths)
    defer stdout.flush() catch {};

    // Propagate errors with try
    const session_info = try getSessionFiles(allocator, project_dir, filter, .{});
    errdefer session_info.file_pattern.deinit(allocator);

    // ...
}
```

### DuckDB Error Extraction

```zig
fn printError(conn: *zuckdb.Conn) void {
    if (conn.err) |msg| {
        const error_msg = std.mem.span(msg);
        // Use debug.print - no buffering, writes directly to stderr
        std.debug.print("Error: {s}\n", .{error_msg});
    }
}

// Usage in query execution
fn executeQuery(db: *Database, sql: []const u8) !ResultSet {
    const rows = db.conn.query(sql, .{}) catch |err| {
        printError(&db.conn);
        return err;
    };
    // ...
}
```

### Critical Flush Pattern

```zig
// GOOD: Deferred flush with catch {} for cleanup paths
defer stdout.flush() catch {};

// GOOD: Explicit flush before critical output completion
try stdout.print("Query results:\n", .{});
try stdout.flush();  // Ensure visible before blocking operation

// BAD: Forgetting flush - output may be lost
stdout.print("Hello\n", .{}) catch {};
// Missing flush! Output may not appear
```

---

## Implementation Phases

### Phase 0: Pre-requisites

1. **Modify `test/test.sh` line 10:**
   ```bash
   # Change from:
   CC_QUERY="$SCRIPT_DIR/../bin/cc-query.js"
   # To:
   CC_QUERY="${CC_QUERY:-$SCRIPT_DIR/../bin/cc-query.js}"
   ```

2. **Add to `.gitignore`:**
   ```
   zig/zig-out/
   zig/zig-cache/
   zig/.zig-cache/
   ```

### Phase 1: Project Scaffolding

**Goal:** Zig project compiles and links to DuckDB

**Files to create:**
- `zig/build.zig` - Build configuration with zuckdb.zig dependency
- `zig/build.zig.zon` - Package manifest
- `zig/src/main.zig` - Minimal "Hello World" that opens DuckDB in-memory
- `zig/src/types.zig` - Core type definitions

**build.zig.zon (Zig 0.15.2):**
```zig
.{
    .name = "ccq",  // Simple string, NOT .@"ccq"
    .version = "0.1.0",
    .paths = .{ "build.zig", "build.zig.zon", "src" },
    .dependencies = .{
        .zuckdb = .{
            .url = "git+https://github.com/karlseguin/zuckdb.zig#master",
            .hash = "...",  // Use: zig fetch --save git+https://github.com/karlseguin/zuckdb.zig
        },
    },
}
```

**build.zig (Zig 0.15.2):**
```zig
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zuckdb = b.dependency("zuckdb", .{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "ccq",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    exe.root_module.addImport("zuckdb", zuckdb.module("zuckdb"));
    exe.linkLibC();  // Required for DuckDB

    b.installArtifact(exe);

    // Run step
    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
    const run_step = b.step("run", "Run ccq");
    run_step.dependOn(&run_cmd.step);

    // Test step
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    unit_tests.root_module.addImport("zuckdb", zuckdb.module("zuckdb"));

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
```

**Verification:**
```bash
cd zig && zig build
./zig-out/bin/ccq --help  # Should print placeholder help
```

### Phase 2: Path Utilities (`paths.zig`)

**Goal:** Path resolution matching Node behavior exactly

**Functions to implement:**
```zig
/// Expand ~ to home directory, resolve relative paths
pub fn resolveProjectPath(allocator: Allocator, path: []const u8) ![]const u8

/// Generate project slug: /path/to/project → -path-to-project
pub fn getProjectSlug(allocator: Allocator, path: []const u8) ![]const u8

/// Combine: resolve path + generate slug + return claude projects dir
pub fn resolveProjectDir(allocator: Allocator, path: []const u8) !struct {
    project_path: []const u8,
    claude_projects_dir: []const u8
}
```

**Key details:**
- Use `std.fs.path` for path operations
- Use `std.posix.getenv("HOME")` for home directory
- Check `CLAUDE_PROJECT_DIR` env var for relative path resolution

**Verification:** Unit tests comparing output to Node version

### Phase 3: Session Loader (`session_loader.zig`)

**Goal:** File discovery with identical counting to Node

**Functions to implement (Zig 0.15.2 patterns):**
```zig
/// Returns ~/.claude/projects
pub fn getClaudeProjectsBase(allocator: Allocator) ![]const u8

/// List all project directories
pub fn getAllProjectDirs(allocator: Allocator) ![][]const u8

/// Count sessions and agents from file list
fn countSessionsAndAgents(files: []const []const u8, session_filter: ?[]const u8) struct {
    sessions: usize,
    agents: usize,
}

/// Main function: discover files and build glob patterns
pub fn getSessionFiles(
    allocator: Allocator,
    claude_projects_dir: ?[]const u8,
    session_filter: ?[]const u8,
    options: struct { data_dir: ?[]const u8 = null },
) !SessionInfo
```

**Key details:**
- Session file: `{sessionId}.jsonl` (top-level, no `agent-` prefix)
- Agent file: `{sessionId}/subagents/agent-{agentId}.jsonl`
- Return glob patterns for DuckDB (not actual file list)

**Zig 0.15.2 Directory Iteration Pattern:**
```zig
fn findJsonlFiles(allocator: Allocator, base_path: []const u8) ![][]const u8 {
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    // CRITICAL: Must use .iterate = true for Linux compatibility
    var dir = try std.fs.openDirAbsolute(base_path, .{ .iterate = true });
    defer dir.close();

    // Use walk() for recursive traversal
    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".jsonl")) {
            // CRITICAL: Must copy entry.path - it's reused on next iteration
            const full_path = try std.fs.path.join(allocator, &.{ base_path, entry.path });
            try files.append(allocator, full_path);
        }
    }

    return try files.toOwnedSlice(allocator);
}
```

**Critical Notes:**
- `.iterate = true` is REQUIRED when opening dirs on Linux (works without on macOS, causing platform bugs)
- `walker.next()` reuses the `entry.path` buffer - MUST copy if storing
- Use `std.mem.endsWith` for file extension matching (no built-in glob)
- Non-recursive: use `dir.iterate()` instead of `dir.walk()`

### Phase 4: SQL Views (`views.zig`)

**Goal:** Embedded SQL matching Node's view definitions exactly

**Port all 11 views from `src/query-session.js` lines 243-498:**

| View | Purpose |
|------|---------|
| `messages` | Base view with 40+ columns + derived fields |
| `user_messages` | Filtered to `type = 'user'` |
| `assistant_messages` | Filtered to `type = 'assistant'` |
| `system_messages` | Filtered to `type = 'system'` |
| `human_messages` | User text content (excludes tool results) |
| `raw_messages` | Full JSON via `read_ndjson_objects()` |
| `tool_uses` | LATERAL UNNEST of tool_use blocks |
| `tool_results` | LATERAL UNNEST of tool_result blocks with duration |
| `token_usage` | Extracted token counts |
| `bash_commands` | Bash tool uses with command |
| `file_operations` | Read/Write/Edit/Glob/Grep with paths |

**Critical derived fields:**
```sql
file = regexp_extract(filename, '[^/]+$')
isAgent = starts_with(file, 'agent-')
agentId = CASE WHEN isAgent THEN regexp_extract(file, 'agent-([^.]+)', 1) ELSE NULL END
project = regexp_extract(filename, '/projects/([^/]+)/', 1)
rownum = ordinality
```

**Path escaping for SQL:**
```zig
fn escapePathForSql(allocator: Allocator, path: []const u8) ![]const u8 {
    // Replace ' with '' (SQL escaping)
    var result: std.ArrayListUnmanaged(u8) = .{};  // Empty struct literal
    errdefer result.deinit(allocator);
    for (path) |c| {
        if (c == '\'') {
            try result.appendSlice(allocator, "''");
        } else {
            try result.append(allocator, c);
        }
    }
    return try result.toOwnedSlice(allocator);
}
```

### Phase 5: Database Wrapper (`database.zig`)

**Goal:** DuckDB wrapper with three output modes

```zig
pub const Database = struct {
    db: zuckdb.DB,
    conn: zuckdb.Conn,

    pub fn init(allocator: Allocator) !Database { ... }
    pub fn exec(self: *Database, sql: []const u8) !void { ... }
    pub fn query(self: *Database, allocator: Allocator, sql: []const u8) !ResultSet { ... }
    pub fn deinit(self: *Database) void { ... }
};

pub const ResultSet = struct {
    columns: [][]const u8,
    rows: [][][]const u8,

    pub fn deinit(self: *ResultSet, allocator: Allocator) void {
        for (self.rows) |row| {
            for (row) |cell| allocator.free(cell);
            allocator.free(row);
        }
        allocator.free(self.rows);
        for (self.columns) |col| allocator.free(col);
        allocator.free(self.columns);
    }
};
```

**Column type handling:**

```zig
fn formatRow(allocator: Allocator, row: zuckdb.Row, rows: *zuckdb.Rows) ![][]const u8 {
    const col_count = rows.columnCount();
    var cells = try allocator.alloc([]const u8, col_count);

    for (0..col_count) |i| {
        const col_type = rows.columnType(i);
        cells[i] = switch (col_type) {
            .varchar => blk: {
                const val = row.get(?[]const u8, i) orelse break :blk try allocator.dupe(u8, "NULL");
                break :blk try allocator.dupe(u8, val);  // MUST copy before next()
            },
            .bigint => try std.fmt.allocPrint(allocator, "{d}", .{row.get(i64, i)}),
            .integer => try std.fmt.allocPrint(allocator, "{d}", .{row.get(i32, i)}),
            .timestamp => try formatTimestamp(allocator, row.get(i64, i)),
            .uuid => blk: {
                const uuid_buf = row.get(zuckdb.UUID, i);
                break :blk try allocator.dupe(u8, &uuid_buf);
            },
            .boolean => blk: {
                const val = row.get(?bool, i) orelse break :blk try allocator.dupe(u8, "NULL");
                break :blk if (val) try allocator.dupe(u8, "true") else try allocator.dupe(u8, "false");
            },
            .double => try std.fmt.allocPrint(allocator, "{d}", .{row.get(f64, i)}),
            else => try allocator.dupe(u8, "?"),
        };
    }
    return cells;
}
```

### Phase 6: Value Formatting (`formatter.zig`)

**Goal:** Output matches Node exactly

**Timestamp formatting:** `"YYYY-MM-DD HH:MM:SS.mmm"` (space separator, NO 'T', NO 'Z')

```zig
fn formatTimestamp(allocator: Allocator, micros: i64) ![]const u8 {
    const ms = @divFloor(micros, 1000);
    const epoch_seconds: u64 = @intCast(@divFloor(ms, 1000));
    const remaining_ms: u64 = @intCast(@mod(ms, 1000));

    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day_seconds = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();

    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(allocator,
        "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            hour, minute, second, remaining_ms,
        },
    );
}
```

**Table formatting (Zig 0.15.2 - buffered writer):**
```zig
pub fn formatTable(
    writer: *std.Io.Writer,  // Concrete type, not anytype
    result: *const ResultSet,
) !void {
    // Box-drawing characters: ┌ ┐ └ ┘ ├ ┤ ┬ ┴ ┼ │ ─
    // Column width = max(header_width, max_data_width)
    // Footer: `(N row)` or `(N rows)`

    // ... implementation ...

    // Zig 0.15.2: Caller is responsible for flush
}
```

**TSV formatting:**
- Tab-separated values
- Header row with column names
- `---` separator between multiple queries

### Phase 7: REPL (`repl.zig`) - Manual Stdin Implementation

**Goal:** Interactive and piped modes WITHOUT external readline library

**State machine:**
```zig
pub const Repl = struct {
    state: ReplState,
    buffer: std.ArrayListUnmanaged(u8),  // Multi-line accumulator (0.15 pattern)
    db: *Database,
    allocator: Allocator,
    history: std.ArrayListUnmanaged([]const u8),  // Manual history
    history_path: []const u8,

    pub fn init(allocator: Allocator, db: *Database) !Repl {
        return .{
            .state = .ready,
            .buffer = .{},  // Empty struct literal (not .empty)
            .db = db,
            .allocator = allocator,
            .history = .{},  // Empty struct literal
            .history_path = try getHistoryPath(allocator),
        };
    }

    pub fn run(self: *Repl, session_info: SessionInfo) !void { ... }

    pub fn deinit(self: *Repl) void {
        self.buffer.deinit(self.allocator);
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit(self.allocator);
        self.allocator.free(self.history_path);
    }
};
```

**State transitions:**
- `ready` + input without `;` → `accumulating`
- `accumulating` + input with `;` → execute → `ready`
- `ready` + `.command` → handle → `ready`

**TTY detection (unchanged in 0.15):**
```zig
const stdin_file = std.fs.File.stdin();
const is_tty = stdin_file.isTty();
```

**Two execution paths:**

**Piped mode** (`!is_tty`):
```zig
fn runPipedMode(self: *Repl, stdout: *std.Io.Writer, stderr: *std.Io.Writer) !void {
    const stdin_file = std.fs.File.stdin();
    var stdin_buf: [8192]u8 = undefined;
    var stdin_reader = stdin_file.reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    // Read all input
    var input: std.ArrayListUnmanaged(u8) = .{};  // Empty struct literal
    defer input.deinit(self.allocator);

    while (true) {
        // Zig 0.15.2: Use takeDelimiterExclusive + toss
        const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        try input.appendSlice(self.allocator, line);
        try input.append(self.allocator, '\n');
        try stdin.toss(1);  // Consume the newline delimiter
    }

    // Split by `;` keeping semicolon with statement
    // Execute each statement with TSV output
    // Separator between queries: `---`
    // Handle dot commands (lines starting with `.`)
}
```

**Interactive mode** (`is_tty`):
```zig
fn runInteractiveMode(self: *Repl, stdout: *std.Io.Writer, stderr: *std.Io.Writer, session_info: SessionInfo) !void {
    // Print banner
    try stdout.print("Loaded {d} project(s), {d} session(s), {d} agent file(s)\n", .{
        session_info.project_count,
        session_info.session_count,
        session_info.agent_count,
    });
    try stdout.flush();

    // Load history
    self.loadHistory() catch {};
    defer self.saveHistory() catch {};

    const stdin_file = std.fs.File.stdin();
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = stdin_file.reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    while (true) {
        // Print prompt
        const prompt = if (self.state == .ready) "cc-query> " else "      -> ";
        try stdout.print("{s}", .{prompt});
        try stdout.flush();

        // Read line (basic - no arrow keys without readline library)
        // Zig 0.15.2: Use takeDelimiterExclusive + toss
        const line = stdin.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };

        // Add to history
        if (line.len > 0) {
            const saved = try self.allocator.dupe(u8, line);
            try self.history.append(self.allocator, saved);
        }

        // Consume the newline delimiter
        stdin.toss(1) catch {};

        // Process line...
    }
}
```

**History file management (manual):**
```zig
fn loadHistory(self: *Repl) !void {
    const file = std.fs.openFileAbsolute(self.history_path, .{}) catch return;
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(&buf);
    const reader = &file_reader.interface;

    while (true) {
        // Zig 0.15.2: takeDelimiterExclusive + toss
        const line = reader.takeDelimiterExclusive('\n') catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        const saved = try self.allocator.dupe(u8, line);
        try self.history.append(self.allocator, saved);
        reader.toss(1) catch break;  // Consume newline
    }
}

fn saveHistory(self: *Repl) !void {
    const file = try std.fs.createFileAbsolute(self.history_path, .{});
    defer file.close();

    var buf: [4096]u8 = undefined;
    var file_writer = file.writer(&buf);
    const writer = &file_writer.interface;

    // Save last 100 entries
    const start = if (self.history.items.len > 100) self.history.items.len - 100 else 0;
    for (self.history.items[start..]) |entry| {
        try writer.print("{s}\n", .{entry});
    }
    try writer.flush();
}

fn getHistoryPath(allocator: Allocator) ![]const u8 {
    const home = std.posix.getenv("HOME") orelse return error.NoHomeDir;
    return std.fmt.allocPrint(allocator, "{s}/.cc_query_history", .{home});
}
```

**Dot commands:**
- `.help`, `.h` → help text (must match Node exactly)
- `.schema`, `.s` → all view schemas
- `.schema <view>`, `.s <view>` → specific view
- `.quit`, `.exit`, `.q` → exit

### Phase 8: CLI Entry Point (`main.zig`)

**Goal:** Argument parsing matching Node behavior

**Main function (Zig 0.15.2 I/O):**
```zig
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Zig 0.15.2: Set up buffered I/O with .interface pattern
    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;  // Use .interface pointer
    defer stdout.flush() catch {};

    const stderr_file = std.fs.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = stderr_file.writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // Parse args
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = try parseArgs(args);

    if (config.help) {
        try printHelp(stdout);
        return;
    }

    // ... rest of initialization ...
}
```

**Arguments:**
```
ccq [options] [project-path]

Options:
  -s, --session <prefix>  Filter to sessions matching ID prefix
  -d, --data-dir <dir>    Use directory directly as JSONL source
  -h, --help              Show help
```

**Help text:** Use "cc-query" in help text (matching Node) for test parity.

### Phase 9: Test Integration

**Modify `test/test.sh` line 10:**
```bash
CC_QUERY="${CC_QUERY:-$SCRIPT_DIR/../bin/cc-query.js}"
```

**New file: `test/test-zig.sh`**
```bash
#!/bin/bash
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CC_QUERY="$SCRIPT_DIR/../zig/zig-out/bin/ccq" exec "$SCRIPT_DIR/test.sh"
```

**Update `justfile`:**
```makefile
zig-build:
    cd zig && zig build

zig-test: zig-build
    test/test-zig.sh

zig-release:
    cd zig && zig build -Doptimize=ReleaseFast

test-all: test zig-test
```

---

## Unit Testing Strategy

```zig
// zig/tests/paths_test.zig
test "resolveProjectPath expands tilde" {
    const result = try resolveProjectPath(testing.allocator, "~/code/foo");
    defer testing.allocator.free(result);
    try testing.expect(!std.mem.startsWith(u8, result, "~"));
}

test "getProjectSlug replaces slashes and dots" {
    const result = try getProjectSlug(testing.allocator, "/home/user/my.project");
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("-home-user-my-project", result);
}

// zig/tests/formatter_test.zig
test "formatTimestamp matches Node output" {
    const micros: i64 = 1736039614310000;  // 2025-01-05 01:13:34.310
    const result = try formatTimestamp(testing.allocator, micros);
    defer testing.allocator.free(result);
    try testing.expectEqualStrings("2025-01-05 01:13:34.310", result);
}

// zig/tests/session_loader_test.zig
test "countSessionsAndAgents distinguishes file types" {
    const files = &[_][]const u8{
        "abc123.jsonl",
        "abc123/subagents/agent-xyz.jsonl",
        "def456.jsonl",
    };
    const counts = countSessionsAndAgents(files, null);
    try testing.expectEqual(@as(usize, 2), counts.sessions);
    try testing.expectEqual(@as(usize, 1), counts.agents);
}
```

Run with: `cd zig && zig build test`

---

## Files to Modify

| File | Change |
|------|--------|
| `test/test.sh` | Line 10: respect `CC_QUERY` env var |
| `justfile` | Add `zig-build`, `zig-test`, `zig-release`, `test-all` |
| `.gitignore` | Add `zig/zig-out/`, `zig/zig-cache/`, `zig/.zig-cache/` |

## Files to Create

| File | Based On |
|------|----------|
| `zig/build.zig` | New (Zig 0.15.2 build system) |
| `zig/build.zig.zon` | New (Zig 0.15.2 package manifest) |
| `zig/src/main.zig` | `bin/cc-query.js` |
| `zig/src/types.zig` | New (centralized types) |
| `zig/src/paths.zig` | `src/utils.js` |
| `zig/src/session_loader.zig` | `src/session-loader.js` |
| `zig/src/database.zig` | `src/query-session.js` (connection only) |
| `zig/src/views.zig` | `src/query-session.js` lines 243-498 |
| `zig/src/formatter.zig` | `src/query-session.js` (formatting only) |
| `zig/src/repl.zig` | `src/repl.js` (manual stdin, no linenoize) |
| `test/test-zig.sh` | New |

---

## Critical Line References

| Feature | JS File | Lines |
|---------|---------|-------|
| CLI args & help | `bin/cc-query.js` | 6-58 |
| Error messages | `bin/cc-query.js` | 84-96 |
| Value formatting | `src/query-session.js` | 16-40 |
| Table/TSV output | `src/query-session.js` | 47-113 |
| SQL views (all 11) | `src/query-session.js` | 243-498 |
| Session counting | `src/session-loader.js` | 29-59 |
| File discovery | `src/session-loader.js` | 68-193 |
| REPL help text | `src/repl.js` | 52-108 |
| Dot commands | `src/repl.js` | 133-176 |
| Multi-line input | `src/repl.js` | 279-325 |
| Path resolution | `src/utils.js` | 9-16 |
| Slug generation | `src/utils.js` | 23-25 |

---

## Risk Areas & Mitigations

| Risk | Severity | Mitigation |
|------|----------|------------|
| Zig 0.15.2 I/O complexity | High | Use `.interface` pointer pattern, always flush before exit |
| Missing `.flush()` calls | High | Use `defer stdout.flush() catch {};` pattern at function start |
| Wrong ArrayList init (`.empty` vs `.{}`) | High | Use `.{}` empty struct literal, NOT `.empty` |
| Wrong reader API (`readUntilDelimiter`) | High | Use `takeDelimiterExclusive('\n')` + `toss(1)` |
| Missing readline features | Medium | Document limitations (no arrow keys in interactive mode) |
| Value lifetime bugs (use-after-next) | High | Strict discipline: copy all strings immediately |
| Timestamp format mismatch | Medium | Unit test with known micros → expected string |
| Path escaping SQL injection | Medium | Implement proper `'` → `''` escaping |
| Memory leaks | Medium | Use arena allocators; test with GPA leak detection |
| Large result sets OOM | Low | Implement streaming for >10k rows |
| `std.posix.getenv` platform limits | Low | Only affects WASI/Windows; cc-query targets Unix |
| Missing `.iterate = true` in openDir | High | Causes panic on Linux; always include when iterating |
| Walker path buffer reuse | High | MUST copy `entry.path` before storing; reused on `next()` |

---

## Verification Checklist

### Build & Unit Tests
- [ ] `cd zig && zig build` compiles without errors
- [ ] `cd zig && zig build test` passes all unit tests

### CLI Parity
- [ ] `ccq --help` output matches `cc-query --help` exactly
- [ ] `-s <prefix>` filters sessions correctly
- [ ] `-d <dir>` uses custom data directory
- [ ] Exit codes match (0 success, 1 error)

### Query Output Parity
- [ ] TSV format matches (header + tabs + newlines)
- [ ] Box-drawing table renders correctly
- [ ] Multiple query separator `---` works
- [ ] Value formatting: NULL, UUID, timestamp, bigint, JSON

### REPL Parity
- [ ] `.help` output matches
- [ ] `.schema` lists all 11 views
- [ ] `.schema <view>` shows specific view columns
- [ ] `.quit` / `.q` / `.exit` all exit
- [ ] Multi-line input accumulates until `;`
- [ ] History persists to `~/.cc_query_history`

### Known Limitations (Manual REPL)
- [ ] No arrow key navigation (requires readline library)
- [ ] No in-line editing (requires readline library)
- [ ] Basic history (save/load only, no search)

### Integration Tests
- [ ] `just zig-test` passes all test cases
- [ ] `just test-all` runs both Node and Zig tests

### End-to-End Verification
```bash
# Build
cd zig && zig build

# Compare outputs
diff <(../bin/cc-query.js --help) <(./zig-out/bin/ccq --help)

# Run full test suite
cd ../test
CC_QUERY=../zig/zig-out/bin/ccq ./test.sh

# Interactive smoke test
./zig-out/bin/ccq -d ../test/fixtures
cc-query> SELECT count(*) FROM messages;
cc-query> .schema
cc-query> .quit
```

---

## Sources

- [Zig 0.15.1 Release Notes](https://ziglang.org/download/0.15.1/release-notes.html)
- [Zig 0.15 Migration Roadblocks](https://sngeth.com/zig/systems-programming/breaking-changes/2025/10/24/zig-0-15-migration-roadblocks/)
- [Zig 0.15.1 I/O Overhaul](https://dev.to/bkataru/zig-0151-io-overhaul-understanding-the-new-reader-writer-interfaces-30oe)
- [ArrayList Migration Discussion](https://ziggit.dev/t/arraylist-and-allocator-updating-code-to-0-15/12167)
- [zuckdb.zig](https://github.com/karlseguin/zuckdb.zig) - Updated for Zig 0.15
- [linenoize](https://github.com/joachimschmidt557/linenoize) - Still at 0.14, not used
