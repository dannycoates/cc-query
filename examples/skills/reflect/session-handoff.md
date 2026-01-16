# Session Handoff Workflow

Use this when creating handoff summaries for work continuation. The goal is **1-2 bash calls total**.

## Target Metrics

| Metric | Target | Avoid |
|--------|--------|-------|
| Bash calls | 1-2 | 10+ |
| Time | 1-2 min | 5+ min |
| Agent spawns | 0-1 | 5+ |

## Single-Call Handoff Query

Run this single batched query to gather all handoff data:

```bash
cat << 'EOF' | cc-query .
-- 1. Today's sessions overview
SELECT sessionId, project, min(timestamp) as started, max(timestamp) as ended,
       count(*) as msgs, count(DISTINCT agentId) as agents
FROM messages WHERE DATE(timestamp) = CURRENT_DATE
GROUP BY sessionId, project ORDER BY started;

-- 2. All human messages from today (the actual work topics)
SELECT timestamp, project, left(content, 400) as content
FROM human_messages WHERE DATE(timestamp) = CURRENT_DATE
  AND content NOT LIKE '%<local-command%'
  AND content NOT LIKE '%<command-name%'
  AND length(content) > 20
ORDER BY timestamp;

-- 3. Tool activity summary
SELECT tool_name, count(*) as calls
FROM tool_uses WHERE DATE(timestamp) = CURRENT_DATE
GROUP BY tool_name ORDER BY calls DESC;

-- 4. Errors to note
SELECT timestamp, tool_name, left(result_content, 150) as error
FROM tool_results tr JOIN tool_uses tu ON tr.tool_use_id = tu.tool_id
WHERE DATE(tr.timestamp) = CURRENT_DATE AND tr.is_error
ORDER BY tr.timestamp LIMIT 10;

-- 5. Token usage today
SELECT sum(input_tokens) as input, sum(output_tokens) as output, sum(cache_read_tokens) as cached
FROM token_usage WHERE DATE(timestamp) = CURRENT_DATE;
EOF
```

## Date Range Variations

### Last N days
```sql
WHERE timestamp > now() - INTERVAL '3 days'
```

### Specific date range
```sql
WHERE DATE(timestamp) BETWEEN '2026-01-10' AND '2026-01-15'
```

### This week
```sql
WHERE timestamp > date_trunc('week', now())
```

## Cross-Project Handoff

When handoff spans multiple projects:

```bash
cat << 'EOF' | cc-query
-- All projects worked on recently
SELECT project, count(DISTINCT sessionId) as sessions,
       count(*) as msgs, max(timestamp) as last_activity
FROM messages WHERE timestamp > now() - INTERVAL '7 days'
GROUP BY project ORDER BY last_activity DESC;

-- Human messages across all projects
SELECT timestamp, project, left(content, 300) as topic
FROM human_messages WHERE timestamp > now() - INTERVAL '7 days'
  AND content NOT LIKE '%<local-command%'
  AND length(content) > 30
ORDER BY timestamp DESC LIMIT 50;
EOF
```

## Output Format

Structure the handoff summary as:

```markdown
# Session Handoff - [DATE]

## Work Summary
- **Sessions**: N sessions across M projects
- **Duration**: First activity at HH:MM, last at HH:MM
- **Focus areas**: [Inferred from human_messages]

## Key Activities
1. [Project A]: Brief description of work done
2. [Project B]: Brief description of work done

## In-Progress Items
- [Any incomplete tasks or open threads]

## Notes for Next Session
- [Relevant context, blockers, or next steps]

## Stats
| Metric | Value |
|--------|-------|
| Messages | X |
| Tool Calls | Y |
| Errors | Z |
| Tokens (input/output/cached) | A/B/C |
```
