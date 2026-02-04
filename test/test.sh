#!/bin/bash
# Runs cc-query tests against fixtures, compares to expected outputs
# Exit 0 if all pass, exit 1 if any fail

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES_DIR="$SCRIPT_DIR/fixtures"
EXPECTED_DIR="$SCRIPT_DIR/expected"
CC_QUERY="${CC_QUERY:-$SCRIPT_DIR/../bin/cc-query.js}"

PASSED=0
FAILED=0
FAILED_TESTS=""

# Check fixtures exist
if [[ ! -d "$FIXTURES_DIR" ]] || [[ -z "$(ls -A "$FIXTURES_DIR" 2>/dev/null)" ]]; then
  echo "Error: No fixtures found. Run ./test/collect.sh first."
  exit 1
fi

echo "=== cc-query Test Suite ==="
echo ""

# Load session prefix for filter test
if [[ -f "$EXPECTED_DIR/filter-session.prefix" ]]; then
  SESSION_PREFIX=$(cat "$EXPECTED_DIR/filter-session.prefix")
fi

# Define test runner functions for test mode
run_query_test() {
  local name="$1"
  local query="$2"
  local expected_file="$EXPECTED_DIR/$name.txt"

  if [[ ! -f "$expected_file" ]]; then
    echo "SKIP: $name (no expected output)"
    return
  fi

  local output
  output=$(echo "$query" | "$CC_QUERY" -d "$FIXTURES_DIR" 2>&1)
  local expected
  expected=$(cat "$expected_file")

  if [[ "$output" == "$expected" ]]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name"
    echo "  Expected:"
    head -3 "$expected_file" | sed 's/^/    /'
    echo "  Got:"
    echo "$output" | head -3 | sed 's/^/    /'
    FAILED=$((FAILED + 1))
    FAILED_TESTS="$FAILED_TESTS $name"
  fi
}

run_command_test() {
  local name="$1"
  shift
  local expected_file="$EXPECTED_DIR/$name.txt"

  if [[ ! -f "$expected_file" ]]; then
    echo "SKIP: $name (no expected output)"
    return
  fi

  local output
  output=$("$@" 2>&1) || true
  local expected
  expected=$(cat "$expected_file")

  if [[ "$output" == "$expected" ]]; then
    echo "PASS: $name"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: $name"
    echo "  Expected:"
    head -3 "$expected_file" | sed 's/^/    /'
    echo "  Got:"
    echo "$output" | head -3 | sed 's/^/    /'
    FAILED=$((FAILED + 1))
    FAILED_TESTS="$FAILED_TESTS $name"
  fi
}

run_session_filter_test() {
  local expected_file="$EXPECTED_DIR/filter-session.txt"

  if [[ -z "$SESSION_PREFIX" ]]; then
    echo "SKIP: filter-session (no prefix file)"
    return
  fi

  if [[ ! -f "$expected_file" ]]; then
    echo "SKIP: filter-session (no expected output)"
    return
  fi

  local output
  output=$(echo "SELECT count(*) FROM messages;" | "$CC_QUERY" -s "$SESSION_PREFIX" -d "$FIXTURES_DIR" 2>&1)
  local expected
  expected=$(cat "$expected_file")

  if [[ "$output" == "$expected" ]]; then
    echo "PASS: filter-session"
    PASSED=$((PASSED + 1))
  else
    echo "FAIL: filter-session"
    FAILED=$((FAILED + 1))
    FAILED_TESTS="$FAILED_TESTS filter-session"
  fi
}

# Run all test cases
source "$SCRIPT_DIR/test-cases.sh"

echo ""
echo "=== Summary ==="
echo "Passed: $PASSED"
echo "Failed: $FAILED"

if [[ $FAILED -gt 0 ]]; then
  echo ""
  echo "Failed tests:$FAILED_TESTS"
  exit 1
fi

echo ""
echo "All tests passed!"
exit 0
