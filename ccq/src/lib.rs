//! cc-query library for querying Claude Code session data with `DuckDB`.

pub mod error;
pub mod formatter;
pub mod query_session;
pub mod repl;
pub mod session_loader;
pub mod utils;

pub use error::{Error, Result};
pub use query_session::QuerySession;
pub use session_loader::SessionInfo;
