import { DuckDBInstance } from "@duckdb/node-api";
import { getSessionFiles } from "./session-loader.js";

/**
 * @typedef {object} QuerySessionInfo
 * @property {number} sessionCount
 * @property {number} agentCount
 * @property {number} projectCount
 */

/**
 * Format query results as a table string
 * @param {import("@duckdb/node-api").DuckDBResultReader} result
 * @returns {string}
 */
function formatResults(result) {
  const columnCount = result.columnCount;
  if (columnCount === 0) return "";

  // Build column names array
  const columnNames = [];
  for (let i = 0; i < columnCount; i++) {
    columnNames.push(result.columnName(i));
  }
  const rows = result.getRows();

  if (rows.length === 0) {
    return columnNames.join(" | ") + "\n(0 rows)";
  }

  // Convert all values to strings and calculate column widths
  const stringRows = rows.map((row) =>
    row.map((val) => {
      if (val === null || val === undefined) return "NULL";
      if (typeof val === "bigint") return val.toString();
      if (typeof val === "object") {
        // Handle DuckDB timestamp objects (returned as {micros: bigint})
        if ("micros" in val) {
          const ms = Number(val.micros) / 1000;
          return new Date(ms).toISOString().replace("T", " ").replace("Z", "");
        }
        // Handle DuckDB UUID objects (returned as {hugeint: string})
        if ("hugeint" in val) {
          // Convert 128-bit signed decimal to UUID hex string
          // DuckDB XORs the high bit for sorting, so flip it back
          let n = BigInt(val.hugeint);
          if (n < 0n) n += 1n << 128n; // Convert from signed to unsigned
          n ^= 1n << 127n; // Flip high bit (undo DuckDB's sort optimization)
          const hex = n.toString(16).padStart(32, "0");
          return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
        }
        return JSON.stringify(val, (_, v) =>
          typeof v === "bigint" ? v.toString() : v,
        );
      }
      return String(val);
    }),
  );

  const widths = columnNames.map((name, i) => {
    const maxDataWidth = Math.max(
      ...stringRows.map((row) => row[i]?.length || 0),
    );
    return Math.max(name.length, maxDataWidth);
  });

  // Build formatted output
  const lines = [];

  // Header
  const header = columnNames.map((n, i) => n.padEnd(widths[i])).join(" │ ");
  lines.push("┌" + widths.map((w) => "─".repeat(w + 2)).join("┬") + "┐");
  lines.push("│ " + header + " │");
  lines.push("├" + widths.map((w) => "─".repeat(w + 2)).join("┼") + "┤");

  // Data rows
  for (const row of stringRows) {
    const rowStr = row.map((v, i) => (v || "").padEnd(widths[i])).join(" │ ");
    lines.push("│ " + rowStr + " │");
  }

  lines.push("└" + widths.map((w) => "─".repeat(w + 2)).join("┴") + "┘");
  lines.push(`(${rows.length} row${rows.length === 1 ? "" : "s"})`);

  return lines.join("\n");
}

/**
 * A reusable session for querying Claude Code message data
 */
export class QuerySession {
  /** @type {import("@duckdb/node-api").DuckDBConnection | undefined} */
  #connection;
  /** @type {string} */
  #filePattern;
  /** @type {QuerySessionInfo} */
  #info;

  /**
   * @param {string} filePattern - Glob pattern for JSONL files
   * @param {QuerySessionInfo} info - Session counts
   */
  constructor(filePattern, info) {
    this.#filePattern = filePattern;
    this.#info = info;
  }

  /**
   * Create a QuerySession from a project path
   * @param {string | null} projectDir - Claude projects dir, or null for all
   * @param {string} [sessionFilter] - Optional session ID prefix filter
   * @returns {Promise<QuerySession>}
   */
  static async create(projectDir, sessionFilter = "") {
    const { sessionCount, agentCount, projectCount, filePattern } =
      await getSessionFiles(projectDir, sessionFilter);

    if (sessionCount === 0) {
      const err = new Error("No sessions found");
      // @ts-ignore
      err.code = "ENOENT";
      throw err;
    }

    const qs = new QuerySession(filePattern, {
      sessionCount,
      agentCount,
      projectCount,
    });
    await qs.#init();
    return qs;
  }

  /** @returns {QuerySessionInfo} */
  get info() {
    return this.#info;
  }

  /**
   * @returns {Promise<void>}
   */
  async #init() {
    const instance = await DuckDBInstance.create(":memory:");
    this.#connection = await instance.connect();
    await this.#connection.run(this.#getCreateViewsSql());
  }

  /**
   * Execute a SQL query and return formatted table
   * @param {string} sql
   * @returns {Promise<string>} Query result as formatted table
   */
  async query(sql) {
    if (!this.#connection) {
      throw new Error("Session not initialized - use QuerySession.create()");
    }
    const result = await this.#connection.runAndReadAll(sql);
    return formatResults(result);
  }

  /**
   * Execute a SQL query and return raw rows
   * @param {string} sql
   * @returns {Promise<{columns: string[], rows: any[][]}>} Query result as raw data
   */
  async queryRows(sql) {
    if (!this.#connection) {
      throw new Error("Session not initialized - use QuerySession.create()");
    }
    const result = await this.#connection.runAndReadAll(sql);
    const columns = [];
    for (let i = 0; i < result.columnCount; i++) {
      columns.push(result.columnName(i));
    }
    return { columns, rows: result.getRows() };
  }

  /**
   * Clean up resources
   */
  cleanup() {
    this.#connection?.closeSync();
  }

  /**
   * Get the SQL to create views
   * @returns {string}
   */
  #getCreateViewsSql() {
    // Explicitly define schema so missing columns become NULL with proper types
    const columns = {
      // Common fields
      uuid: "UUID",
      type: "VARCHAR",
      subtype: "VARCHAR",
      parentUuid: "UUID",
      timestamp: "TIMESTAMP",
      sessionId: "UUID",
      cwd: "VARCHAR",
      gitBranch: "VARCHAR",
      slug: "VARCHAR",
      version: "VARCHAR",
      isSidechain: "BOOLEAN",
      userType: "VARCHAR",
      message: "JSON",
      // User-specific
      isCompactSummary: "BOOLEAN",
      isMeta: "BOOLEAN",
      isVisibleInTranscriptOnly: "BOOLEAN",
      sourceToolUseID: "VARCHAR",
      thinkingMetadata: "JSON",
      todos: "JSON",
      toolUseResult: "JSON",
      // Assistant-specific
      error: "JSON",
      isApiErrorMessage: "BOOLEAN",
      requestId: "VARCHAR",
      sourceToolAssistantUUID: "UUID",
      // System-specific
      content: "VARCHAR",
      compactMetadata: "JSON",
      hasOutput: "BOOLEAN",
      hookCount: "INTEGER",
      hookErrors: "JSON",
      hookInfos: "JSON",
      level: "VARCHAR",
      logicalParentUuid: "UUID",
      maxRetries: "INTEGER",
      preventedContinuation: "BOOLEAN",
      retryAttempt: "INTEGER",
      retryInMs: "INTEGER",
      stopReason: "VARCHAR",
      toolUseID: "VARCHAR",
    };

    const columnsDef = Object.entries(columns)
      .map(([name, type]) => `'${name}': '${type}'`)
      .join(", ");

    return `
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
      '${this.#filePattern}',
      filename=true,
      ignore_errors=true,
      columns={${columnsDef}}
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
    FROM read_ndjson_objects('${this.#filePattern}', ignore_errors=true)
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
  `;
  }
}
