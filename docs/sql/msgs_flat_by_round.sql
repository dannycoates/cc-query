-- Flat table of messages with round numbers and extracted content
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
  timestamp,
  uuid,
  type,
  agentId,
  CASE
    -- User message with string content
    WHEN type = 'user' AND dynamicType(message.content) = 'String'
      THEN message.content::String
    -- User message with array content (tool results)
    WHEN type = 'user'
      THEN arrayStringConcat(
        arrayMap(x -> JSONExtractString(x, 'content'), message.content::Array(String)),
        '\n'
      )
    -- Assistant message: text blocks, or [ToolName] {input} fallback
    WHEN type = 'assistant'
      THEN coalesce(
        nullIf(
          arrayStringConcat(
            arrayFilter(x -> notEquals(x, ''),
              arrayMap(x -> JSONExtractString(x, 'text'), message.content::Array(String))
            ),
            '\n'
          ),
          ''
        ),
        arrayStringConcat(
          arrayFilter(x -> notEquals(x, ''),
            arrayMap(x ->
              concat('[', JSONExtractString(x, 'name'), '] ', JSONExtractRaw(x, 'input')),
              message.content::Array(String)
            )
          ),
          '\n'
        )
      )
    -- System message
    WHEN type = 'system'
      THEN content
    ELSE ''
  END as msg
FROM ranked
WHERE round > 0
ORDER BY round, timestamp;
