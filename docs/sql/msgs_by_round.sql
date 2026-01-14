-- Group messages into rounds starting with each human message
-- Replace SESSION_ID with the actual session UUID

WITH ranked AS (
  SELECT
    *,
    countIf(
      type = 'user'
      AND dynamicType(message.content) = 'String'
      AND agentId = ''
      AND isMeta = false
    ) OVER (ORDER BY timestamp) as round
  FROM messages
  WHERE sessionId = 'SESSION_ID'
)
SELECT
  round,
  count(*) as msgs,
  substring(
    maxIf(message.content::String, type = 'user' AND dynamicType(message.content) = 'String'),
    1, 60
  ) as prompt,
  min(timestamp) as started,
  groupArray(uuid) as uuids
FROM ranked
WHERE round > 0
GROUP BY round
ORDER BY round;
