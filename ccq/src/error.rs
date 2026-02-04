//! Error types for ccq.

use std::path::PathBuf;

/// Custom error type for ccq operations.
#[derive(Debug, thiserror::Error)]
#[non_exhaustive]
pub enum Error {
    /// Must match: "Error: No JSONL files found in {path}"
    #[error("No JSONL files found in {}", path.display())]
    NoSessions { path: PathBuf },

    #[error("Database error: {0}")]
    Database(#[from] duckdb::Error),

    #[error("IO error: {0}")]
    Io(#[from] std::io::Error),

    #[error("Readline error: {0}")]
    Readline(#[from] rustyline::error::ReadlineError),
}

/// Result type alias for ccq operations.
pub type Result<T> = std::result::Result<T, Error>;
