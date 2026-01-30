#!/usr/bin/env bash
# Get full content by ID (auto-detects tool calls vs messages)
# Usage: ./get-content.sh <id> [type] [session_id]
#   id: tool_id (starts with 'toolu_') or 8-char uuid prefix
#   type: U (human), T (thinking), A (assistant) - required for message IDs
#   session_id: optional, defaults to CLAUDE_SESSION_ID

set -euo pipefail

CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"

ID="${1:-}"

if [[ -z "$ID" ]]; then
  echo "Usage: $0 <id> [type] [session_id]" >&2
  echo "  id: tool_id (starts with 'toolu_') or 8-char uuid prefix" >&2
  echo "  type: U (human), T (thinking), A (assistant) - required for messages" >&2
  exit 1
fi

# Auto-detect tool calls by ID prefix
if [[ "$ID" == toolu_* ]]; then
  # For tool calls: arg2 is session_id (type not needed)
  SESSION_ID="${2:-${CLAUDE_SESSION_ID:-}}"
  if [[ -z "$SESSION_ID" ]]; then
    echo "Error: Session ID required (pass as arg or set CLAUDE_SESSION_ID)" >&2
    exit 1
  fi
  cat << EOF | ${CLAUDE_PLUGIN_ROOT}/bin/cc-query -s "$SESSION_ID"
SELECT tu.tool_name, tu.tool_input, tr.result_content, tr.is_error
FROM tool_uses tu
LEFT JOIN tool_results tr ON tu.tool_id = tr.tool_use_id
WHERE tu.tool_id = '${ID}';
EOF
  exit 0
fi

# For messages: arg2 is type, arg3 is session_id
TYPE="${2:-}"
SESSION_ID="${3:-${CLAUDE_SESSION_ID:-}}"

if [[ -z "$TYPE" ]]; then
  echo "Error: Type required for message IDs (U, T, or A)" >&2
  exit 1
fi

if [[ -z "$SESSION_ID" ]]; then
  echo "Error: Session ID required (pass as arg or set CLAUDE_SESSION_ID)" >&2
  exit 1
fi

case "$TYPE" in
  U|u)
    cat << EOF | ${CLAUDE_PLUGIN_ROOT}/bin/cc-query -s "$SESSION_ID"
SELECT content FROM human_messages WHERE uuid::VARCHAR LIKE '${ID}%';
EOF
    ;;
  T|t)
    cat << EOF | ${CLAUDE_PLUGIN_ROOT}/bin/cc-query -s "$SESSION_ID"
SELECT json_extract_string(block, '$.thinking') as thinking
FROM assistant_messages,
LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
WHERE uuid::VARCHAR LIKE '${ID}%' AND json_extract_string(block, '$.type') = 'thinking';
EOF
    ;;
  A|a)
    cat << EOF | ${CLAUDE_PLUGIN_ROOT}/bin/cc-query -s "$SESSION_ID"
SELECT json_extract_string(block, '$.text') as response
FROM assistant_messages,
LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
WHERE uuid::VARCHAR LIKE '${ID}%' AND json_extract_string(block, '$.type') = 'text';
EOF
    ;;
  *)
    echo "Error: Unknown type '$TYPE'. Use U, T, or A." >&2
    exit 1
    ;;
esac
