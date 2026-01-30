---
name: api-logs
description: Query raw Claude API request/response logs using SQL. Use when analyzing API calls, model usage, request patterns, tool definitions, or raw API traffic from cc-proxy logs. Triggers on requests about API logs, raw requests, model usage stats, or cc-proxy data.
context: fork
allowed-tools: Bash
---

# Querying Raw API Logs

Use `${CLAUDE_PLUGIN_ROOT}/bin/cc-query --raw` to analyze raw Claude API request/response logs with SQL (DuckDB).

**Data source**: `~/.local/log/cc-proxy/cc-proxy.log` (NDJSON format from cc-proxy)

## Query Planning (Read This First)

**Each bash call costs ~1-2 seconds** (Node.js startup + DuckDB init + log parsing). Combine queries into batches.

**Standard pattern:**
```bash
cat << 'EOF' | ${CLAUDE_PLUGIN_ROOT}/bin/cc-query --raw
-- Query 1
SELECT ...;
-- Query 2
SELECT ...;
EOF
```

## Quick Start

```bash
${CLAUDE_PLUGIN_ROOT}/bin/cc-query --raw                      # Default log path
${CLAUDE_PLUGIN_ROOT}/bin/cc-query --raw /path/to/other.log   # Custom log file
```

## Views

| View               | Description                                      | Key Fields |
| ------------------ | ------------------------------------------------ | ---------- |
| `requests`         | All API requests                                 | `model`, `messages`, `tools`, `metadata`, `max_tokens`, `stream` |
| `responses`        | All API responses                                | `model`, `id`, `stop_reason`, `input_tokens`, `output_tokens`, `content` |
| `request_messages` | Unnested messages from requests                  | `rownum`, `message_index`, `role`, `content` |
| `request_tools`    | Unnested tools from requests                     | `rownum`, `tool_index`, `name`, `description`, `input_schema` |
| `system_prompts`   | Unnested system prompt blocks                    | `rownum`, `model`, `block_index`, `block_type`, `text_content` |
| `response_blocks`  | Unnested response content blocks                 | `rownum`, `block_index`, `block_type`, `text_content`, `tool_name` |
| `model_usage`      | Token usage stats by model                       | `model`, `response_count`, `total_input_tokens`, `total_output_tokens`, `avg_input_tokens`, `avg_output_tokens` |
| `raw_entries`      | Raw JSON for each log entry                      | `rownum`, `raw`, `entry_type` |

## Key Fields

**requests**: `rownum`, `model`, `messages` (JSON), `system` (JSON), `tools` (JSON), `metadata` (JSON), `max_tokens`, `stream`, `message_count`, `tool_count`

**responses**: `rownum`, `model`, `id`, `stop_reason`, `usage` (JSON), `input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_creation_tokens`, `content` (JSON array)

**request_messages**: `rownum` (links to request), `message_index`, `role`, `content` (JSON)

**request_tools**: `rownum` (links to request), `tool_index`, `name`, `description`, `input_schema` (JSON)

**system_prompts**: `rownum` (links to request), `model`, `block_index`, `block_type`, `text_content`, `raw_block` (JSON)

**response_blocks**: `rownum` (links to response), `block_index`, `block_type`, `text_content` (text or thinking), `tool_name`, `tool_id`, `tool_input` (JSON), `raw_block` (JSON)

## Example Queries

### Model usage breakdown
```sql
SELECT model, count(*) as requests FROM requests GROUP BY model ORDER BY requests DESC;
```

### Model usage with token stats
```sql
SELECT * FROM model_usage ORDER BY response_count DESC;
```

### Token usage by response
```sql
SELECT rownum, model, input_tokens, output_tokens, stop_reason
FROM responses ORDER BY rownum DESC LIMIT 10;
```

### Recent requests
```sql
SELECT rownum, model, message_count, tool_count, max_tokens
FROM requests ORDER BY rownum DESC LIMIT 10;
```

### Request/response counts
```sql
SELECT 'requests' as type, count(*) as cnt FROM requests
UNION ALL
SELECT 'responses', count(*) FROM responses;
```

### Tools defined in requests
```sql
SELECT DISTINCT name FROM request_tools ORDER BY name;
```

### Tool frequency across requests
```sql
SELECT name, count(*) as occurrences
FROM request_tools
GROUP BY name
ORDER BY occurrences DESC LIMIT 20;
```

### Requests by message count
```sql
SELECT rownum, model, message_count
FROM requests
ORDER BY message_count DESC LIMIT 10;
```

### Messages in a specific request
```sql
SELECT message_index, role, left(content::VARCHAR, 100) as preview
FROM request_messages
WHERE rownum = 123
ORDER BY message_index;
```

### Streaming vs non-streaming
```sql
SELECT stream, count(*) as requests
FROM requests
GROUP BY stream;
```

### Search system prompts for keywords
```sql
SELECT rownum, model, block_index, left(text_content, 200) as preview
FROM system_prompts
WHERE text_content ILIKE '%keyword%'
ORDER BY rownum DESC LIMIT 10;
```

### System prompt blocks by type
```sql
SELECT block_type, count(*) as occurrences
FROM system_prompts
GROUP BY block_type;
```

### Response block types (text, thinking, tool_use)
```sql
SELECT block_type, count(*) as occurrences
FROM response_blocks
GROUP BY block_type
ORDER BY occurrences DESC;
```

### Tool calls in responses
```sql
SELECT rownum, tool_name, tool_id
FROM response_blocks
WHERE block_type = 'tool_use'
ORDER BY rownum DESC LIMIT 20;
```

### Most used tools in responses
```sql
SELECT tool_name, count(*) as calls
FROM response_blocks
WHERE block_type = 'tool_use'
GROUP BY tool_name
ORDER BY calls DESC;
```

### Max tokens distribution
```sql
SELECT
  CASE
    WHEN max_tokens < 1000 THEN '<1k'
    WHEN max_tokens < 10000 THEN '1k-10k'
    WHEN max_tokens < 30000 THEN '10k-30k'
    ELSE '30k+'
  END as token_range,
  count(*) as requests
FROM requests
WHERE max_tokens IS NOT NULL
GROUP BY token_range
ORDER BY requests DESC;
```

## Common Analysis Patterns

### Quick Overview (Single Call)
```bash
cat << 'EOF' | ${CLAUDE_PLUGIN_ROOT}/bin/cc-query --raw
-- Token usage by model
SELECT model, response_count, total_input_tokens, total_output_tokens FROM model_usage ORDER BY response_count DESC;
-- Request stats
SELECT count(*) as total_requests, avg(message_count)::INTEGER as avg_msgs, avg(tool_count)::INTEGER as avg_tools FROM requests;
-- Top tools
SELECT name, count(*) as uses FROM request_tools GROUP BY name ORDER BY uses DESC LIMIT 10;
EOF
```

### Analyze Specific Request
```bash
cat << 'EOF' | ${CLAUDE_PLUGIN_ROOT}/bin/cc-query --raw
-- Find request by row number
SELECT rownum, model, message_count, tool_count FROM requests WHERE rownum = 123;
-- Get messages for that request
SELECT message_index, role, left(content::VARCHAR, 200) FROM request_messages WHERE rownum = 123;
-- Get tools for that request
SELECT name FROM request_tools WHERE rownum = 123;
EOF
```

## Performance Notes

- The log file can be large (100MB+). Queries scan the entire file.
- `request_messages` and `request_tools` views unnest arrays and can be memory-intensive on large files.
- For quick stats, prefer `requests` and `model_usage` views over unnested views.
- Use `LIMIT` to prevent excessive output.

## JSON Access

- `messages->'field'` returns JSON
- `messages->>'field'` returns string
- `content[1]` array access (1-indexed in DuckDB)
- `json_array_length(arr)` count array elements
- `UNNEST(CAST(json_array AS JSON[]))` expand arrays
