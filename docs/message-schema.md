# cc-query Documentation

## Usage

```bash
# Interactive REPL
cc-query                      # All projects
cc-query .                    # Current project
cc-query ~/code/my-project    # Specific project

# Piped queries (like psql)
echo "SELECT count(*) FROM messages;" | cc-query .

# Multiple queries
cat << 'EOF' | cc-query
SELECT count(*) FROM messages;
SELECT type, count(*) FROM messages GROUP BY type;
EOF

# From a file
cat queries.sql | cc-query .

# With session filter
cc-query -s abc123 .
```

In piped mode, cc-query executes all queries and exits without prompts or banners.

## Library Usage

```javascript
import { QuerySession } from "cc-query";

const qs = await QuerySession.create(null); // null = all projects, or pass path
console.log(qs.info); // { sessionCount, agentCount, projectCount }

// Formatted table output
console.log(await qs.query("SELECT type, count(*) FROM messages GROUP BY type"));

// Raw rows for programmatic access
const { columns, rows } = await qs.queryRows("SELECT * FROM messages LIMIT 5");

qs.cleanup();
```

---

# Database Schema

## Views

| View                 | Description                                          |
| -------------------- | ---------------------------------------------------- |
| `messages`           | All messages (user, assistant, system)               |
| `user_messages`      | User messages with tool results, todos, etc.         |
| `assistant_messages` | Assistant messages with API response data            |
| `system_messages`    | System messages (hooks, retries, tool output, etc.)  |
| `human_messages`     | Only human-typed messages (excludes tool results)    |
| `raw_messages`       | Raw JSON for each message (uuid + full JSON)         |

## Common Fields (all views)

| Field        | Type      | Description                                      |
| ------------ | --------- | ------------------------------------------------ |
| `uuid`       | UUID      | Unique message ID                                |
| `type`       | VARCHAR   | Message type: `user`, `assistant`, `system`      |
| `parentUuid` | UUID      | Parent message ID (conversation threading)       |
| `timestamp`  | TIMESTAMP | When the message was created                     |
| `sessionId`  | UUID      | Session ID                                       |
| `cwd`        | VARCHAR   | Working directory                                |
| `gitBranch`  | VARCHAR   | Git branch (if in a git repo)                    |
| `slug`       | VARCHAR   | Session slug (human-readable name)               |
| `version`    | VARCHAR   | Claude Code version                              |
| `isSidechain`| BOOLEAN   | Whether this is a sidechain message              |
| `userType`   | VARCHAR   | User type (e.g., `external`)                     |
| `message`    | JSON      | The Anthropic API message payload                |

## Derived Fields (all views)

| Field     | Type    | Description                                        |
| --------- | ------- | -------------------------------------------------- |
| `file`    | VARCHAR | Source filename (e.g., `session-id.jsonl`)         |
| `isAgent` | BOOLEAN | Whether this is from an agent (subagent) file      |
| `agentId` | VARCHAR | Agent ID if from agent file (e.g., `ab4747c`)      |
| `project` | VARCHAR | Project slug (directory name under ~/.claude/projects) |
| `rownum`  | BIGINT  | Row number in source file                          |

## User Message Fields

| Field                    | Type    | Description                                    |
| ------------------------ | ------- | ---------------------------------------------- |
| `isMeta`                 | BOOLEAN | System-injected meta message                   |
| `toolUseResult`          | JSON    | Tool result metadata (durationMs, filenames)   |
| `sourceToolAssistantUUID`| UUID    | Links tool result to assistant that called it  |
| `sourceToolUseID`        | VARCHAR | The tool_use_id this result responds to        |
| `thinkingMetadata`       | JSON    | Metadata about thinking blocks                 |
| `todos`                  | JSON    | Todo list state                                |

## System Message Fields

| Field                 | Type    | Description                              |
| --------------------- | ------- | ---------------------------------------- |
| `subtype`             | VARCHAR | System message subtype                   |
| `content`             | VARCHAR | System message content                   |
| `level`               | VARCHAR | Log level                                |
| `hookCount`           | INTEGER | Number of hooks executed                 |
| `hookErrors`          | JSON    | Hook error details                       |
| `hookInfos`           | JSON    | Hook info details                        |
| `stopReason`          | VARCHAR | Why processing stopped                   |
| `toolUseID`           | VARCHAR | Related tool use ID                      |
| `hasOutput`           | BOOLEAN | Whether tool produced output             |
| `preventedContinuation` | BOOLEAN | Whether continuation was prevented     |

---

# Message JSON Schema

This document describes the structure of the `message` JSON field in `user_messages` and `assistant_messages` views, based on the [Anthropic Messages API](https://docs.anthropic.com/en/api/messages).

## Assistant Messages

Assistant messages follow the Anthropic API response format.

### Top-level Fields

| Field           | Type    | Description                                                                      |
| --------------- | ------- | -------------------------------------------------------------------------------- |
| `id`            | String  | Message ID (e.g., `msg_01GC7S5QXPz4Cj5QJVwk7nkW`)                                |
| `type`          | String  | Always `"message"`                                                               |
| `role`          | String  | Always `"assistant"`                                                             |
| `model`         | String  | Model ID (e.g., `claude-opus-4-5-20251101`)                                      |
| `content`       | Array   | Array of content blocks                                                          |
| `stop_reason`   | String  | Why generation stopped: `end_turn`, `tool_use`, `stop_sequence`, or `max_tokens` |
| `stop_sequence` | String? | The stop sequence that triggered, if any                                         |
| `usage`         | Object  | Token usage statistics                                                           |

### Content Block Types

The `content` array contains blocks of different types:

#### Text Block

```json
{
  "type": "text",
  "text": "The response text..."
}
```

#### Tool Use Block

```json
{
  "type": "tool_use",
  "id": "toolu_019rXQBzHUwVWg7aB5BAhX9W",
  "name": "Read",
  "input": {
    "file_path": "/path/to/file.js"
  }
}
```

#### Thinking Block (Extended Thinking)

```json
{
  "type": "thinking",
  "thinking": "The model's reasoning process...",
  "signature": "base64-encoded-signature..."
}
```

### Usage Object

```json
{
  "input_tokens": 2,
  "output_tokens": 155,
  "cache_creation_input_tokens": 10718,
  "cache_read_input_tokens": 0,
  "cache_creation": {
    "ephemeral_5m_input_tokens": 10718,
    "ephemeral_1h_input_tokens": 0
  },
  "service_tier": "standard"
}
```

## User Messages

User messages contain either plain text or tool results.

### Top-level Fields

| Field     | Type            | Description                            |
| --------- | --------------- | -------------------------------------- |
| `role`    | String          | Always `"user"`                        |
| `content` | String or Array | Text string or array of content blocks |

### Content as String

Simple text messages have content as a string:

```json
{
  "role": "user",
  "content": "Please help me with this code..."
}
```

### Content as Array (Tool Results)

When returning tool results, content is an array:

```json
{
  "role": "user",
  "content": [
    {
      "type": "tool_result",
      "tool_use_id": "toolu_014dBAWyEEDLdLpu1Pizeg4s",
      "content": "file contents or command output...",
      "is_error": false
    }
  ]
}
```

## Example Queries

### Count messages by stop reason

```sql
SELECT
  message->>'stop_reason' as reason,
  count(*) as cnt
FROM assistant_messages
GROUP BY reason
ORDER BY cnt DESC;
```

### Get token usage stats

```sql
SELECT
  sum(CAST(message->'usage'->>'input_tokens' AS BIGINT)) as total_input,
  sum(CAST(message->'usage'->>'output_tokens' AS BIGINT)) as total_output,
  sum(CAST(message->'usage'->>'cache_read_input_tokens' AS BIGINT)) as cache_hits
FROM assistant_messages;
```

### Get model usage breakdown

```sql
SELECT
  message->>'model' as model,
  count(*) as messages,
  sum(CAST(message->'usage'->>'output_tokens' AS BIGINT)) as total_output_tokens
FROM assistant_messages
GROUP BY model
ORDER BY messages DESC;
```

## Working with Content Arrays

The `content` field is a JSON array. Use `->` to access elements by index (0-based) and `UNNEST` to expand arrays.

### Extract first content block

```sql
-- Get the first content block
SELECT message->'content'->0 as first_block
FROM assistant_messages
LIMIT 1;
```

### Count tool uses by name

```sql
SELECT
  message->'content'->0->>'name' as tool,
  count(*) as uses
FROM assistant_messages
WHERE message->>'stop_reason' = 'tool_use'
GROUP BY tool
ORDER BY uses DESC
LIMIT 10;
```

### Find specific tool usage

```sql
SELECT
  timestamp,
  message->'content'->0->>'name' as tool,
  message->'content'->0->>'id' as tool_id
FROM assistant_messages
WHERE message->>'stop_reason' = 'tool_use'
  AND message->'content'->0->>'name' = 'Bash'
ORDER BY timestamp DESC
LIMIT 5;
```

### Get tool input parameters

```sql
SELECT
  timestamp,
  message->'content'->0->>'name' as tool,
  message->'content'->0->'input' as input
FROM assistant_messages
WHERE message->>'stop_reason' = 'tool_use'
ORDER BY timestamp DESC
LIMIT 5;
```

### Expand all content blocks with UNNEST

```sql
SELECT
  timestamp,
  block->>'type' as block_type,
  block->>'name' as tool_name
FROM assistant_messages,
LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
WHERE block->>'type' = 'tool_use'
LIMIT 20;
```

### Find thinking blocks

```sql
SELECT
  timestamp,
  left(block->>'thinking', 200) as thinking_preview
FROM assistant_messages,
LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
WHERE block->>'type' = 'thinking'
LIMIT 5;
```

### Find tool results (in user messages)

```sql
SELECT
  timestamp,
  block->>'tool_use_id' as tool_id,
  CAST(block->>'is_error' AS BOOLEAN) as is_error,
  left(block->>'content', 100) as result_preview
FROM user_messages,
LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
WHERE block->>'type' = 'tool_result'
LIMIT 10;
```

### Find tool errors

```sql
SELECT
  timestamp,
  block->>'tool_use_id' as tool_id,
  left(block->>'content', 200) as error_content
FROM user_messages,
LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
WHERE block->>'type' = 'tool_result'
  AND CAST(block->>'is_error' AS BOOLEAN) = true
LIMIT 10;
```

## Useful JSON Functions

| Function                          | Description                      |
| --------------------------------- | -------------------------------- |
| `json->>'key'`                    | Extract string value             |
| `json->'key'`                     | Extract JSON value               |
| `json->0`                         | Access array element (0-indexed) |
| `json_extract_string(json, path)` | Extract string with JSONPath     |
| `json_type(json)`                 | Get type of JSON value           |
| `UNNEST(json_array)`              | Expand array into rows           |

## Fun Queries

### Coding Activity by Hour

```sql
SELECT
  extract(hour FROM timestamp) as hour,
  count(*) as messages,
  repeat('█', (count(*) * 30 / max(count(*)) OVER ())::INT) as activity
FROM messages
GROUP BY hour
ORDER BY hour;
```

### Tool Chains: What Follows What?

```sql
WITH tool_sequence AS (
  SELECT
    timestamp,
    sessionId,
    message->'content'->0->>'name' as tool,
    LAG(message->'content'->0->>'name')
      OVER (PARTITION BY sessionId ORDER BY timestamp) as prev_tool
  FROM assistant_messages
  WHERE message->>'stop_reason' = 'tool_use'
)
SELECT
  prev_tool || ' -> ' || tool as chain,
  count(*) as cnt
FROM tool_sequence
WHERE prev_tool IS NOT NULL AND tool IS NOT NULL
  AND prev_tool != '' AND tool != ''
GROUP BY chain
ORDER BY cnt DESC
LIMIT 10;
```

### Most Edited Files

```sql
SELECT
  message->'content'->0->'input'->>'file_path' as file,
  count(*) as edits
FROM assistant_messages
WHERE message->>'stop_reason' = 'tool_use'
  AND message->'content'->0->>'name' = 'Edit'
GROUP BY file
ORDER BY edits DESC
LIMIT 10;
```

### Session Size Distribution

```sql
SELECT
  CASE
    WHEN cnt <= 10 THEN '1-10 messages'
    WHEN cnt <= 50 THEN '11-50 messages'
    WHEN cnt <= 100 THEN '51-100 messages'
    WHEN cnt <= 200 THEN '101-200 messages'
    ELSE '200+ messages'
  END as session_size,
  count(*) as sessions,
  repeat('█', (count(*) * 20 / max(count(*)) OVER ())::INT) as chart
FROM (
  SELECT sessionId, count(*) as cnt
  FROM messages
  GROUP BY sessionId
)
GROUP BY session_size
ORDER BY session_size;
```

### Thinking Block Analysis

```sql
SELECT
  message->>'stop_reason' as outcome,
  round(avg(length(block->>'thinking')), 0) as avg_thinking_len,
  count(*) as cnt
FROM assistant_messages,
LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
WHERE block->>'type' = 'thinking'
GROUP BY outcome
ORDER BY avg_thinking_len DESC;
```

### Token Efficiency Over Time

```sql
SELECT
  CAST(timestamp AS DATE) as day,
  sum(CAST(message->'usage'->>'output_tokens' AS BIGINT)) as output_tokens,
  count(*) FILTER (WHERE type = 'user') as user_msgs,
  round(
    sum(CAST(message->'usage'->>'output_tokens' AS BIGINT))::FLOAT /
    nullif(count(*) FILTER (WHERE type = 'user'), 0),
    0
  ) as tokens_per_user_msg
FROM messages
WHERE CAST(timestamp AS DATE) >= current_date - INTERVAL '14 days'
GROUP BY day
ORDER BY day;
```

### Agent Types Spawned

```sql
SELECT
  message->'content'->0->'input'->>'subagent_type' as agent_type,
  count(*) as spawns
FROM assistant_messages
WHERE message->>'stop_reason' = 'tool_use'
  AND message->'content'->0->>'name' = 'Task'
GROUP BY agent_type
ORDER BY spawns DESC;
```

### Cache Efficiency

```sql
SELECT
  CAST(timestamp AS DATE) as day,
  sum(CAST(message->'usage'->>'input_tokens' AS BIGINT)) as input_tokens,
  sum(CAST(message->'usage'->>'cache_read_input_tokens' AS BIGINT)) as cache_hits,
  round(
    sum(CAST(message->'usage'->>'cache_read_input_tokens' AS BIGINT))::FLOAT * 100.0 /
    nullif(sum(CAST(message->'usage'->>'input_tokens' AS BIGINT)) +
           sum(CAST(message->'usage'->>'cache_read_input_tokens' AS BIGINT)), 0),
    1
  ) as cache_hit_pct
FROM assistant_messages
WHERE CAST(timestamp AS DATE) >= current_date - INTERVAL '7 days'
GROUP BY day
ORDER BY day;
```

### Cross-Project Comparison

```sql
SELECT
  project,
  count(*) as messages,
  count(*) FILTER (WHERE type = 'assistant' AND message->>'stop_reason' = 'tool_use') as tool_uses,
  round(
    count(*) FILTER (WHERE type = 'assistant' AND message->>'stop_reason' = 'tool_use')::FLOAT * 100.0 /
    nullif(count(*) FILTER (WHERE type = 'assistant'), 0),
    1
  ) as tool_use_pct,
  sum(CAST(message->'usage'->>'output_tokens' AS BIGINT)) as total_tokens
FROM messages
GROUP BY project
ORDER BY messages DESC;
```

### Agent vs Main Session Activity

```sql
SELECT
  isAgent,
  count(*) as messages,
  count(DISTINCT sessionId) as sessions,
  count(DISTINCT agentId) FILTER (WHERE isAgent) as unique_agents
FROM messages
GROUP BY isAgent;
```

### Tool Result Duration Analysis

```sql
SELECT
  message->'content'->0->>'tool_use_id' as tool_id,
  CAST(toolUseResult->>'durationMs' AS INTEGER) as duration_ms,
  toolUseResult->>'truncated' as truncated
FROM user_messages
WHERE toolUseResult IS NOT NULL
ORDER BY duration_ms DESC
LIMIT 10;
```

### Link Tool Results to Tool Calls

```sql
-- Find the assistant message that triggered a tool result
SELECT
  u.timestamp as result_time,
  a.timestamp as call_time,
  a.message->'content'->0->>'name' as tool_name,
  CAST(u.toolUseResult->>'durationMs' AS INTEGER) as duration_ms
FROM user_messages u
JOIN assistant_messages a ON u.sourceToolAssistantUUID = a.uuid
WHERE u.toolUseResult IS NOT NULL
ORDER BY u.timestamp DESC
LIMIT 10;
```

## Notes

- Use `->` for JSON access, `->>` to extract as string
- Array indices are 0-based in DuckDB (use `->0` for first element)
- Use `CAST(... AS TYPE)` for type conversions
- Use `UNNEST()` with `LATERAL` to expand arrays into rows
- Empty/missing JSON fields return NULL
- Use `FILTER (WHERE ...)` for conditional aggregation (instead of `countIf`)
