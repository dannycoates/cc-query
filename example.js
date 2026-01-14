import { QuerySession } from "./index.js";

// Create a session for a specific project
const qs = await QuerySession.create(null); // null = all projects

console.log(`Loaded ${qs.info.sessionCount} sessions, ${qs.info.agentCount} agents\n`);

// Run a query and get formatted output
console.log("=== Messages by type ===");
console.log(await qs.query(`
  SELECT type, count(*) as cnt
  FROM messages
  GROUP BY type
  ORDER BY cnt DESC
`));

// Run a query and get raw rows for programmatic access
console.log("\n=== Top 5 tools used ===");
const { rows } = await qs.queryRows(`
  SELECT
    message->'content'->0->>'name' as tool,
    count(*) as uses
  FROM assistant_messages
  WHERE message->>'stop_reason' = 'tool_use'
  GROUP BY tool
  ORDER BY uses DESC
  LIMIT 5
`);

for (const row of rows) {
  console.log(`${row[0]}: ${row[1]} uses`);
}

// Clean up
qs.cleanup();
