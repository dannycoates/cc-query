---
name: pickup
description: Resume work from a handoff document. Use when the user says 'pickup' or wants to start a new session from a previous handoff file.
---

# Pickup from Handoff

Resume work from a handoff document created by the `/handoff` skill.

## Workflow

### 1. Find the handoff file

If the user provided a path, use it. Otherwise, find the most recent handoff file:

```bash
ls -t handoff--*.md 2>/dev/null | head -1
```

If no handoff files found, ask the user for a path.

### 2. Read and present options

Read the handoff file. Extract:
- **Next Steps** section - these become the primary action options
- **Tasks** table - incomplete tasks (status != completed) become secondary options
- **Errors & Blockers** section - if present, resolving these should be an option

Use `AskUserQuestion` to ask what to work on next. Present 2-4 options derived from the handoff:
- Primary options from "Next Steps" (most actionable)
- Option to address blockers if any exist
- Option to continue an incomplete task

### 3. Retrieve context

Based on user selection, read referenced files from the "Files of Interest" table to restore working context. Focus on files with `e` (edit) operations as they represent active work.

If the handoff includes a "Key Conversation Flow" or "Longest Messages" table, use the retrieval script to get full content for important items:

```bash
${CLAUDE_PLUGIN_ROOT}/skills/pickup/scripts/get-content.sh <id> [type] [session_id]
# Tool calls (toolu_*): type not needed, session_id is arg 2
# Messages: type required (U=human, T=thinking, A=assistant), session_id is arg 3
```

The session ID is in the handoff header.

### 4. Begin work

Summarize the selected task and relevant context, then proceed with implementation.
