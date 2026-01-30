import { DuckDBInstance } from "@duckdb/node-api";
import { homedir } from "node:os";
import { join } from "node:path";
import { access } from "node:fs/promises";

const DEFAULT_RAW_LOG = join(homedir(), ".local/log/cc-proxy/cc-proxy.log");

/**
 * Convert a result value to string for display
 * @param {any} val
 * @returns {string}
 */
function valueToString(val) {
  if (val === null || val === undefined) return "NULL";
  if (typeof val === "bigint") return val.toString();
  if (typeof val === "object") {
    if ("micros" in val) {
      const ms = Number(val.micros) / 1000;
      return new Date(ms).toISOString().replace("T", " ").replace("Z", "");
    }
    if ("hugeint" in val) {
      let n = BigInt(val.hugeint);
      if (n < 0n) n += 1n << 128n;
      n ^= 1n << 127n;
      const hex = n.toString(16).padStart(32, "0");
      return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
    }
    return JSON.stringify(val, (_, v) =>
      typeof v === "bigint" ? v.toString() : v,
    );
  }
  return String(val);
}

/**
 * Format query results as TSV with header row
 * @param {import("@duckdb/node-api").DuckDBResultReader} result
 * @returns {string}
 */
function formatResultsTsv(result) {
  const columnCount = result.columnCount;
  if (columnCount === 0) return "";

  const columnNames = [];
  for (let i = 0; i < columnCount; i++) {
    columnNames.push(result.columnName(i));
  }
  const rows = result.getRows();

  const lines = [columnNames.join("\t")];
  for (const row of rows) {
    lines.push(row.map(valueToString).join("\t"));
  }
  return lines.join("\n");
}

/**
 * Format query results as a table string
 * @param {import("@duckdb/node-api").DuckDBResultReader} result
 * @returns {string}
 */
function formatResults(result) {
  const columnCount = result.columnCount;
  if (columnCount === 0) return "";

  const columnNames = [];
  for (let i = 0; i < columnCount; i++) {
    columnNames.push(result.columnName(i));
  }
  const rows = result.getRows();

  if (rows.length === 0) {
    return columnNames.join(" | ") + "\n(0 rows)";
  }

  const stringRows = rows.map((row) => row.map(valueToString));

  const widths = columnNames.map((name, i) => {
    const maxDataWidth = Math.max(
      ...stringRows.map((row) => row[i]?.length || 0),
    );
    return Math.max(name.length, maxDataWidth);
  });

  const lines = [];

  const header = columnNames.map((n, i) => n.padEnd(widths[i])).join(" │ ");
  lines.push("┌" + widths.map((w) => "─".repeat(w + 2)).join("┬") + "┐");
  lines.push("│ " + header + " │");
  lines.push("├" + widths.map((w) => "─".repeat(w + 2)).join("┼") + "┤");

  for (const row of stringRows) {
    const rowStr = row.map((v, i) => (v || "").padEnd(widths[i])).join(" │ ");
    lines.push("│ " + rowStr + " │");
  }

  lines.push("└" + widths.map((w) => "─".repeat(w + 2)).join("┴") + "┘");
  lines.push(`(${rows.length} row${rows.length === 1 ? "" : "s"})`);

  return lines.join("\n");
}

/**
 * @typedef {object} RawQuerySessionInfo
 * @property {number} requestCount
 * @property {number} responseCount
 * @property {string} filePath
 */

/**
 * A session for querying raw Claude API request/response logs
 */
export class RawQuerySession {
  /** @type {import("@duckdb/node-api").DuckDBConnection | undefined} */
  #connection;
  /** @type {string} */
  #filePath;
  /** @type {RawQuerySessionInfo} */
  #info;

  /**
   * @param {string} filePath - Path to the NDJSON log file
   * @param {RawQuerySessionInfo} info - Counts
   */
  constructor(filePath, info) {
    this.#filePath = filePath;
    this.#info = info;
  }

  /**
   * Create a RawQuerySession from a log file path
   * @param {string | null} [filePath] - Path to log file, or null for default
   * @returns {Promise<RawQuerySession>}
   */
  static async create(filePath = null) {
    const resolvedPath = filePath || DEFAULT_RAW_LOG;

    // Verify file exists
    try {
      await access(resolvedPath);
    } catch {
      const err = new Error(`Log file not found: ${resolvedPath}`);
      // @ts-ignore
      err.code = "ENOENT";
      throw err;
    }

    // Create instance and initialize to get counts
    const instance = await DuckDBInstance.create(":memory:");
    const connection = await instance.connect();

    // Count requests and responses
    const countSql = `
      SELECT
        count(*) FILTER (WHERE json->>'request' IS NOT NULL) as request_count,
        count(*) FILTER (WHERE json->>'response' IS NOT NULL) as response_count
      FROM read_ndjson_objects('${resolvedPath}', ignore_errors=true)
    `;
    const countResult = await connection.runAndReadAll(countSql);
    const countRows = countResult.getRows();
    const requestCount = Number(countRows[0]?.[0] ?? 0);
    const responseCount = Number(countRows[0]?.[1] ?? 0);

    if (requestCount === 0 && responseCount === 0) {
      connection.closeSync();
      const err = new Error("No requests or responses found in log file");
      // @ts-ignore
      err.code = "ENOENT";
      throw err;
    }

    const qs = new RawQuerySession(resolvedPath, {
      requestCount,
      responseCount,
      filePath: resolvedPath,
    });
    qs.#connection = connection;
    await qs.#createViews();
    return qs;
  }

  /** @returns {RawQuerySessionInfo} */
  get info() {
    return this.#info;
  }

  /**
   * @returns {Promise<void>}
   */
  async #createViews() {
    if (!this.#connection) throw new Error("Not initialized");
    await this.#connection.run(this.#getCreateViewsSql());
  }

  /**
   * Execute a SQL query and return formatted table
   * @param {string} sql
   * @returns {Promise<string>} Query result as formatted table
   */
  async query(sql) {
    if (!this.#connection) {
      throw new Error("Session not initialized - use RawQuerySession.create()");
    }
    const result = await this.#connection.runAndReadAll(sql);
    return formatResults(result);
  }

  /**
   * Execute a SQL query and return TSV formatted string with header
   * @param {string} sql
   * @returns {Promise<string>} Query result as TSV
   */
  async queryTsv(sql) {
    if (!this.#connection) {
      throw new Error("Session not initialized - use RawQuerySession.create()");
    }
    const result = await this.#connection.runAndReadAll(sql);
    return formatResultsTsv(result);
  }

  /**
   * Execute a SQL query and return raw rows
   * @param {string} sql
   * @returns {Promise<{columns: string[], rows: any[][]}>} Query result as raw data
   */
  async queryRows(sql) {
    if (!this.#connection) {
      throw new Error("Session not initialized - use RawQuerySession.create()");
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
    const filePath = this.#filePath;

    return `
    -- Base table for all entries with row numbers
    CREATE OR REPLACE VIEW raw_entries AS
    SELECT
      ordinality as rownum,
      json as raw,
      CASE
        WHEN json->>'request' IS NOT NULL THEN 'request'
        WHEN json->>'response' IS NOT NULL THEN 'response'
        ELSE 'other'
      END as entry_type
    FROM read_ndjson_objects('${filePath}', ignore_errors=true) WITH ORDINALITY
    WHERE json->>'request' IS NOT NULL OR json->>'response' IS NOT NULL;

    -- API requests
    CREATE OR REPLACE VIEW requests AS
    SELECT
      ordinality as rownum,
      json->'request'->>'model' as model,
      json->'request'->'messages' as messages,
      json->'request'->'system' as system,
      json->'request'->'tools' as tools,
      json->'request'->'metadata' as metadata,
      CAST(json->'request'->>'max_tokens' AS INTEGER) as max_tokens,
      CAST(json->'request'->>'stream' AS BOOLEAN) as stream,
      json_array_length(json->'request'->'messages') as message_count,
      json_array_length(json->'request'->'tools') as tool_count
    FROM read_ndjson_objects('${filePath}', ignore_errors=true) WITH ORDINALITY
    WHERE json->>'request' IS NOT NULL;

    -- API responses (full response body)
    CREATE OR REPLACE VIEW responses AS
    SELECT
      ordinality as rownum,
      json->'response'->>'model' as model,
      json->'response'->>'id' as id,
      json->'response'->>'stop_reason' as stop_reason,
      json->'response'->'usage' as usage,
      CAST(json->'response'->'usage'->>'input_tokens' AS INTEGER) as input_tokens,
      CAST(json->'response'->'usage'->>'output_tokens' AS INTEGER) as output_tokens,
      CAST(json->'response'->'usage'->>'cache_read_input_tokens' AS INTEGER) as cache_read_tokens,
      CAST(json->'response'->'usage'->>'cache_creation_input_tokens' AS INTEGER) as cache_creation_tokens,
      json->'response'->'content' as content
    FROM read_ndjson_objects('${filePath}', ignore_errors=true) WITH ORDINALITY
    WHERE json->>'response' IS NOT NULL;

    -- Unnested messages from requests
    CREATE OR REPLACE VIEW request_messages AS
    SELECT
      r.rownum,
      (row_number() OVER (PARTITION BY r.rownum ORDER BY (SELECT NULL))) - 1 as message_index,
      msg->>'role' as role,
      msg->'content' as content
    FROM requests r,
    LATERAL UNNEST(CAST(r.messages AS JSON[])) as t(msg);

    -- Unnested tools from requests
    CREATE OR REPLACE VIEW request_tools AS
    SELECT
      r.rownum,
      (row_number() OVER (PARTITION BY r.rownum ORDER BY (SELECT NULL))) - 1 as tool_index,
      tool->>'name' as name,
      tool->>'description' as description,
      tool->'input_schema' as input_schema
    FROM requests r,
    LATERAL UNNEST(CAST(r.tools AS JSON[])) as t(tool)
    WHERE r.tools IS NOT NULL;

    -- Model usage summary from responses (includes token stats)
    CREATE OR REPLACE VIEW model_usage AS
    SELECT
      model,
      count(*) as response_count,
      sum(input_tokens) as total_input_tokens,
      sum(output_tokens) as total_output_tokens,
      sum(cache_read_tokens) as total_cache_read,
      sum(cache_creation_tokens) as total_cache_creation,
      avg(input_tokens)::INTEGER as avg_input_tokens,
      avg(output_tokens)::INTEGER as avg_output_tokens
    FROM responses
    GROUP BY model;

    -- Unnested system prompt blocks
    CREATE OR REPLACE VIEW system_prompts AS
    SELECT
      r.rownum,
      r.model,
      (row_number() OVER (PARTITION BY r.rownum ORDER BY (SELECT NULL))) - 1 as block_index,
      block->>'type' as block_type,
      CASE
        WHEN block->>'type' = 'text' THEN block->>'text'
        ELSE NULL
      END as text_content,
      block as raw_block
    FROM requests r,
    LATERAL UNNEST(CAST(r.system AS JSON[])) as t(block)
    WHERE r.system IS NOT NULL;

    -- Unnested response content blocks
    CREATE OR REPLACE VIEW response_blocks AS
    SELECT
      r.rownum,
      (row_number() OVER (PARTITION BY r.rownum ORDER BY (SELECT NULL))) - 1 as block_index,
      block->>'type' as block_type,
      CASE
        WHEN block->>'type' = 'text' THEN block->>'text'
        WHEN block->>'type' = 'thinking' THEN block->>'thinking'
        ELSE NULL
      END as text_content,
      CASE
        WHEN block->>'type' = 'tool_use' THEN block->>'name'
        ELSE NULL
      END as tool_name,
      CASE
        WHEN block->>'type' = 'tool_use' THEN block->>'id'
        ELSE NULL
      END as tool_id,
      CASE
        WHEN block->>'type' = 'tool_use' THEN block->'input'
        ELSE NULL
      END as tool_input,
      block as raw_block
    FROM responses r,
    LATERAL UNNEST(CAST(r.content AS JSON[])) as t(block);
    `;
  }
}
