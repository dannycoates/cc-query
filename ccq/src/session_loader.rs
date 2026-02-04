//! Session file discovery and glob pattern generation.
#![allow(clippy::redundant_closure_for_method_calls)] // Result type shadowing
#![allow(clippy::option_if_let_else)] // if let is more readable here

use std::fs;
use std::path::{Path, PathBuf};
use walkdir::WalkDir;
use rayon::prelude::*;

use crate::utils::{claude_projects_base, resolve_project_dir};
use crate::Result;

/// Pattern for `DuckDB` to read JSONL files.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub enum FilePattern {
    /// Single glob pattern
    Single(String),
    /// Multiple glob patterns (for filtered sessions with agents)
    Multiple(Vec<String>),
}

impl std::fmt::Display for FilePattern {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Single(p) => write!(f, "'{p}'"),
            Self::Multiple(ps) => {
                let joined = ps
                    .iter()
                    .map(|p| format!("'{p}'"))
                    .collect::<Vec<_>>()
                    .join(", ");
                write!(f, "[{joined}]")
            }
        }
    }
}

/// Information about discovered session files.
#[derive(Debug, Clone)]
pub struct SessionInfo {
    session_count: usize,
    agent_count: usize,
    project_count: usize,
    file_pattern: FilePattern,
}

impl SessionInfo {
    /// Number of session files found.
    pub const fn session_count(&self) -> usize {
        self.session_count
    }

    /// Number of agent files found.
    pub const fn agent_count(&self) -> usize {
        self.agent_count
    }

    /// Number of projects scanned.
    pub const fn project_count(&self) -> usize {
        self.project_count
    }

    /// File pattern for `DuckDB` to read.
    pub const fn file_pattern(&self) -> &FilePattern {
        &self.file_pattern
    }
}

/// Single-pass file discovery that counts sessions, agents, and total JSONL files.
/// Returns: (sessions, agents, `total_jsonl_files`)
fn walk_and_count(dir: &Path, session_filter: Option<&str>) -> (usize, usize, usize) {
    let mut sessions = 0;
    let mut agents = 0;
    let mut total_jsonl = 0;

    for entry in WalkDir::new(dir).into_iter().filter_map(|e| e.ok()) {
        if !entry.file_type().is_file() {
            continue;
        }
        let path = entry.path();
        let path_str = path.to_string_lossy();
        if !path_str.ends_with(".jsonl") {
            continue;
        }

        total_jsonl += 1;

        let Some(basename) = path.file_name().and_then(|n| n.to_str()) else {
            continue;
        };
        let is_subagent_path = path_str.contains("/subagents/");

        if is_subagent_path && basename.starts_with("agent-") {
            if let Some(filter) = session_filter {
                // Get session dir: /base/session_id/subagents/agent-xxx.jsonl
                let Some(session_dir) = path
                    .parent()
                    .and_then(|p| p.parent())
                    .and_then(|p| p.file_name())
                    .and_then(|n| n.to_str())
                else {
                    continue;
                };
                if session_dir.starts_with(filter) {
                    agents += 1;
                }
            } else {
                agents += 1;
            }
        } else if !basename.starts_with("agent-")
            && !is_subagent_path
            && session_filter.is_none_or(|f| basename.starts_with(f))
        {
            sessions += 1;
        }
    }
    (sessions, agents, total_jsonl)
}

/// Get all project directories under ~/.claude/projects.
fn get_all_project_dirs() -> Vec<PathBuf> {
    let base = claude_projects_base();
    if !base.exists() {
        return vec![];
    }

    fs::read_dir(&base)
        .into_iter()
        .flatten()
        .filter_map(|e| e.ok())
        .filter(|e| e.file_type().is_ok_and(|t| t.is_dir()))
        .map(|e| e.path())
        .collect()
}

/// Discover session files and generate glob patterns for `DuckDB`.
///
/// # Errors
/// Returns error if database operations fail.
#[allow(clippy::unnecessary_wraps)]
pub fn get_session_files(
    project_path: Option<&Path>,
    session_filter: Option<&str>,
    data_dir: Option<&Path>,
) -> Result<SessionInfo> {
    // Mode 1: Direct data directory
    if let Some(dir) = data_dir {
        return get_session_files_data_dir(dir, session_filter);
    }

    // Mode 2: All projects (no project path specified)
    let Some(project_path) = project_path else {
        return get_session_files_all_projects(session_filter);
    };

    // Mode 3: Specific project
    let resolved = resolve_project_dir(&project_path.to_string_lossy());
    get_session_files_project(&resolved.claude_data_dir, session_filter)
}

/// Get session files from a direct data directory.
#[allow(clippy::unnecessary_wraps)]
fn get_session_files_data_dir(dir: &Path, session_filter: Option<&str>) -> Result<SessionInfo> {
    let (sessions, agents, total_jsonl) = walk_and_count(dir, session_filter);

    if sessions == 0 && agents == 0 {
        if total_jsonl == 0 {
            return Ok(SessionInfo {
                session_count: 0,
                agent_count: 0,
                project_count: 0,
                file_pattern: FilePattern::Single(String::new()),
            });
        }

        // Has JSONL files but they don't match normal session naming - still use them
        return Ok(SessionInfo {
            session_count: total_jsonl,
            agent_count: 0,
            project_count: 1,
            file_pattern: FilePattern::Single(dir.join("**/*.jsonl").to_string_lossy().into()),
        });
    }

    let file_pattern = if let Some(filter) = session_filter {
        let mut patterns = vec![dir.join(format!("{filter}*.jsonl")).to_string_lossy().into()];
        if agents > 0 {
            patterns.push(
                dir.join(format!("{filter}*/subagents/*.jsonl"))
                    .to_string_lossy()
                    .into(),
            );
        }
        FilePattern::Multiple(patterns)
    } else {
        FilePattern::Single(dir.join("**/*.jsonl").to_string_lossy().into())
    };

    Ok(SessionInfo {
        session_count: sessions,
        agent_count: agents,
        project_count: 1,
        file_pattern,
    })
}

/// Get session files from all Claude projects.
#[allow(clippy::unnecessary_wraps)]
fn get_session_files_all_projects(session_filter: Option<&str>) -> Result<SessionInfo> {
    let base = claude_projects_base();
    let project_dirs = get_all_project_dirs();

    let (total_sessions, total_agents, _) = project_dirs
        .par_iter()
        .map(|dir| walk_and_count(dir, session_filter))
        .reduce(|| (0, 0, 0), |(s1, a1, j1), (s2, a2, j2)| (s1 + s2, a1 + a2, j1 + j2));

    if total_sessions == 0 {
        return Ok(SessionInfo {
            session_count: 0,
            agent_count: 0,
            project_count: 0,
            file_pattern: FilePattern::Single(String::new()),
        });
    }

    let file_pattern = if let Some(filter) = session_filter {
        let mut patterns = vec![base
            .join("*")
            .join(format!("{filter}*.jsonl"))
            .to_string_lossy()
            .into()];
        if total_agents > 0 {
            patterns.push(
                base.join("*")
                    .join(format!("{filter}*/subagents/*.jsonl"))
                    .to_string_lossy()
                    .into(),
            );
        }
        FilePattern::Multiple(patterns)
    } else {
        FilePattern::Single(base.join("*/**/*.jsonl").to_string_lossy().into())
    };

    Ok(SessionInfo {
        session_count: total_sessions,
        agent_count: total_agents,
        project_count: project_dirs.len(),
        file_pattern,
    })
}

/// Get session files from a specific Claude project directory.
#[allow(clippy::unnecessary_wraps)]
fn get_session_files_project(claude_dir: &Path, session_filter: Option<&str>) -> Result<SessionInfo> {
    if !claude_dir.exists() {
        return Ok(SessionInfo {
            session_count: 0,
            agent_count: 0,
            project_count: 1,
            file_pattern: FilePattern::Single(String::new()),
        });
    }

    let (sessions, agents, _) = walk_and_count(claude_dir, session_filter);

    if sessions == 0 {
        return Ok(SessionInfo {
            session_count: 0,
            agent_count: 0,
            project_count: 1,
            file_pattern: FilePattern::Single(String::new()),
        });
    }

    let file_pattern = if let Some(filter) = session_filter {
        let mut patterns = vec![claude_dir
            .join(format!("{filter}*.jsonl"))
            .to_string_lossy()
            .into()];
        if agents > 0 {
            patterns.push(
                claude_dir
                    .join(format!("{filter}*/subagents/*.jsonl"))
                    .to_string_lossy()
                    .into(),
            );
        }
        FilePattern::Multiple(patterns)
    } else {
        FilePattern::Single(claude_dir.join("**/*.jsonl").to_string_lossy().into())
    };

    Ok(SessionInfo {
        session_count: sessions,
        agent_count: agents,
        project_count: 1,
        file_pattern,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::TempDir;

    #[test]
    fn test_file_pattern_display_single() {
        let pattern = FilePattern::Single("/path/to/*.jsonl".to_string());
        assert_eq!(format!("{pattern}"), "'/path/to/*.jsonl'");
    }

    #[test]
    fn test_file_pattern_display_multiple() {
        let pattern = FilePattern::Multiple(vec![
            "/path/to/a*.jsonl".to_string(),
            "/path/to/b*.jsonl".to_string(),
        ]);
        assert_eq!(
            format!("{pattern}"),
            "['/path/to/a*.jsonl', '/path/to/b*.jsonl']"
        );
    }

    fn create_file(dir: &Path, name: &str) {
        let path = dir.join(name);
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        let mut f = fs::File::create(path).unwrap();
        writeln!(f, "{{}}").unwrap();
    }

    #[test]
    fn test_walk_and_count_basic() {
        let tmp = TempDir::new().unwrap();
        create_file(tmp.path(), "abc123.jsonl");
        create_file(tmp.path(), "def456.jsonl");

        let (sessions, agents, total) = walk_and_count(tmp.path(), None);
        assert_eq!(sessions, 2);
        assert_eq!(agents, 0);
        assert_eq!(total, 2);
    }

    #[test]
    fn test_walk_and_count_with_filter() {
        let tmp = TempDir::new().unwrap();
        create_file(tmp.path(), "abc123.jsonl");
        create_file(tmp.path(), "def456.jsonl");

        let (sessions, agents, total) = walk_and_count(tmp.path(), Some("abc"));
        assert_eq!(sessions, 1);
        assert_eq!(agents, 0);
        assert_eq!(total, 2);
    }

    #[test]
    fn test_walk_and_count_with_subagents() {
        let tmp = TempDir::new().unwrap();
        create_file(tmp.path(), "abc123.jsonl");
        create_file(tmp.path(), "abc123/subagents/agent-001.jsonl");

        let (sessions, agents, total) = walk_and_count(tmp.path(), None);
        assert_eq!(sessions, 1);
        assert_eq!(agents, 1);
        assert_eq!(total, 2);
    }
}
