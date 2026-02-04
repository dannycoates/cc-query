//! Interactive REPL and piped query execution.

use std::io::{self, BufWriter, Read, Write};

use rustyline::error::ReadlineError;
use rustyline::DefaultEditor;

use crate::{QuerySession, Result};

const HISTORY_FILE: &str = ".cc_query_history";
const PROMPT: &str = "ccq> ";
const CONTINUATION_PROMPT: &str = "  -> ";

/// All available views
const VIEWS: &[&str] = &[
    "messages",
    "user_messages",
    "human_messages",
    "assistant_messages",
    "system_messages",
    "raw_messages",
    "tool_uses",
    "tool_results",
    "token_usage",
    "bash_commands",
    "file_operations",
];

/// Dot command result.
enum DotCommandResult {
    /// Continue REPL
    Continue,
    /// Exit REPL
    Exit,
}

/// Start an interactive REPL session.
///
/// # Errors
/// Returns error if REPL initialization or I/O fails.
pub fn start_interactive(session: &QuerySession) -> Result<()> {
    let history_path = dirs::home_dir()
        .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "No home directory"))?
        .join(HISTORY_FILE);

    let mut editor = DefaultEditor::new()?;
    let _ = editor.load_history(&history_path); // Ignore missing file

    print_banner(session);

    let result = run_repl_loop(&mut editor, session);

    // Always try to save history, ignore errors
    let _ = editor.save_history(&history_path);

    result
}

fn print_banner(session: &QuerySession) {
    let info = session.info();
    if info.project_count() > 1 {
        println!(
            "Loaded {} project(s), {} session(s), {} agent file(s)",
            info.project_count(),
            info.session_count(),
            info.agent_count()
        );
    } else {
        println!(
            "Loaded {} session(s), {} agent file(s)",
            info.session_count(),
            info.agent_count()
        );
    }
    println!("Type \".help\" for usage hints.\n");
}

fn run_repl_loop(editor: &mut DefaultEditor, session: &QuerySession) -> Result<()> {
    let mut multiline_buffer = String::new();

    loop {
        let prompt = if multiline_buffer.is_empty() {
            PROMPT
        } else {
            CONTINUATION_PROMPT
        };

        match editor.readline(prompt) {
            Ok(line) => {
                let trimmed = line.trim();

                // Handle multi-line mode
                if !multiline_buffer.is_empty() {
                    multiline_buffer.push('\n');
                    multiline_buffer.push_str(&line);

                    // Check if query ends with semicolon
                    if trimmed.ends_with(';') {
                        let _ = editor.add_history_entry(&multiline_buffer);
                        execute_query(session, &multiline_buffer);
                        multiline_buffer.clear();
                    }
                    continue;
                }

                // Handle dot commands
                if trimmed.starts_with('.') {
                    let _ = editor.add_history_entry(trimmed);
                    if matches!(handle_dot_command(trimmed, session), DotCommandResult::Exit) {
                        break;
                    }
                }
                // Handle SQL queries
                else if !trimmed.is_empty() {
                    if trimmed.ends_with(';') {
                        let _ = editor.add_history_entry(trimmed);
                        execute_query(session, trimmed);
                    } else {
                        // Start multi-line mode
                        multiline_buffer = line;
                    }
                }
            }
            Err(ReadlineError::Interrupted | ReadlineError::Eof) => break,
            Err(e) => return Err(e.into()),
        }
    }

    println!("Goodbye!");
    Ok(())
}

fn execute_query(session: &QuerySession, sql: &str) {
    match session.query(sql) {
        Ok(result) => {
            println!("{}", result.to_table());
        }
        Err(e) => {
            eprintln!("Error: {e}");
        }
    }
}

fn handle_dot_command(command: &str, session: &QuerySession) -> DotCommandResult {
    let cmd = command.to_lowercase();

    if cmd == ".quit" || cmd == ".exit" || cmd == ".q" {
        return DotCommandResult::Exit;
    }

    if cmd == ".help" || cmd == ".h" {
        print_help();
        return DotCommandResult::Continue;
    }

    if cmd == ".schema" || cmd == ".s" {
        for view in VIEWS {
            println!("\n=== {view} ===");
            execute_query(session, &format!("DESCRIBE {view}"));
        }
        return DotCommandResult::Continue;
    }

    if cmd.starts_with(".schema ") || cmd.starts_with(".s ") {
        let view = command.split_whitespace().nth(1).unwrap_or("");
        execute_query(session, &format!("DESCRIBE {view}"));
        return DotCommandResult::Continue;
    }

    println!("Unknown command: {command}. Type .help for usage.");
    DotCommandResult::Continue
}

fn print_help() {
    println!(
        r"
Commands:
  .help, .h      Show this help
  .schema, .s    Show schemas for all views
  .schema <view> Show schema for a specific view
  .quit, .q      Exit

Views:
  messages            All messages (user, assistant, system)
  user_messages       User messages with user-specific fields
  human_messages      Human-typed messages (excludes tool results)
  assistant_messages  Assistant messages with error, requestId, etc.
  system_messages     System messages with hooks, retry info, etc.
  raw_messages        Raw JSON for each message by uuid
  tool_uses           All tool calls with unnested content blocks
  tool_results        Tool results with duration and error status
  token_usage         Token counts per assistant message
  bash_commands       Bash tool calls with extracted command
  file_operations     Read/Write/Edit/Glob/Grep with file paths

Example queries:
  -- Count messages by type
  SELECT type, count(*) as cnt FROM messages GROUP BY type ORDER BY cnt DESC;

  -- Messages by project (when querying all projects)
  SELECT project, count(*) as cnt FROM messages GROUP BY project ORDER BY cnt DESC;

  -- Recent assistant messages
  SELECT timestamp, message->>'role', message->>'stop_reason'
  FROM assistant_messages ORDER BY timestamp DESC LIMIT 10;

  -- Tool usage
  SELECT message->>'stop_reason' as reason, count(*) as cnt
  FROM assistant_messages
  GROUP BY reason ORDER BY cnt DESC;

  -- Sessions summary
  SELECT sessionId, count(*) as msgs, min(timestamp) as started
  FROM messages GROUP BY sessionId ORDER BY started DESC;

  -- System message subtypes
  SELECT subtype, count(*) FROM system_messages GROUP BY subtype;

  -- Agent vs main session breakdown
  SELECT isAgent, count(*) FROM messages GROUP BY isAgent;

JSON field access (DuckDB syntax):
  message->'field'        Access JSON field (returns JSON)
  message->>'field'       Access JSON field as string
  message->'a'->'b'       Nested access

Useful functions:
  arr[n]                 Get nth element (1-indexed)
  UNNEST(arr)            Expand array into rows
  json_extract_string()  Extract string from JSON
"
    );
}

/// Execute piped queries from stdin.
///
/// # Errors
/// Returns error if I/O or query execution fails.
pub fn run_piped(session: &QuerySession) -> Result<()> {
    let mut input = String::new();
    io::stdin().read_to_string(&mut input)?;

    let stdout = io::stdout();
    let mut writer = BufWriter::new(stdout.lock());

    // Split by semicolons, keeping the semicolon with each statement
    let statements: Vec<&str> = input
        .split(';')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect();

    let mut is_first = true;

    for stmt in statements {
        if stmt.starts_with('.') {
            writer.flush()?; // Flush before dot command output
            if matches!(handle_dot_command_piped(stmt, session), DotCommandResult::Exit) {
                break;
            }
        } else {
            if !is_first {
                writeln!(writer, "---")?;
            }
            match session.query_tsv_streaming(stmt, &mut writer) {
                Ok(_) => {
                    is_first = false;
                }
                Err(e) => {
                    writer.flush()?;
                    eprintln!("Error: {e}");
                }
            }
        }
    }
    writer.flush()?;

    Ok(())
}

fn handle_dot_command_piped(command: &str, session: &QuerySession) -> DotCommandResult {
    let cmd = command.to_lowercase();

    if cmd == ".quit" || cmd == ".exit" || cmd == ".q" {
        return DotCommandResult::Exit;
    }

    if cmd == ".help" || cmd == ".h" {
        print_help();
        return DotCommandResult::Continue;
    }

    if cmd == ".schema" || cmd == ".s" {
        for view in VIEWS {
            println!("\n=== {view} ===");
            if let Ok(result) = session.query(&format!("DESCRIBE {view}")) {
                println!("{}", result.to_table());
            }
        }
        return DotCommandResult::Continue;
    }

    if cmd.starts_with(".schema ") || cmd.starts_with(".s ") {
        let view = command.split_whitespace().nth(1).unwrap_or("");
        if let Ok(result) = session.query(&format!("DESCRIBE {view}")) {
            println!("{}", result.to_table());
        }
        return DotCommandResult::Continue;
    }

    println!("Unknown command: {command}. Type .help for usage.");
    DotCommandResult::Continue
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_views_list() {
        assert!(VIEWS.contains(&"messages"));
        assert!(VIEWS.contains(&"tool_uses"));
        assert_eq!(VIEWS.len(), 11);
    }
}
