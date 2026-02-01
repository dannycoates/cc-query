const std = @import("std");
const Allocator = std.mem.Allocator;

/// Escape a path for SQL by replacing ' with ''
pub fn escapePathForSql(allocator: Allocator, path: []const u8) ![]const u8 {
    var result: std.ArrayListUnmanaged(u8) = .{};
    errdefer result.deinit(allocator);
    for (path) |c| {
        if (c == '\'') {
            try result.appendSlice(allocator, "''");
        } else {
            try result.append(allocator, c);
        }
    }
    return try result.toOwnedSlice(allocator);
}

/// Column definitions for explicit schema
const columns_def =
    \\'uuid': 'UUID', 'type': 'VARCHAR', 'subtype': 'VARCHAR', 'parentUuid': 'UUID',
    \\'timestamp': 'TIMESTAMP', 'sessionId': 'UUID', 'cwd': 'VARCHAR', 'gitBranch': 'VARCHAR',
    \\'slug': 'VARCHAR', 'version': 'VARCHAR', 'isSidechain': 'BOOLEAN', 'userType': 'VARCHAR',
    \\'message': 'JSON', 'isCompactSummary': 'BOOLEAN', 'isMeta': 'BOOLEAN',
    \\'isVisibleInTranscriptOnly': 'BOOLEAN', 'sourceToolUseID': 'VARCHAR',
    \\'thinkingMetadata': 'JSON', 'todos': 'JSON', 'toolUseResult': 'JSON',
    \\'error': 'JSON', 'isApiErrorMessage': 'BOOLEAN', 'requestId': 'VARCHAR',
    \\'sourceToolAssistantUUID': 'UUID', 'content': 'VARCHAR', 'compactMetadata': 'JSON',
    \\'hasOutput': 'BOOLEAN', 'hookCount': 'INTEGER', 'hookErrors': 'JSON',
    \\'hookInfos': 'JSON', 'level': 'VARCHAR', 'logicalParentUuid': 'UUID',
    \\'maxRetries': 'INTEGER', 'preventedContinuation': 'BOOLEAN', 'retryAttempt': 'INTEGER',
    \\'retryInMs': 'INTEGER', 'stopReason': 'VARCHAR', 'toolUseID': 'VARCHAR'
;

/// Generate the SQL to create all views
/// file_pattern should be formatted for SQL (e.g., '/path/*.jsonl' or ['/a.jsonl', '/b.jsonl'])
pub fn getCreateViewsSql(allocator: Allocator, file_pattern: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\-- Base messages view with explicit schema for type safety
        \\CREATE OR REPLACE VIEW messages AS
        \\SELECT
        \\  uuid,
        \\  type,
        \\  subtype,
        \\  parentUuid,
        \\  timestamp,
        \\  sessionId,
        \\  cwd,
        \\  gitBranch,
        \\  slug,
        \\  version,
        \\  isSidechain,
        \\  userType,
        \\  message,
        \\  isCompactSummary,
        \\  isMeta,
        \\  isVisibleInTranscriptOnly,
        \\  sourceToolUseID,
        \\  sourceToolAssistantUUID,
        \\  thinkingMetadata,
        \\  todos,
        \\  toolUseResult,
        \\  error,
        \\  isApiErrorMessage,
        \\  requestId,
        \\  content,
        \\  compactMetadata,
        \\  hasOutput,
        \\  hookCount,
        \\  hookErrors,
        \\  hookInfos,
        \\  level,
        \\  logicalParentUuid,
        \\  maxRetries,
        \\  preventedContinuation,
        \\  retryAttempt,
        \\  retryInMs,
        \\  stopReason,
        \\  toolUseID,
        \\  -- Derived fields
        \\  regexp_extract(filename, '[^/]+$') as file,
        \\  starts_with(regexp_extract(filename, '[^/]+$'), 'agent-') as isAgent,
        \\  CASE WHEN starts_with(regexp_extract(filename, '[^/]+$'), 'agent-')
        \\       THEN regexp_extract(regexp_extract(filename, '[^/]+$'), 'agent-([^.]+)', 1)
        \\       ELSE NULL
        \\  END as agentId,
        \\  -- Extract project slug (directory after /projects/)
        \\  regexp_extract(filename, '/projects/([^/]+)/', 1) as project,
        \\  ordinality as rownum
        \\FROM read_ndjson(
        \\  {s},
        \\  filename=true,
        \\  ignore_errors=true,
        \\  columns={{{s}}}
        \\) WITH ORDINALITY
        \\WHERE type IN ('user', 'assistant', 'system');
        \\
        \\-- User messages view
        \\CREATE OR REPLACE VIEW user_messages AS
        \\SELECT
        \\  uuid, parentUuid, timestamp, sessionId, cwd, gitBranch, slug, version,
        \\  isSidechain, userType, message, isCompactSummary, isMeta,
        \\  isVisibleInTranscriptOnly, sourceToolUseID, sourceToolAssistantUUID,
        \\  thinkingMetadata, todos, toolUseResult, file, isAgent, agentId, project, rownum
        \\FROM messages
        \\WHERE type = 'user';
        \\
        \\-- Human-typed messages (excludes tool results and system-injected text)
        \\CREATE OR REPLACE VIEW human_messages AS
        \\SELECT
        \\  uuid, parentUuid, timestamp, sessionId, cwd, gitBranch, slug, version,
        \\  isSidechain, message->>'content' as content, file, project, rownum
        \\FROM user_messages
        \\WHERE json_type(message->'content') = 'VARCHAR'
        \\  AND (agentId IS NULL OR agentId = '')
        \\  AND (isMeta IS NULL OR isMeta = false);
        \\
        \\-- Assistant messages view
        \\CREATE OR REPLACE VIEW assistant_messages AS
        \\SELECT
        \\  uuid, parentUuid, timestamp, sessionId, cwd, gitBranch, slug, version,
        \\  isSidechain, userType, message, error, isApiErrorMessage, requestId,
        \\  file, isAgent, agentId, project, rownum
        \\FROM messages
        \\WHERE type = 'assistant';
        \\
        \\-- System messages view
        \\CREATE OR REPLACE VIEW system_messages AS
        \\SELECT
        \\  uuid, subtype, parentUuid, timestamp, sessionId, cwd, gitBranch, slug,
        \\  version, isSidechain, userType, content, error, compactMetadata,
        \\  hasOutput, hookCount, hookErrors, hookInfos, level, logicalParentUuid,
        \\  maxRetries, preventedContinuation, retryAttempt, retryInMs, stopReason,
        \\  toolUseID, isMeta, file, isAgent, agentId, project, rownum
        \\FROM messages
        \\WHERE type = 'system';
        \\
        \\-- Raw messages view with full JSON string
        \\CREATE OR REPLACE VIEW raw_messages AS
        \\SELECT
        \\  (json->>'uuid')::UUID as uuid,
        \\  json as raw
        \\FROM read_ndjson_objects({s}, ignore_errors=true)
        \\WHERE json->>'uuid' IS NOT NULL AND length(json->>'uuid') > 0;
        \\
        \\-- Tool uses: All tool calls with unnested content blocks
        \\CREATE OR REPLACE VIEW tool_uses AS
        \\SELECT
        \\  m.uuid,
        \\  m.timestamp,
        \\  m.sessionId,
        \\  m.isAgent,
        \\  m.agentId,
        \\  m.project,
        \\  m.rownum,
        \\  block->>'name' as tool_name,
        \\  block->>'id' as tool_id,
        \\  block->'input' as tool_input,
        \\  row_number() OVER (PARTITION BY m.uuid ORDER BY (SELECT NULL)) - 1 as block_index
        \\FROM assistant_messages m,
        \\LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
        \\WHERE block->>'type' = 'tool_use';
        \\
        \\-- Tool results: All tool results with duration
        \\CREATE OR REPLACE VIEW tool_results AS
        \\WITH array_messages AS (
        \\  SELECT * FROM user_messages
        \\  WHERE json_type(message->'content') = 'ARRAY'
        \\)
        \\SELECT
        \\  m.uuid,
        \\  m.timestamp,
        \\  m.sessionId,
        \\  m.isAgent,
        \\  m.agentId,
        \\  m.project,
        \\  m.rownum,
        \\  block->>'tool_use_id' as tool_use_id,
        \\  CAST(block->>'is_error' AS BOOLEAN) as is_error,
        \\  block->>'content' as result_content,
        \\  CAST(m.toolUseResult->>'durationMs' AS INTEGER) as duration_ms,
        \\  m.sourceToolAssistantUUID
        \\FROM array_messages m,
        \\LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block)
        \\WHERE block->>'type' = 'tool_result';
        \\
        \\-- Token usage: Pre-cast token counts
        \\CREATE OR REPLACE VIEW token_usage AS
        \\SELECT
        \\  uuid,
        \\  timestamp,
        \\  sessionId,
        \\  isAgent,
        \\  agentId,
        \\  project,
        \\  message->>'model' as model,
        \\  message->>'stop_reason' as stop_reason,
        \\  CAST(message->'usage'->>'input_tokens' AS BIGINT) as input_tokens,
        \\  CAST(message->'usage'->>'output_tokens' AS BIGINT) as output_tokens,
        \\  CAST(message->'usage'->>'cache_read_input_tokens' AS BIGINT) as cache_read_tokens,
        \\  CAST(message->'usage'->>'cache_creation_input_tokens' AS BIGINT) as cache_creation_tokens
        \\FROM assistant_messages
        \\WHERE (message->'usage') IS NOT NULL;
        \\
        \\-- Bash commands: Bash tool uses with extracted command
        \\CREATE OR REPLACE VIEW bash_commands AS
        \\SELECT
        \\  uuid,
        \\  timestamp,
        \\  sessionId,
        \\  isAgent,
        \\  agentId,
        \\  project,
        \\  rownum,
        \\  tool_id,
        \\  tool_input->>'command' as command,
        \\  tool_input->>'description' as description,
        \\  CAST(tool_input->>'timeout' AS INTEGER) as timeout,
        \\  CAST(tool_input->>'run_in_background' AS BOOLEAN) as run_in_background
        \\FROM tool_uses
        \\WHERE tool_name = 'Bash';
        \\
        \\-- File operations: Read/Write/Edit/Glob/Grep with extracted paths
        \\CREATE OR REPLACE VIEW file_operations AS
        \\SELECT
        \\  uuid,
        \\  timestamp,
        \\  sessionId,
        \\  isAgent,
        \\  agentId,
        \\  project,
        \\  rownum,
        \\  tool_id,
        \\  tool_name,
        \\  COALESCE(
        \\    tool_input->>'file_path',
        \\    tool_input->>'path'
        \\  ) as file_path,
        \\  tool_input->>'pattern' as pattern
        \\FROM tool_uses
        \\WHERE tool_name IN ('Read', 'Write', 'Edit', 'Glob', 'Grep');
    , .{ file_pattern, columns_def, file_pattern });
}

test "escapePathForSql escapes single quotes" {
    const allocator = std.testing.allocator;
    const result = try escapePathForSql(allocator, "/path/with'quote");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("/path/with''quote", result);
}

test "getCreateViewsSql generates valid SQL" {
    const allocator = std.testing.allocator;
    const sql = try getCreateViewsSql(allocator, "'/test/*.jsonl'");
    defer allocator.free(sql);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE OR REPLACE VIEW messages") != null);
    try std.testing.expect(std.mem.indexOf(u8, sql, "CREATE OR REPLACE VIEW tool_uses") != null);
}
