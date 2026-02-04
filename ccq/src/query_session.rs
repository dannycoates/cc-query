//! `DuckDB` query session management.

use std::io::Write;
use std::path::Path;

use duckdb::Connection;

use crate::session_loader::{self, FilePattern, SessionInfo};
use crate::{formatter, Error, Result};

/// Query result with column names and row data.
#[derive(Debug, Clone)]
pub struct QueryResult {
    columns: Vec<String>,
    rows: Vec<Vec<String>>,
}

impl QueryResult {
    /// Column names from the query.
    pub fn columns(&self) -> &[String] {
        &self.columns
    }

    /// Row data as strings.
    pub fn rows(&self) -> &[Vec<String>] {
        &self.rows
    }

    /// Number of rows returned.
    pub const fn row_count(&self) -> usize {
        self.rows.len()
    }

    /// Format as a table with Unicode box-drawing characters.
    pub fn to_table(&self) -> String {
        formatter::format_table(&self.columns, &self.rows)
    }

    /// Format as tab-separated values.
    pub fn to_tsv(&self) -> String {
        formatter::format_tsv(&self.columns, &self.rows)
    }
}

/// `DuckDB` session with pre-configured views over JSONL session data.
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
                path: data_dir.map_or_else(
                    || project_dir.map(Path::to_path_buf).unwrap_or_default(),
                    Path::to_path_buf,
                ),
            });
        }

        let conn = Connection::open_in_memory()?;
        let sql = Self::build_create_views_sql(info.file_pattern());
        conn.execute_batch(&sql)?;

        Ok(Self { conn, info })
    }

    /// Session information (counts, patterns).
    pub const fn info(&self) -> &SessionInfo {
        &self.info
    }

    /// Execute a SQL query and return results.
    ///
    /// # Errors
    /// Returns error if the query fails.
    pub fn query(&self, sql: &str) -> Result<QueryResult> {
        let mut stmt = self.conn.prepare(sql)?;

        // Execute query first
        let mut rows_iter = stmt.query([])?;

        // Get column info after execution
        let column_count = rows_iter
            .as_ref()
            .map_or(0, duckdb::Statement::column_count);

        // Get column names
        let columns: Vec<String> = (0..column_count)
            .map(|i| {
                rows_iter
                    .as_ref()
                    .and_then(|s| s.column_name(i).ok())
                    .map_or_else(|| "?".to_string(), String::clone)
            })
            .collect();

        // Collect rows
        let mut rows = Vec::new();

        while let Some(row) = rows_iter.next()? {
            let mut row_data = Vec::with_capacity(column_count);
            for i in 0..column_count {
                // Use DisplayValueRef to avoid intermediate Value allocation
                row_data.push(formatter::DisplayValueRef(&row.get_ref(i)?).to_string());
            }
            rows.push(row_data);
        }

        Ok(QueryResult { columns, rows })
    }

    /// Execute a SQL query and stream TSV results directly to a writer.
    ///
    /// This method avoids collecting all rows in memory, making it suitable
    /// for large result sets in piped mode.
    ///
    /// # Errors
    /// Returns error if the query fails or writing fails.
    pub fn query_tsv_streaming<W: Write>(&self, sql: &str, mut writer: W) -> Result<usize> {
        let mut stmt = self.conn.prepare(sql)?;
        let mut rows_iter = stmt.query([])?;
        let column_count = rows_iter
            .as_ref()
            .map_or(0, duckdb::Statement::column_count);

        // Write header
        let columns: Vec<_> = (0..column_count)
            .map(|i| {
                rows_iter
                    .as_ref()
                    .and_then(|s| s.column_name(i).ok())
                    .map_or_else(|| "?".to_string(), String::clone)
            })
            .collect();
        writeln!(writer, "{}", columns.join("\t"))?;

        // Stream rows - no per-cell allocations!
        let mut row_count = 0;
        while let Some(row) = rows_iter.next()? {
            for i in 0..column_count {
                if i > 0 {
                    write!(writer, "\t")?;
                }
                // DisplayValueRef writes directly to writer, no intermediate String
                write!(writer, "{}", formatter::DisplayValueRef(&row.get_ref(i)?))?;
            }
            writeln!(writer)?;
            row_count += 1;
        }
        Ok(row_count)
    }

    /// Generate SQL to create all 11 views.
    #[allow(clippy::too_many_lines)]
    fn build_create_views_sql(pattern: &FilePattern) -> String {
        let pattern_sql = pattern.to_string();

        // Explicit column schema for type safety
        let columns_def = [
            "'uuid': 'UUID'",
            "'type': 'VARCHAR'",
            "'subtype': 'VARCHAR'",
            "'parentUuid': 'UUID'",
            "'timestamp': 'TIMESTAMP'",
            "'sessionId': 'UUID'",
            "'cwd': 'VARCHAR'",
            "'gitBranch': 'VARCHAR'",
            "'slug': 'VARCHAR'",
            "'version': 'VARCHAR'",
            "'isSidechain': 'BOOLEAN'",
            "'userType': 'VARCHAR'",
            "'message': 'JSON'",
            "'isCompactSummary': 'BOOLEAN'",
            "'isMeta': 'BOOLEAN'",
            "'isVisibleInTranscriptOnly': 'BOOLEAN'",
            "'sourceToolUseID': 'VARCHAR'",
            "'thinkingMetadata': 'JSON'",
            "'todos': 'JSON'",
            "'toolUseResult': 'JSON'",
            "'error': 'JSON'",
            "'isApiErrorMessage': 'BOOLEAN'",
            "'requestId': 'VARCHAR'",
            "'sourceToolAssistantUUID': 'UUID'",
            "'content': 'VARCHAR'",
            "'compactMetadata': 'JSON'",
            "'hasOutput': 'BOOLEAN'",
            "'hookCount': 'INTEGER'",
            "'hookErrors': 'JSON'",
            "'hookInfos': 'JSON'",
            "'level': 'VARCHAR'",
            "'logicalParentUuid': 'UUID'",
            "'maxRetries': 'INTEGER'",
            "'preventedContinuation': 'BOOLEAN'",
            "'retryAttempt': 'INTEGER'",
            "'retryInMs': 'INTEGER'",
            "'stopReason': 'VARCHAR'",
            "'toolUseID': 'VARCHAR'",
        ]
        .join(", ");

        format!(
            r"
    -- Base messages view with explicit schema for type safety
    CREATE OR REPLACE VIEW messages AS
    SELECT
      uuid,
      type,
      subtype,
      parentUuid,
      timestamp,
      sessionId,
      cwd,
      gitBranch,
      slug,
      version,
      isSidechain,
      userType,
      message,
      isCompactSummary,
      isMeta,
      isVisibleInTranscriptOnly,
      sourceToolUseID,
      sourceToolAssistantUUID,
      thinkingMetadata,
      todos,
      toolUseResult,
      error,
      isApiErrorMessage,
      requestId,
      content,
      compactMetadata,
      hasOutput,
      hookCount,
      hookErrors,
      hookInfos,
      level,
      logicalParentUuid,
      maxRetries,
      preventedContinuation,
      retryAttempt,
      retryInMs,
      stopReason,
      toolUseID,
      -- Derived fields
      regexp_extract(filename, '[^/]+$') as file,
      starts_with(regexp_extract(filename, '[^/]+$'), 'agent-') as isAgent,
      CASE WHEN starts_with(regexp_extract(filename, '[^/]+$'), 'agent-')
           THEN regexp_extract(regexp_extract(filename, '[^/]+$'), 'agent-([^.]+)', 1)
           ELSE NULL
      END as agentId,
      -- Extract project slug (directory after /projects/)
      regexp_extract(filename, '/projects/([^/]+)/', 1) as project,
      ordinality as rownum
    FROM read_ndjson(
      {pattern_sql},
      filename=true,
      ignore_errors=true,
      columns={{{columns_def}}}
    ) WITH ORDINALITY
    WHERE type IN ('user', 'assistant', 'system');

    -- User messages view
    CREATE OR REPLACE VIEW user_messages AS
    SELECT
      uuid, parentUuid, timestamp, sessionId, cwd, gitBranch, slug, version,
      isSidechain, userType, message, isCompactSummary, isMeta,
      isVisibleInTranscriptOnly, sourceToolUseID, sourceToolAssistantUUID,
      thinkingMetadata, todos, toolUseResult, file, isAgent, agentId, project, rownum
    FROM messages
    WHERE type = 'user';

    -- Human-typed messages (excludes tool results and system-injected text)
    CREATE OR REPLACE VIEW human_messages AS
    SELECT
      uuid, parentUuid, timestamp, sessionId, cwd, gitBranch, slug, version,
      isSidechain, message->>'content' as content, file, project, rownum
    FROM user_messages
    WHERE json_type(message->'content') = 'VARCHAR'
      AND (agentId IS NULL OR agentId = '')
      AND (isMeta IS NULL OR isMeta = false);

    -- Assistant messages view
    CREATE OR REPLACE VIEW assistant_messages AS
    SELECT
      uuid, parentUuid, timestamp, sessionId, cwd, gitBranch, slug, version,
      isSidechain, userType, message, error, isApiErrorMessage, requestId,
      file, isAgent, agentId, project, rownum
    FROM messages
    WHERE type = 'assistant';

    -- System messages view
    CREATE OR REPLACE VIEW system_messages AS
    SELECT
      uuid, subtype, parentUuid, timestamp, sessionId, cwd, gitBranch, slug,
      version, isSidechain, userType, content, error, compactMetadata,
      hasOutput, hookCount, hookErrors, hookInfos, level, logicalParentUuid,
      maxRetries, preventedContinuation, retryAttempt, retryInMs, stopReason,
      toolUseID, isMeta, file, isAgent, agentId, project, rownum
    FROM messages
    WHERE type = 'system';

    -- Raw messages view with full JSON string
    CREATE OR REPLACE VIEW raw_messages AS
    SELECT
      (json->>'uuid')::UUID as uuid,
      json as raw
    FROM read_ndjson_objects({pattern_sql}, ignore_errors=true)
    WHERE json->>'uuid' IS NOT NULL AND length(json->>'uuid') > 0;

    -- Tool uses: All tool calls with unnested content blocks
    CREATE OR REPLACE VIEW tool_uses AS
    SELECT
      m.uuid,
      m.timestamp,
      m.sessionId,
      m.isAgent,
      m.agentId,
      m.project,
      m.rownum,
      block->>'name' as tool_name,
      block->>'id' as tool_id,
      block->'input' as tool_input,
      row_number() OVER (PARTITION BY m.uuid ORDER BY (SELECT NULL)) - 1 as block_index
    FROM assistant_messages m,
    LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
    WHERE block->>'type' = 'tool_use';

    -- Tool results: All tool results with duration
    CREATE OR REPLACE VIEW tool_results AS
    WITH array_messages AS (
      SELECT * FROM user_messages
      WHERE json_type(message->'content') = 'ARRAY'
    )
    SELECT
      m.uuid,
      m.timestamp,
      m.sessionId,
      m.isAgent,
      m.agentId,
      m.project,
      m.rownum,
      block->>'tool_use_id' as tool_use_id,
      CAST(block->>'is_error' AS BOOLEAN) as is_error,
      block->>'content' as result_content,
      CAST(m.toolUseResult->>'durationMs' AS INTEGER) as duration_ms,
      m.sourceToolAssistantUUID
    FROM array_messages m,
    LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
    WHERE block->>'type' = 'tool_result';

    -- Token usage: Pre-cast token counts
    CREATE OR REPLACE VIEW token_usage AS
    SELECT
      uuid,
      timestamp,
      sessionId,
      isAgent,
      agentId,
      project,
      message->>'model' as model,
      message->>'stop_reason' as stop_reason,
      CAST(message->'usage'->>'input_tokens' AS BIGINT) as input_tokens,
      CAST(message->'usage'->>'output_tokens' AS BIGINT) as output_tokens,
      CAST(message->'usage'->>'cache_read_input_tokens' AS BIGINT) as cache_read_tokens,
      CAST(message->'usage'->>'cache_creation_input_tokens' AS BIGINT) as cache_creation_tokens
    FROM assistant_messages
    WHERE (message->'usage') IS NOT NULL;

    -- Bash commands: Bash tool uses with extracted command
    CREATE OR REPLACE VIEW bash_commands AS
    SELECT
      uuid,
      timestamp,
      sessionId,
      isAgent,
      agentId,
      project,
      rownum,
      tool_id,
      tool_input->>'command' as command,
      tool_input->>'description' as description,
      CAST(tool_input->>'timeout' AS INTEGER) as timeout,
      CAST(tool_input->>'run_in_background' AS BOOLEAN) as run_in_background
    FROM tool_uses
    WHERE tool_name = 'Bash';

    -- File operations: Read/Write/Edit/Glob/Grep with extracted paths
    CREATE OR REPLACE VIEW file_operations AS
    SELECT
      uuid,
      timestamp,
      sessionId,
      isAgent,
      agentId,
      project,
      rownum,
      tool_id,
      tool_name,
      COALESCE(
        tool_input->>'file_path',
        tool_input->>'path'
      ) as file_path,
      tool_input->>'pattern' as pattern
    FROM tool_uses
    WHERE tool_name IN ('Read', 'Write', 'Edit', 'Glob', 'Grep');
  "
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_query_result_formatting() {
        let result = QueryResult {
            columns: vec!["a".to_string(), "b".to_string()],
            rows: vec![vec!["1".to_string(), "2".to_string()]],
        };
        assert!(result.to_table().contains("(1 row)"));
        assert_eq!(result.to_tsv(), "a\tb\n1\t2");
    }

    #[test]
    fn test_build_create_views_sql_single_pattern() {
        let pattern = FilePattern::Single("/path/to/*.jsonl".to_string());
        let sql = QuerySession::build_create_views_sql(&pattern);
        assert!(sql.contains("'/path/to/*.jsonl'"));
        assert!(sql.contains("CREATE OR REPLACE VIEW messages"));
        assert!(sql.contains("CREATE OR REPLACE VIEW tool_uses"));
    }

    #[test]
    fn test_build_create_views_sql_multiple_patterns() {
        let pattern = FilePattern::Multiple(vec![
            "/path/a*.jsonl".to_string(),
            "/path/b*.jsonl".to_string(),
        ]);
        let sql = QuerySession::build_create_views_sql(&pattern);
        assert!(sql.contains("['/path/a*.jsonl', '/path/b*.jsonl']"));
    }
}
