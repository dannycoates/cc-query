-- Fork Analysis Queries for Claude Code Sessions
-- Forks occur when a message has multiple children (branches in conversation tree)

-- 1. Find sessions with branches
-- Shows sessions that have fork points and how many extra branches they have
SELECT
  sessionId,
  count(DISTINCT parentUuid) as fork_points,
  sum(children - 1) as extra_branches
FROM (
  SELECT sessionId, parentUuid, count(*) as children
  FROM messages
  WHERE parentUuid IS NOT NULL
  GROUP BY sessionId, parentUuid
  HAVING children > 1
)
GROUP BY sessionId
ORDER BY fork_points DESC;

-- 2. Find fork points with their children
-- Shows which messages have multiple children and what types they are
SELECT
  sessionId,
  parentUuid,
  count(*) as child_count,
  groupArray(type) as child_types
FROM messages
WHERE parentUuid IS NOT NULL
GROUP BY sessionId, parentUuid
HAVING child_count > 1
ORDER BY child_count DESC
LIMIT 20;

-- 3. Analyze what types of messages tend to fork
-- System messages fork most (after tool results), then assistant, then user
WITH forks AS (
  SELECT sessionId, parentUuid, count(*) as children
  FROM messages
  WHERE parentUuid IS NOT NULL
  GROUP BY sessionId, parentUuid
  HAVING children > 1
)
SELECT
  m.type as parent_type,
  count(*) as fork_count,
  round(avg(f.children), 2) as avg_children
FROM forks f
JOIN messages m ON f.parentUuid = m.uuid AND f.sessionId = m.sessionId
GROUP BY parent_type
ORDER BY fork_count DESC;

-- 4. Show fork points with context for a specific session
-- Replace SESSION_ID with the actual session UUID
SELECT
  m.timestamp,
  m.type as parent_type,
  substring(
    CASE
      WHEN m.type = 'user' AND dynamicType(m.message.content) = 'String'
        THEN m.message.content::String
      WHEN m.type = 'system' THEN m.content
      ELSE ''
    END, 1, 80
  ) as parent_preview,
  f.children as child_count
FROM (
  SELECT parentUuid, count(*) as children
  FROM messages
  WHERE sessionId = 'SESSION_ID'
    AND parentUuid IS NOT NULL
  GROUP BY parentUuid
  HAVING children > 1
) f
JOIN messages m ON f.parentUuid = m.uuid
WHERE m.sessionId = 'SESSION_ID'
ORDER BY m.timestamp;

-- 5. Show all branches at each fork point for a specific session
-- Shows parent -> children relationships at forks
-- Replace SESSION_ID with the actual session UUID
SELECT
  parent.timestamp as fork_time,
  parent.type as parent_type,
  child.timestamp as child_time,
  child.type as child_type,
  substring(
    CASE
      WHEN child.type = 'user' AND dynamicType(child.message.content) = 'String'
        THEN child.message.content::String
      WHEN child.type = 'system' THEN child.content
      ELSE ''
    END, 1, 60
  ) as child_preview
FROM messages child
JOIN messages parent ON child.parentUuid = parent.uuid
  AND child.sessionId = parent.sessionId
WHERE child.sessionId = 'SESSION_ID'
  AND child.parentUuid IN (
    SELECT parentUuid
    FROM messages
    WHERE sessionId = 'SESSION_ID'
      AND parentUuid IS NOT NULL
    GROUP BY parentUuid
    HAVING count(*) > 1
  )
ORDER BY parent.timestamp, child.timestamp;

-- Fork types typically observed:
-- 1. Session resume: Multiple continuations after /compact
-- 2. Message edit: User changed message before sending
-- 3. User retry: Same message sent multiple times (escape + retry)
-- 4. API retry: Multiple assistant responses from same parent (rate limits, errors)
