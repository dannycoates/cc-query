#!/bin/bash
# Shared test case definitions
# Sourced by both collect.sh and test.sh
#
# Before sourcing, define these functions:
#   run_query_test <name> <query>     - Run SQL query test
#   run_command_test <name> <cmd...>  - Run command test
#   run_session_filter_test           - Run session filter test (uses SESSION_PREFIX)

# =============================================================================
# Core Functionality
# =============================================================================
echo "Core Functionality:"
run_command_test "help" "$CC_QUERY" --help
run_query_test "count-all" "SELECT count(*) FROM messages;"
run_query_test "group-by-type" "SELECT type, count(*) as cnt FROM messages GROUP BY type ORDER BY type;"
run_query_test "schema-all" ".schema"
run_query_test "schema-messages" ".schema messages"

# =============================================================================
# Base Views
# =============================================================================
echo ""
echo "Base Views:"
run_query_test "view-user-messages" "SELECT count(*) FROM user_messages;"
run_query_test "view-assistant-messages" "SELECT count(*) FROM assistant_messages;"
run_query_test "view-system-messages" "SELECT count(*) FROM system_messages;"
run_query_test "view-human-messages" "SELECT count(*) FROM human_messages;"
run_query_test "view-raw-messages" "SELECT count(*) FROM raw_messages;"

# =============================================================================
# Convenience Views
# =============================================================================
echo ""
echo "Convenience Views:"
run_query_test "view-tool-uses" "SELECT tool_name, count(*) as cnt FROM tool_uses GROUP BY tool_name ORDER BY tool_name LIMIT 10;"
run_query_test "view-tool-results" "SELECT count(*) FROM tool_results;"
run_query_test "view-token-usage" "SELECT count(*) FROM token_usage;"
run_query_test "view-bash-commands" "SELECT count(*) FROM bash_commands;"
run_query_test "view-file-operations" "SELECT count(*) FROM file_operations;"

# =============================================================================
# JSON Access (from reflect skill)
# =============================================================================
echo ""
echo "JSON Access:"
run_query_test "json-extract" "SELECT message->>'role' as role FROM messages WHERE type='assistant' LIMIT 1;"
run_query_test "json-nested" "SELECT message->'usage'->>'input_tokens' as tokens FROM assistant_messages WHERE json_type(message->'usage') = 'OBJECT' LIMIT 1;"
run_query_test "json-extract-string" "SELECT json_extract_string(message, '\$.role') as role FROM assistant_messages LIMIT 1;"
run_query_test "json-array-access" "SELECT message->'content'->0->>'type' as block_type FROM assistant_messages WHERE json_type(message->'content') = 'ARRAY' LIMIT 1;"

# =============================================================================
# UNNEST Patterns (from reflect/json-queries.md)
# =============================================================================
echo ""
echo "UNNEST Patterns:"
run_query_test "unnest-content-blocks" "SELECT block->>'type' as block_type, count(*) as cnt FROM assistant_messages, LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block) WHERE json_type(message->'content') = 'ARRAY' GROUP BY block_type ORDER BY cnt DESC LIMIT 5;"
run_query_test "unnest-tool-uses" "SELECT block->>'name' as tool FROM assistant_messages, LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block) WHERE block->>'type' = 'tool_use' LIMIT 3;"

# =============================================================================
# Token Usage Queries (from reflect skill)
# =============================================================================
echo ""
echo "Token Usage:"
run_query_test "token-sum" "SELECT sum(input_tokens) as input, sum(output_tokens) as output FROM token_usage;"
run_query_test "token-by-model" "SELECT model, count(*) as messages, sum(output_tokens) as total_output FROM token_usage GROUP BY model ORDER BY messages DESC LIMIT 3;"
run_query_test "stop-reason-counts" "SELECT message->>'stop_reason' as reason, count(*) as cnt FROM assistant_messages GROUP BY reason ORDER BY cnt DESC;"

# =============================================================================
# Session Analysis (from reflect skill)
# =============================================================================
echo ""
echo "Session Analysis:"
run_query_test "session-summary" "SELECT sessionId, count(*) as msgs, min(timestamp) as started FROM messages GROUP BY sessionId ORDER BY started DESC LIMIT 3;"
run_query_test "agent-breakdown" "SELECT isAgent, count(*) as messages, count(DISTINCT agentId) as agents FROM messages GROUP BY isAgent ORDER BY isAgent;"
run_query_test "project-stats" "SELECT project, count(*) as msgs FROM messages GROUP BY project ORDER BY msgs DESC LIMIT 3;"

# =============================================================================
# Date/Time Functions (from reflect/advanced-queries.md)
# =============================================================================
echo ""
echo "Date/Time Functions:"
run_query_test "date-trunc" "SELECT date_trunc('hour', timestamp) as hour, count(*) as msgs FROM messages GROUP BY hour ORDER BY hour DESC LIMIT 3;"
run_query_test "extract-hour" "SELECT extract(hour FROM timestamp) as hour, count(*) as msgs FROM messages GROUP BY hour ORDER BY msgs DESC LIMIT 3;"

# =============================================================================
# String Functions (from handoff skill)
# =============================================================================
echo ""
echo "String Functions:"
run_query_test "left-truncate" "SELECT left(content, 50) as preview FROM human_messages LIMIT 1;"
run_query_test "concat-fields" "SELECT concat(type, ': ', CAST(count(*) AS VARCHAR)) as summary FROM messages GROUP BY type ORDER BY type LIMIT 3;"
run_query_test "replace-newlines" "SELECT replace(content, chr(10), '\\\\n') as escaped FROM human_messages WHERE content LIKE '%\n%' LIMIT 1;"

# =============================================================================
# JOIN Patterns (from handoff/session-summary.sh)
# =============================================================================
echo ""
echo "JOIN Patterns:"
run_query_test "tool-use-result-join" "SELECT tu.tool_name, tr.is_error, tr.duration_ms FROM tool_uses tu LEFT JOIN tool_results tr ON tu.tool_id = tr.tool_use_id ORDER BY tu.tool_name, tr.is_error NULLS FIRST LIMIT 5;"
run_query_test "tool-error-join" "SELECT tu.tool_name, count(*) as errors FROM tool_uses tu JOIN tool_results tr ON tu.tool_id = tr.tool_use_id WHERE tr.is_error = true GROUP BY tu.tool_name ORDER BY errors DESC, tu.tool_name LIMIT 3;"

# =============================================================================
# CTE Patterns (from reflect/advanced-queries.md)
# =============================================================================
echo ""
echo "CTE Patterns:"
run_query_test "cte-basic" "WITH msg_counts AS (SELECT type, count(*) as cnt FROM messages GROUP BY type) SELECT * FROM msg_counts ORDER BY cnt DESC;"
run_query_test "cte-filter" "WITH array_msgs AS (SELECT * FROM assistant_messages WHERE json_type(message->'content') = 'ARRAY') SELECT count(*) FROM array_msgs;"

# =============================================================================
# FILTER Clause (from reflect/advanced-queries.md)
# =============================================================================
echo ""
echo "FILTER Clause:"
run_query_test "filter-clause" "SELECT count(*) as total, count(*) FILTER (WHERE type = 'assistant') as assistant_only FROM messages;"

# =============================================================================
# UUID Matching (from pickup skill)
# =============================================================================
echo ""
echo "UUID Matching:"
run_query_test "uuid-like-match" "SELECT count(*) FROM messages WHERE uuid::VARCHAR LIKE (SELECT left(uuid::VARCHAR, 8) FROM messages LIMIT 1) || '%';"

# =============================================================================
# Derived Fields
# =============================================================================
echo ""
echo "Derived Fields:"
run_query_test "derived-isagent" "SELECT isAgent, count(*) as cnt FROM messages GROUP BY isAgent;"
run_query_test "derived-project" "SELECT project, count(*) as cnt FROM messages WHERE project IS NOT NULL GROUP BY project ORDER BY cnt DESC LIMIT 3;"
run_query_test "derived-rownum" "SELECT rownum, type FROM messages ORDER BY rownum LIMIT 3;"

# =============================================================================
# Session Filtering
# =============================================================================
echo ""
echo "Session Filtering:"
run_session_filter_test

# =============================================================================
# Multiple Queries
# =============================================================================
echo ""
echo "Multiple Queries:"
run_query_test "multiple-queries" "SELECT count(*) FROM messages; SELECT count(*) FROM tool_uses;"

# =============================================================================
# Error Handling
# =============================================================================
echo ""
echo "Error Handling:"
run_command_test "error-no-sessions" "$CC_QUERY" -d "/nonexistent/path/that/does/not/exist"
