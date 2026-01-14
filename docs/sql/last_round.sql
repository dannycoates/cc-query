-- Get all message content between the last user and assistant messages in a session
-- Replace YOUR_SESSION_ID with the actual session UUID

WITH session_bounds AS (
  SELECT
    maxIf(timestamp, type = 'user') as last_user_ts,
    maxIf(timestamp, type = 'assistant') as last_assistant_ts
  FROM messages
  WHERE sessionId = 'YOUR_SESSION_ID'
)
SELECT
  timestamp,
  type,
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
    -- Assistant message (extract text from text blocks)
    WHEN type = 'assistant'
      THEN arrayStringConcat(
        arrayFilter(x -> x != '',
          arrayMap(x -> JSONExtractString(x, 'text'), message.content::Array(String))
        ),
        '\n'
      )
    -- System message
    WHEN type = 'system'
      THEN content
    ELSE ''
  END as content_text
FROM messages, session_bounds
WHERE sessionId = 'YOUR_SESSION_ID'
  AND timestamp >= least(last_user_ts, last_assistant_ts)
  AND timestamp <= greatest(last_user_ts, last_assistant_ts)
ORDER BY timestamp;
