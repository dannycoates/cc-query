import { createInterface } from "node:readline";
import { homedir } from "node:os";
import { readFile, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { QuerySession } from "./query-session.js";

const HISTORY_FILE = join(homedir(), ".cc_query_history");
const HISTORY_SIZE = 100;

/**
 * Load query history from file
 * @returns {Promise<string[]>}
 */
async function loadHistory() {
  try {
    const content = await readFile(HISTORY_FILE, "utf-8");
    return content
      .split("\n")
      .filter((line) => line.trim())
      .slice(-HISTORY_SIZE);
  } catch {
    return [];
  }
}

/**
 * Save query history to file
 * @param {string[]} history
 */
async function saveHistory(history) {
  try {
    await writeFile(
      HISTORY_FILE,
      history.slice(-HISTORY_SIZE).join("\n"),
      "utf-8",
    );
  } catch {
    // Silently ignore write errors
  }
}

/**
 * @typedef {object} ReplOptions
 * @property {string} [sessionFilter] - Session ID prefix filter
 */

/**
 * Get help text for .help command
 * @returns {string}
 */
function getHelpText() {
  return `
Commands:
  .help, .h      Show this help
  .schema, .s    Show schemas for all views
  .schema <view> Show schema for a specific view
  .quit, .q      Exit

Views:
  messages            All messages (user, assistant, system)
  user_messages       User messages with user-specific fields
  human_messages      Human-typed messages (excludes tool results)
  assistant_messages  Assistant messages with error, requestId, etc.
  system_messages     System messages with hooks, retry info, etc.
  raw_messages        Raw JSON for each message by uuid
  tool_uses           All tool calls with unnested content blocks
  tool_results        Tool results with duration and error status
  token_usage         Token counts per assistant message
  bash_commands       Bash tool calls with extracted command
  file_operations     Read/Write/Edit/Glob/Grep with file paths

Example queries:
  -- Count messages by type
  SELECT type, count(*) as cnt FROM messages GROUP BY type ORDER BY cnt DESC;

  -- Messages by project (when querying all projects)
  SELECT project, count(*) as cnt FROM messages GROUP BY project ORDER BY cnt DESC;

  -- Recent assistant messages
  SELECT timestamp, message->>'role', message->>'stop_reason'
  FROM assistant_messages ORDER BY timestamp DESC LIMIT 10;

  -- Tool usage
  SELECT message->>'stop_reason' as reason, count(*) as cnt
  FROM assistant_messages
  GROUP BY reason ORDER BY cnt DESC;

  -- Sessions summary
  SELECT sessionId, count(*) as msgs, min(timestamp) as started
  FROM messages GROUP BY sessionId ORDER BY started DESC;

  -- System message subtypes
  SELECT subtype, count(*) FROM system_messages GROUP BY subtype;

  -- Agent vs main session breakdown
  SELECT isAgent, count(*) FROM messages GROUP BY isAgent;

JSON field access (DuckDB syntax):
  message->'field'        Access JSON field (returns JSON)
  message->>'field'       Access JSON field as string
  message->'a'->'b'       Nested access

Useful functions:
  arr[n]                 Get nth element (1-indexed)
  UNNEST(arr)            Expand array into rows
  json_extract_string()  Extract string from JSON
`;
}

/**
 * Execute a SQL query and print results
 * @param {QuerySession} qs
 * @param {string} query
 */
async function executeQuery(qs, query) {
  try {
    const result = await qs.query(query);
    if (result) {
      console.log(result);
    }
  } catch (err) {
    console.error(`Error: ${err instanceof Error ? err.message : err}`);
  }
}

/**
 * Handle dot commands
 * @param {string} command
 * @param {QuerySession} qs
 * @returns {Promise<boolean>} true if should exit
 */
async function handleDotCommand(command, qs) {
  const cmd = command.toLowerCase();

  if (cmd === ".quit" || cmd === ".exit" || cmd === ".q") {
    console.log("\nGoodbye!");
    qs.cleanup();
    return true;
  }

  if (cmd === ".help" || cmd === ".h") {
    console.log(getHelpText());
    return false;
  }

  if (cmd === ".schema" || cmd === ".s") {
    const views = [
      "messages",
      "user_messages",
      "human_messages",
      "assistant_messages",
      "system_messages",
      "raw_messages",
      "tool_uses",
      "tool_results",
      "token_usage",
      "bash_commands",
      "file_operations",
    ];
    for (const view of views) {
      console.log(`\n=== ${view} ===`);
      await executeQuery(qs, `DESCRIBE ${view}`);
    }
    return false;
  }

  if (cmd.startsWith(".schema ") || cmd.startsWith(".s ")) {
    const view = command.split(/\s+/)[1];
    await executeQuery(qs, `DESCRIBE ${view}`);
    return false;
  }

  console.log(`Unknown command: ${command}. Type .help for usage.`);
  return false;
}

/**
 * Read all stdin as a string
 * @returns {Promise<string>}
 */
async function readStdin() {
  const chunks = [];
  for await (const chunk of process.stdin) {
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf-8");
}

/**
 * Run queries from piped input (non-interactive mode)
 * @param {QuerySession} qs
 * @param {string} input
 */
async function runPipedQueries(qs, input) {
  // Split by semicolons, keeping the semicolon with each statement
  const statements = input
    .split(/(?<=;)/)
    .map((s) => s.trim())
    .filter((s) => s && s !== ";");

  for (const stmt of statements) {
    if (stmt.startsWith(".")) {
      const shouldExit = await handleDotCommand(stmt, qs);
      if (shouldExit) break;
    } else {
      await executeQuery(qs, stmt);
    }
  }
}

/**
 * Start the interactive REPL or run piped queries
 * @param {string | null} claudeProjectsDir
 * @param {ReplOptions} [options]
 */
export async function startRepl(claudeProjectsDir, options = {}) {
  const { sessionFilter = "" } = options;

  // Create query session (handles file discovery and view creation)
  const qs = await QuerySession.create(claudeProjectsDir, sessionFilter);
  const { sessionCount, agentCount, projectCount } = qs.info;

  // Check if input is piped (non-TTY)
  if (!process.stdin.isTTY) {
    try {
      const input = await readStdin();
      await runPipedQueries(qs, input);
    } finally {
      qs.cleanup();
    }
    return;
  }

  // Interactive mode
  try {
    const projectInfo = projectCount > 1 ? `${projectCount} project(s), ` : "";
    console.log(
      `Loaded ${projectInfo}${sessionCount} session(s), ${agentCount} agent file(s)`,
    );
    if (sessionFilter) {
      console.log(`Filter: ${sessionFilter}*`);
    }
    console.log('Type ".help" for usage hints.\n');

    // Setup readline with persistent history
    const history = await loadHistory();
    const rl = createInterface({
      input: process.stdin,
      output: process.stdout,
      prompt: "cc-query> ",
      terminal: true,
      history,
      historySize: HISTORY_SIZE,
      removeHistoryDuplicates: true,
    });

    // Persist history on changes
    rl.on("history", (newHistory) => {
      saveHistory(newHistory);
    });

    let multiLineBuffer = "";
    let inMultiLine = false;

    rl.on("close", () => {
      console.log("\nGoodbye!");
      qs.cleanup();
      process.exit(0);
    });

    rl.prompt();

    for await (const line of rl) {
      const trimmed = line.trim();

      // Handle multi-line mode
      if (inMultiLine) {
        multiLineBuffer += "\n" + line;
        // Check if query ends with semicolon
        if (trimmed.endsWith(";")) {
          await executeQuery(qs, multiLineBuffer);
          multiLineBuffer = "";
          inMultiLine = false;
        } else {
          process.stdout.write("      -> ");
          continue;
        }
      }
      // Handle dot commands
      else if (trimmed.startsWith(".")) {
        const shouldExit = await handleDotCommand(trimmed, qs);
        if (shouldExit) break;
      }
      // Handle SQL queries
      else if (trimmed) {
        if (trimmed.endsWith(";")) {
          await executeQuery(qs, trimmed);
        } else {
          // Start multi-line mode
          multiLineBuffer = line;
          inMultiLine = true;
          process.stdout.write("      -> ");
          continue;
        }
      }

      rl.prompt();
    }
  } finally {
    qs.cleanup();
  }
}
