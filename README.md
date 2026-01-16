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

This [example skill](examples/skills/reflect/SKILL.md) gives claude the ability and slash command `/reflect` to work with claude session history.

Why not a plugin? If you copy the skill you can reflect on it to adapt to your own usage.

For example you can ask questions like:
- Across all projects what bash commands return the most errors?
- Let's analyze the last session and identify how we might improve the claude.md file
- Gimme a summary of what we worked on this past week
- Let's go though our whole session history and identify repeated patterns that we could extract into skills
- Let's look at our use of cc-query tool calls to see how we might improve the reflect skill

### Test drive

To test drive this skill do something like this:

1. `npm i -g cc-query`
2. Clone this repo or otherwise fetch the `examples/skills/reflect` dir
3. `mkdir -p ~/.claude/skills && cp -R examples/skills/reflect ~/.claude/skills/`
4. run claude and use `/reflect [whatever you want]`

## License

MIT
