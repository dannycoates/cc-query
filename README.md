# cc-query

SQL REPL for querying Claude Code session data using DuckDB.

## Installation

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
- `tool_calls` - Tool invocations from assistant messages
- `raw_messages` - Unparsed JSONL data

## REPL Commands

- `.help` - Show tables and example queries
- `.schema` - Show table schema
- `.quit` - Exit

## Skill (experimental)

This [skill](https://gist.github.com/dannycoates/b4436fb77c9cfd2763028eee42d1d320) gives claude the ability and slash command `/reflect` to work with claude session history.

For example you can ask questions like:
- Across all projects what bash commands return the most errors?
- Let's analyze the last session and identify how we might improve the claude.md file
- Gimme a summary of what we worked on this past week
- Let's go though our whole session history and identify repeated patterns that we could extract into skills

## License

MIT
