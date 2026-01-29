# Handoff Document Template

Generate the handoff document by processing each section below. For each section:
1. Read the `<instructions>` to understand what content to include
2. Fill in the `{placeholders}` in the `<template>` with analyzed data
3. Output the filled template text (not the XML tags)

**Output file:** Write to the file created by `session-name.sh` (see SKILL.md)

---
<document>
<section name="Header">
<instructions>
Extract from session-summary.sh output:
- Duration in minutes and timestamps (started/ended)
- Total message count
- Agent count (from agents row)
- Token totals (input_tokens, output_tokens)
</instructions>
<template>
# Session Handoff: ${CLAUDE_SESSION_ID}

**Generated:** {current_timestamp}
**Duration:** {duration_minutes} minutes ({start_time} - {end_time})
**Messages:** {total_messages} | **Agents:** {agent_count} | **Tokens:** {input_tokens}/{output_tokens}
</template>
</section>

<section name="Executive Summary">
<instructions>
Write 2-3 sentences per distinct task identified in the session:
- What was the primary goal?
- What was accomplished?
- What is the current state?

Keep it concise but complete enough for someone to understand the session at a glance.
</instructions>
<template>
## Executive Summary

{summary_paragraphs}
</template>
</section>

<section name="Tasks">
<instructions>
Extract tasks from human messages chronologically:
1. **Task Initiations**: "implement X", "fix Y", "add Z", questions that spawn work
2. **Clarifications**: Follow-ups, corrections, scope changes
3. **Completions**: Acknowledgments like "looks good", "that works"

Determine status from final state:
- **completed**: User acknowledged or work finished without blockers
- **in progress**: Work started but no completion signal
- **blocked**: Errors encountered and not resolved
- **not started**: Mentioned but no work done

Use action-oriented task names: "Add dark mode toggle" not "Dark mode"
</instructions>
<template>
## Tasks

| Task | Status | Files | Notes |
|------|--------|-------|-------|
| {task_name} | {status} | {key_files} | {blockers_or_context} |
</template>
</section>

<section name="Files Modified">
<instructions>
From the touched files table:
- Include files with Edit (e) or Write (w) operations
- Provide brief description of what changed
- Use absolute paths
</instructions>
<template>
## Files Modified

| File | Operations | Summary of Changes |
|------|------------|-------------------|
| {absolute_path} | {operations} | {change_description} |
</template>
</section>

<section name="Key Edits">
<instructions>
For significant Edit operations, summarize actual code changes:
- Show old code snippet → new code snippet
- Explain the reason/purpose
- Prioritize edits that are important for understanding the work done
</instructions>
<template>
## Key Edits

- **{file_path}**: Changed `{old_code}` to `{new_code}` - {reason}
- **{file_path}**: Added {description} - {reason}
</template>
</section>

<section name="Mistakes & Corrections">
<instructions>
Document instances where the user corrected Claude's approach or output:
- What did the user say?
- What was wrong with Claude's understanding/action?
- How was it resolved?

ALWAYS include this section. If no corrections occurred, write:
"No corrections were needed during this session."
</instructions>
<template>
## Mistakes & Corrections

| Time | User Said | What Was Wrong | Resolution |
|------|-----------|----------------|------------|
| {time} | "{user_correction}" | {what_was_wrong} | {how_fixed} |
</template>
</section>

<section name="Errors & Blockers">
<instructions>
List any unresolved errors with sufficient context for the next session.
Include:
- Error message or description
- What was being attempted
- Any partial workarounds tried

OMIT this entire section if there are no errors or blockers.
</instructions>
<template>
## Errors & Blockers

- {error_description}
</template>
</section>

<section name="Key Conversation Flow">
<instructions>
Capture the dialogue using importance rating (include only 3+ importance):
- Include 10-50% of total messages
- Show both user requests AND Claude's reasoning/responses

Speaker codes:
- U = User message
- A = Agent/Assistant response
- T = Thinking block
- C = Tool Call

Importance Rating Guide:
| Rating | Criteria | Include? |
|--------|----------|----------|
| 5 | Task definition, blocking errors, final deliverables | Always |
| 4 | Significant code changes, key decisions | Always |
| 3 | Standard implementation, normal operations | Selectively |
| 2 | Routine checks, minor clarifications | Omit |
| 1 | Acknowledgments, trivial exchanges | Omit |
</instructions>
<template>
## Key Conversation Flow

Speaker codes:
- U = User message
- A = Agent/Assistant response
- T = Thinking block
- C = Tool Call

| ID | Time | Speaker | Summary |
|----|------|---------|---------|
| {id} | {time} | {speaker} | {summary} |

To retrieve full content for any row:

```bash
# For messages (U, T, A) - ID is 8-char uuid prefix
cat << 'EOF' | ${CLAUDE_PLUGIN_ROOT}/bin/cc-query -s "${CLAUDE_SESSION_ID}"
SELECT content FROM human_messages WHERE uuid::VARCHAR LIKE '{id}%';  -- U
SELECT block->>'thinking' FROM assistant_messages, LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block) WHERE uuid::VARCHAR LIKE '{id}%' AND block->>'type' = 'thinking';  -- T
SELECT block->>'text' FROM assistant_messages, LATERAL UNNEST(CAST(message->'content' AS JSON[])) as t(block) WHERE uuid::VARCHAR LIKE '{id}%' AND block->>'type' = 'text';  -- A
EOF

# For tool calls (C) - ID is full tool_id
cat << 'EOF' | ${CLAUDE_PLUGIN_ROOT}/bin/cc-query -s "${CLAUDE_SESSION_ID}"
SELECT tu.tool_input, tr.result_content FROM tool_uses tu LEFT JOIN tool_results tr ON tu.tool_id = tr.tool_use_id WHERE tu.tool_id = '{tool_id}';
EOF
```
</template>
</section>

<section name="Next Steps">
<instructions>
Derive concrete, actionable items from session state:
- Be specific: "Run `npm test` to verify changes" not "Test the code"
- Include file paths and commands where relevant
- If no clear next steps exist, write:
  "Session ended without explicit next steps. Review Tasks table for incomplete items."
</instructions>
<template>
## Next Steps

1. {concrete_actionable_item}
2. {another_item_if_applicable}
</template>
</section>
</document>
---

## Output Requirements

- **Absolute paths only** for all file references
- **Task names must be action-oriented**: "Add dark mode toggle" not "Dark mode"
- **Status must match evidence**: Don't mark completed if errors unresolved
- **Next steps must be specific**: Commands and file paths, not vague instructions
- **Include both sides of conversation**: User messages AND Claude's thinking/responses
- **Summarize edit content**: Show what code changed, not just "file was edited"
- **Document corrections**: If user corrected Claude, capture what went wrong
- **Omit empty sections** (except Mistakes & Corrections - always include)

## Error Cases

- No messages found: Report "No messages found for session ${CLAUDE_SESSION_ID}"
- Query fails: Note "[Query failed - content unavailable]" and continue with available data
- Ambiguous task status: Mark as "unclear" and list relevant message UUIDs
