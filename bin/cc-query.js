#!/usr/bin/env node

import { startRepl } from "../src/repl.js";
import { resolveProjectDir } from "../src/utils.js";

const args = process.argv.slice(2);

// Parse --session or -s flag
let sessionFilter = "";
const sessionFlagIndex = args.findIndex((a) => a === "--session" || a === "-s");
if (sessionFlagIndex !== -1 && sessionFlagIndex + 1 < args.length) {
  sessionFilter = args[sessionFlagIndex + 1];
}

// Show help
if (args.includes("--help") || args.includes("-h")) {
  console.log("Usage: cc-query [options] [project-path]");
  console.log("");
  console.log("Interactive SQL REPL for querying Claude Code session data.");
  console.log("Uses chdb (embedded ClickHouse) to query JSONL session files.");
  console.log("");
  console.log("Arguments:");
  console.log(
    "  project-path            Path to project (omit for all projects)",
  );
  console.log("");
  console.log("Options:");
  console.log(
    "  --session, -s <prefix>  Filter to sessions matching the ID prefix",
  );
  console.log("  --help, -h              Show this help message");
  console.log("");
  console.log("Examples:");
  console.log("  cc-query                          # All projects");
  console.log("  cc-query ~/code/my-project        # Specific project");
  console.log("  cc-query -s abc123 .              # Filter by session prefix");
  console.log("");
  console.log("Piped input (like psql):");
  console.log('  echo "SELECT count(*) FROM messages;" | cc-query .');
  console.log("  cat queries.sql | cc-query .");
  console.log("");
  console.log("REPL Commands:");
  console.log("  .help      Show available tables and example queries");
  console.log("  .schema    Show table schema");
  console.log("  .quit      Exit the REPL");
  process.exit(0);
}

// Filter out flags to get positional args
const filteredArgs = args.filter(
  (a, i) =>
    a !== "--session" &&
    a !== "-s" &&
    (sessionFlagIndex === -1 || i !== sessionFlagIndex + 1),
);

// If no project specified, use null for all projects
let claudeProjectsDir = null;
let projectPath = null;

if (filteredArgs.length > 0) {
  const resolved = resolveProjectDir(filteredArgs[0]);
  claudeProjectsDir = resolved.claudeProjectsDir;
  projectPath = resolved.projectPath;
}

try {
  await startRepl(claudeProjectsDir, { sessionFilter });
} catch (err) {
  if (
    err instanceof Error &&
    /** @type {NodeJS.ErrnoException} */ (err).code === "ENOENT"
  ) {
    if (projectPath) {
      console.error(`Error: No Claude Code data found for ${projectPath}`);
      console.error(`Expected: ${claudeProjectsDir}`);
    } else {
      console.error("Error: No Claude Code sessions found");
    }
    process.exit(1);
  }
  throw err;
}
