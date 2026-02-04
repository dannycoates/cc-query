//! Output formatting for query results.

use chrono::{TimeZone, Utc};
use duckdb::types::{TimeUnit, ValueRef};
use std::fmt::{self, Display, Formatter};

/// Wrapper for displaying `ValueRef` without allocation for text.
pub struct DisplayValueRef<'a>(pub &'a ValueRef<'a>);

impl Display for DisplayValueRef<'_> {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        match self.0 {
            ValueRef::Null => write!(f, "NULL"),
            ValueRef::Boolean(b) => write!(f, "{b}"),
            ValueRef::TinyInt(n) => write!(f, "{n}"),
            ValueRef::SmallInt(n) => write!(f, "{n}"),
            ValueRef::Int(n) => write!(f, "{n}"),
            ValueRef::BigInt(n) => write!(f, "{n}"),
            ValueRef::HugeInt(n) => write!(f, "{n}"),
            ValueRef::Float(n) => write!(f, "{n}"),
            ValueRef::Double(n) => write!(f, "{n}"),
            ValueRef::Text(bytes) => {
                let s = std::str::from_utf8(bytes).unwrap_or("<invalid utf8>");
                write!(f, "{s}")
            }
            ValueRef::Timestamp(unit, val) => {
                write!(f, "{}", format_timestamp(*unit, *val))
            }
            ValueRef::Date32(days) => write!(f, "{}", format_date(*days)),
            ValueRef::Blob(bytes) => write!(f, "<{} bytes>", bytes.len()),
            _ => write!(f, "{:?}", self.0),
        }
    }
}

/// Format a timestamp to match Node.js output: "YYYY-MM-DD HH:MM:SS.mmm"
fn format_timestamp(unit: TimeUnit, value: i64) -> String {
    let micros = match unit {
        TimeUnit::Second => value * 1_000_000,
        TimeUnit::Millisecond => value * 1_000,
        TimeUnit::Microsecond => value,
        TimeUnit::Nanosecond => value / 1_000,
    };

    Utc.timestamp_micros(micros)
        .single()
        .map_or_else(|| "INVALID_TIMESTAMP".into(), |dt| dt.format("%Y-%m-%d %H:%M:%S%.3f").to_string())
}

/// Format a date (days since Unix epoch) to "YYYY-MM-DD"
fn format_date(days: i32) -> String {
    // Unix epoch is 1970-01-01, which is day 719,163 in the CE calendar
    chrono::NaiveDate::from_num_days_from_ce_opt(days + 719_163)
        .map_or_else(|| "INVALID_DATE".into(), |d| d.format("%Y-%m-%d").to_string())
}

/// Format results as a table with Unicode box-drawing characters.
///
/// Format matches Node.js exactly:
/// ```text
/// ┌──────────┬───────┐
/// │ column1  │ col2  │
/// ├──────────┼───────┤
/// │ value1   │ val2  │
/// └──────────┴───────┘
/// (N rows)
/// ```
pub fn format_table(columns: &[String], rows: &[Vec<String>]) -> String {
    if rows.is_empty() {
        // Special case: header only with "(0 rows)"
        return format!("{}\n(0 rows)", columns.join(" | "));
    }

    // Calculate column widths (max of header and data)
    let widths: Vec<usize> = columns
        .iter()
        .enumerate()
        .map(|(i, name)| {
            let max_data = rows
                .iter()
                .map(|r| r.get(i).map_or(0, String::len))
                .max()
                .unwrap_or(0);
            name.len().max(max_data)
        })
        .collect();

    let mut lines = Vec::new();

    // Top border: ┌─────┬─────┐
    let top = format!(
        "┌{}┐",
        widths
            .iter()
            .map(|w| "─".repeat(w + 2))
            .collect::<Vec<_>>()
            .join("┬")
    );
    lines.push(top);

    // Header row: │ col1  │ col2  │
    let header = columns
        .iter()
        .enumerate()
        .map(|(i, name)| format!("{:width$}", name, width = widths[i]))
        .collect::<Vec<_>>()
        .join(" │ ");
    lines.push(format!("│ {header} │"));

    // Header separator: ├─────┼─────┤
    let sep = format!(
        "├{}┤",
        widths
            .iter()
            .map(|w| "─".repeat(w + 2))
            .collect::<Vec<_>>()
            .join("┼")
    );
    lines.push(sep);

    // Data rows: │ val1  │ val2  │
    for row in rows {
        let row_str = row
            .iter()
            .enumerate()
            .map(|(i, val)| format!("{:width$}", val, width = widths[i]))
            .collect::<Vec<_>>()
            .join(" │ ");
        lines.push(format!("│ {row_str} │"));
    }

    // Bottom border: └─────┴─────┘
    let bottom = format!(
        "└{}┘",
        widths
            .iter()
            .map(|w| "─".repeat(w + 2))
            .collect::<Vec<_>>()
            .join("┴")
    );
    lines.push(bottom);

    // Row count
    let row_word = if rows.len() == 1 { "row" } else { "rows" };
    lines.push(format!("({} {row_word})", rows.len()));

    lines.join("\n")
}

/// Format results as tab-separated values.
pub fn format_tsv(columns: &[String], rows: &[Vec<String>]) -> String {
    let mut lines = Vec::with_capacity(rows.len() + 1);
    lines.push(columns.join("\t"));
    for row in rows {
        lines.push(row.join("\t"));
    }
    lines.join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_format_tsv() {
        let columns = vec!["a".to_string(), "b".to_string()];
        let rows = vec![
            vec!["1".to_string(), "2".to_string()],
            vec!["3".to_string(), "4".to_string()],
        ];
        assert_eq!(format_tsv(&columns, &rows), "a\tb\n1\t2\n3\t4");
    }

    #[test]
    fn test_format_table_empty() {
        let columns = vec!["col1".to_string(), "col2".to_string()];
        let rows: Vec<Vec<String>> = vec![];
        assert_eq!(format_table(&columns, &rows), "col1 | col2\n(0 rows)");
    }

    #[test]
    fn test_format_table_with_data() {
        let columns = vec!["a".to_string(), "b".to_string()];
        let rows = vec![vec!["1".to_string(), "2".to_string()]];
        let result = format_table(&columns, &rows);
        assert!(result.contains("┌"));
        assert!(result.contains("(1 row)"));
    }
}
