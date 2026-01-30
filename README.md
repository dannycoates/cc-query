# cc-query

SQL REPL for querying Claude Code session data using DuckDB.

## Installation

### As a Claude Code Plugin

1. Add the marketplace:
   ```
   /plugin marketplace add dannycoates/cc-query
   ```

2. Install the plugin:
   ```
   /plugin install cc-query@dannycoates-cc-query
   ```

The plugin automatically runs `npm install` on first session start.

### Manual Installation

For use outside of Claude Code

```bash
npm install -g cc-query
```

Requires Node.js 24+.

## Usage

```bash
# Query all projects
cc-query

# Query a specific project
cc-query ~/code/my-project

# Filter by session ID prefix
cc-query -s abc123 .

# Pipe queries (like psql)
echo "SELECT count(*) FROM messages;" | cc-query .
```

## Available Views

- `messages` - All messages with parsed fields
- `user_messages` - User messages only
- `assistant_messages` - Assistant responses only
- `human_messages` - Human-typed messages (no tool results)
- `tool_uses` - Tool invocations from assistant messages
- `tool_results` - Tool results with duration and error status
- `token_usage` - Token consumption per message
- `bash_commands` - Bash command details
- `file_operations` - File read/write/edit operations
- `raw_messages` - Unparsed JSONL data

## REPL Commands

- `.help` - Show tables and example queries
- `.schema` - Show table schema
- `.quit` - Exit

## Skills

The plugin includes three skills for session analysis:

### `/reflect`

Query and analyze Claude Code session history. Use for:
- Token usage analysis
- Tool patterns across projects
- Finding user corrections/preferences
- Weekly summaries

See [skills/reflect/SKILL.md](skills/reflect/SKILL.md) for query reference.

### `/handoff`

Create detailed handoff documents for work continuation. Produces:
- Task status and progress
- Files modified with change summaries
- Key conversation flow
- Actionable next steps

See [skills/handoff/SKILL.md](skills/handoff/SKILL.md) for output format.

### `/pickup`

Resume work from a handoff document. Reads a handoff file and:
- Presents actionable options from Next Steps and incomplete Tasks
- Retrieves full content for key messages using `get-content.sh`
- Restores working context from Files of Interest

See [skills/pickup/SKILL.md](skills/pickup/SKILL.md) for workflow.

### Example Questions

- Across all projects what bash commands return the most errors?
- Let's analyze the last session and identify how we might improve the CLAUDE.md file
- Give me a summary of what we worked on this past week
- Create a handoff document for this session
- /pickup (resume from most recent handoff)

## License

MIT
