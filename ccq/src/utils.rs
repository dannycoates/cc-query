//! Path resolution and project slug utilities.

use std::env;
use std::path::{Path, PathBuf};

/// Resolved project paths.
#[derive(Debug, Clone)]
pub struct ResolvedProject {
    /// Path to Claude Code data directory (~/.claude/projects/{slug}/)
    pub claude_data_dir: PathBuf,
}

/// Returns the base Claude projects directory (~/.claude/projects).
///
/// # Panics
/// Panics if no home directory is found.
pub fn claude_projects_base() -> PathBuf {
    dirs::home_dir()
        .expect("No home directory found")
        .join(".claude")
        .join("projects")
}

/// Resolve a project path with tilde expansion and relative path handling.
///
/// - `~/...` expands to home directory
/// - Relative paths resolve against `CLAUDE_PROJECT_DIR` env var or cwd
///
/// # Panics
/// Panics if no home directory is found (when path contains `~`) or if
/// current directory cannot be determined (for relative paths).
fn resolve_project_path(path: &str) -> PathBuf {
    // Handle tilde expansion
    let resolved = path.strip_prefix("~/").map_or_else(
        || {
            if path == "~" {
                dirs::home_dir().expect("No home directory found")
            } else {
                PathBuf::from(path)
            }
        },
        |rest| {
            dirs::home_dir()
                .expect("No home directory found")
                .join(rest)
        },
    );

    // If not absolute, resolve against CLAUDE_PROJECT_DIR or cwd
    if resolved.is_absolute() {
        resolved
    } else {
        let base_dir = env::var("CLAUDE_PROJECT_DIR")
            .map_or_else(|_| env::current_dir().expect("Failed to get current directory"), PathBuf::from);
        base_dir.join(resolved)
    }
}

/// Generate a project slug from a path.
///
/// Replaces `/` and `.` with `-` to create a filesystem-safe identifier.
fn get_project_slug(path: &Path) -> String {
    path.to_string_lossy().replace(['/', '.'], "-")
}

/// Resolve a project path and return the Claude data directory.
pub fn resolve_project_dir(path: &str) -> ResolvedProject {
    let project_path = resolve_project_path(path);
    let slug = get_project_slug(&project_path);
    let claude_data_dir = claude_projects_base().join(slug);
    ResolvedProject { claude_data_dir }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_get_project_slug() {
        let path = Path::new("/home/user/code/my-project");
        assert_eq!(get_project_slug(path), "-home-user-code-my-project");
    }

    #[test]
    fn test_get_project_slug_with_dots() {
        let path = Path::new("/home/user/code/my.project");
        assert_eq!(get_project_slug(path), "-home-user-code-my-project");
    }

    #[test]
    fn test_claude_projects_base() {
        let base = claude_projects_base();
        assert!(base.ends_with(".claude/projects"));
    }
}
