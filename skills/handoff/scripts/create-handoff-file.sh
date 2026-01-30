#!/usr/bin/env bash
# Creates an empty handoff file with a descriptive name
# Usage: ./session-name.sh <session_id>
#    or: CLAUDE_SESSION_ID=xxx ./session-name.sh
#
# Output: Full path to created file (e.g., ./handoff--go-bash-cli-ast-parser.md)
#         Falls back to session ID if summary unavailable

set -euo pipefail

# Default CLAUDE_PLUGIN_ROOT to project root (3 levels up from scripts/)
CLAUDE_PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"

SESSION_ID="${1:-${CLAUDE_SESSION_ID:-}}"

if [[ -z "$SESSION_ID" ]]; then
  echo "Error: No session ID provided" >&2
  exit 1
fi

# Create file and output path
create_file() {
  local name="$1"
  local filepath="handoff--${name}.md"
  touch "$filepath"
  echo "$filepath"
  exit 0
}

# Fallback function
fallback() {
  create_file "$SESSION_ID"
}

# Get project directory from cc-query
PROJECT=$(cat << EOF | "${CLAUDE_PLUGIN_ROOT}/bin/cc-query" 2>/dev/null
SELECT DISTINCT project FROM messages WHERE sessionId = '$SESSION_ID' LIMIT 1;
EOF
) || fallback

# Extract just the project name (skip header line)
PROJECT=$(echo "$PROJECT" | tail -n +2 | tr -d '[:space:]')

if [[ -z "$PROJECT" ]]; then
  fallback
fi

# Build path to sessions-index.json
INDEX_FILE="$HOME/.claude/projects/$PROJECT/sessions-index.json"

if [[ ! -f "$INDEX_FILE" ]]; then
  fallback
fi

# Extract summary for this session using jq
SUMMARY=$(jq -r --arg sid "$SESSION_ID" \
  '.entries[] | select(.sessionId == $sid) | .summary // empty' \
  "$INDEX_FILE" 2>/dev/null) || fallback

if [[ -z "$SUMMARY" ]]; then
  fallback
fi

# Normalize to kebab-case:
# 1. Lowercase
# 2. Replace non-alphanumeric with dashes
# 3. Collapse multiple dashes
# 4. Trim leading/trailing dashes
# 5. Truncate to reasonable length (50 chars)
NAME=$(echo "$SUMMARY" \
  | tr '[:upper:]' '[:lower:]' \
  | sed 's/[^a-z0-9]/-/g' \
  | sed 's/-\+/-/g' \
  | sed 's/^-//;s/-$//' \
  | cut -c1-50)

create_file "$NAME"
