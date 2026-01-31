#!/bin/bash
# Collects fixtures and expected outputs for cc-query tests
# Run this once to set up test data, then commit results

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
EXPECTED_DIR="$SCRIPT_DIR/expected"
CC_QUERY="$SCRIPT_DIR/../bin/cc-query.js"

echo "=== cc-query Test Fixture Collector ==="
echo ""

# Clean existing fixtures and expected outputs
rm -rf "$FIXTURES_DIR"/* "$EXPECTED_DIR"/*
mkdir -p "$FIXTURES_DIR" "$EXPECTED_DIR"

echo "Step 1: Finding suitable sessions..."
echo ""

# Find a simple session (no agents, 10-50 messages)
echo "Looking for simple session (no agents, 10-50 messages)..."
SIMPLE_RESULT=$(echo "
  SELECT sessionId, count(*) as cnt
  FROM messages
  WHERE NOT isAgent
  GROUP BY sessionId
  HAVING cnt BETWEEN 10 AND 50
  ORDER BY cnt
  LIMIT 1;
" | "$CC_QUERY" 2>/dev/null | tail -1)

SIMPLE_SESSION=$(echo "$SIMPLE_RESULT" | cut -f1)
echo "Found simple session: $SIMPLE_SESSION"

# Find a complex session (with actual subagent files)
echo "Looking for complex session (with subagent files)..."
COMPLEX_SESSION=""
# Get candidate sessions with agent messages, then check for actual subagent files
while IFS=$'\t' read -r session_id agents msgs; do
  [[ "$session_id" == "sessionId" ]] && continue  # skip header
  CANDIDATE_FILE=$(find ~/.claude/projects -maxdepth 3 -name "${session_id}.jsonl" 2>/dev/null | head -1)
  if [[ -n "$CANDIDATE_FILE" ]]; then
    CANDIDATE_DIR="${CANDIDATE_FILE%.jsonl}"
    if [[ -d "$CANDIDATE_DIR/subagents" ]] && ls "$CANDIDATE_DIR/subagents"/*.jsonl &>/dev/null; then
      COMPLEX_SESSION="$session_id"
      break
    fi
  fi
done < <(echo "
  SELECT sessionId, count(DISTINCT agentId) as agents, count(*) as msgs
  FROM messages
  WHERE isAgent
  GROUP BY sessionId
  HAVING agents >= 2
  ORDER BY agents DESC
  LIMIT 20;
" | "$CC_QUERY" 2>/dev/null)

if [[ -n "$COMPLEX_SESSION" ]]; then
  echo "Found complex session: $COMPLEX_SESSION"
else
  echo "Warning: No session with subagent files found"
fi

echo ""
echo "Step 2: Copying session files to fixtures..."
echo ""

# Find and copy simple session file
SIMPLE_FILE=$(find ~/.claude/projects -name "${SIMPLE_SESSION}.jsonl" 2>/dev/null | head -1)
if [[ -n "$SIMPLE_FILE" ]]; then
  cp "$SIMPLE_FILE" "$FIXTURES_DIR/simple.jsonl"
  echo "Copied simple session to fixtures/simple.jsonl"
else
  echo "Warning: Could not find simple session file"
fi

# Find and copy complex session files (main + subagents)
COMPLEX_MAIN=$(find ~/.claude/projects -maxdepth 3 -name "${COMPLEX_SESSION}.jsonl" 2>/dev/null | head -1)
if [[ -n "$COMPLEX_MAIN" ]]; then
  mkdir -p "$FIXTURES_DIR/complex/subagents"
  cp "$COMPLEX_MAIN" "$FIXTURES_DIR/complex/${COMPLEX_SESSION}.jsonl"
  echo "Copied complex main session"
  # Copy subagent files (directory is alongside the .jsonl file)
  COMPLEX_DIR="${COMPLEX_MAIN%.jsonl}"
  if [[ -d "$COMPLEX_DIR/subagents" ]]; then
    cp "$COMPLEX_DIR/subagents"/*.jsonl "$FIXTURES_DIR/complex/subagents/" 2>/dev/null || true
    echo "Copied subagent files"
  fi
else
  echo "Warning: Could not find complex session file"
fi

echo ""
echo "Step 3: Generating expected outputs..."
echo ""

# Store session prefix for filter test
if [[ -n "$SIMPLE_SESSION" ]]; then
  SESSION_PREFIX="${SIMPLE_SESSION:0:8}"
  echo "$SESSION_PREFIX" > "$EXPECTED_DIR/filter-session.prefix"
fi

# Define test runner functions for collect mode
run_query_test() {
  local name="$1"
  local query="$2"
  echo "  $name"
  echo "$query" | "$CC_QUERY" -d "$FIXTURES_DIR" > "$EXPECTED_DIR/$name.txt" 2>&1
}

run_command_test() {
  local name="$1"
  shift
  echo "  $name"
  "$@" > "$EXPECTED_DIR/$name.txt" 2>&1 || true
}

run_session_filter_test() {
  if [[ -n "$SESSION_PREFIX" ]]; then
    echo "  filter-session (prefix: $SESSION_PREFIX)"
    echo "SELECT count(*) FROM messages;" | "$CC_QUERY" -s "$SESSION_PREFIX" -d "$FIXTURES_DIR" > "$EXPECTED_DIR/filter-session.txt" 2>&1
  else
    echo "  filter-session (SKIPPED - no session prefix)"
  fi
}

# Run all test cases
source "$SCRIPT_DIR/test-cases.sh"

echo ""
echo "=== Collection Complete ==="
echo ""
echo "Fixtures:"
find "$FIXTURES_DIR" -name "*.jsonl" | while read f; do
  echo "  $(basename "$f"): $(wc -l < "$f") lines"
done

echo ""
echo "Expected outputs:"
ls -1 "$EXPECTED_DIR"/*.txt | while read f; do
  echo "  $(basename "$f")"
done

echo ""
echo "Run ./test/test.sh to verify tests pass"
