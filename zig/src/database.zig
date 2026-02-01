const std = @import("std");
const Allocator = std.mem.Allocator;
const zuckdb = @import("zuckdb");

/// Query result set with column names and row data
pub const ResultSet = struct {
    columns: [][]const u8,
    rows: [][][]const u8,
    allocator: Allocator,

    pub fn deinit(self: *ResultSet) void {
        for (self.rows) |row| {
            for (row) |cell| self.allocator.free(cell);
            self.allocator.free(row);
        }
        self.allocator.free(self.rows);
        for (self.columns) |col| self.allocator.free(col);
        self.allocator.free(self.columns);
    }
};

/// DuckDB database wrapper
pub const Database = struct {
    db: zuckdb.DB,
    conn: zuckdb.Conn,
    allocator: Allocator,

    pub fn init(allocator: Allocator) !Database {
        var db = try zuckdb.DB.init(allocator, ":memory:", .{});
        errdefer db.deinit();

        const conn = try db.conn();
        return .{
            .db = db,
            .conn = conn,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Database) void {
        self.conn.deinit();
        self.db.deinit();
    }

    /// Execute SQL without returning results
    pub fn exec(self: *Database, sql: []const u8) !void {
        _ = self.conn.exec(sql, .{}) catch |err| {
            self.printError();
            return err;
        };
    }

    /// Execute SQL and return results
    pub fn query(self: *Database, allocator: Allocator, sql: []const u8) !ResultSet {
        var rows = self.conn.query(sql, .{}) catch |err| {
            self.printError();
            return err;
        };
        defer rows.deinit();

        // Get column names
        const col_count = rows.column_count;
        var columns = try allocator.alloc([]const u8, col_count);
        errdefer {
            for (columns) |c| allocator.free(c);
            allocator.free(columns);
        }
        for (0..col_count) |i| {
            columns[i] = try allocator.dupe(u8, std.mem.span(rows.columnName(i)));
        }

        // Collect all rows
        var result_rows: std.ArrayListUnmanaged([][]const u8) = .{};
        errdefer {
            for (result_rows.items) |row| {
                for (row) |cell| allocator.free(cell);
                allocator.free(row);
            }
            result_rows.deinit(allocator);
        }

        while (true) {
            const row = try rows.next();
            if (row) |r| {
                const cells = try formatRow(allocator, r, &rows);
                try result_rows.append(allocator, cells);
            } else {
                break;
            }
        }

        return .{
            .columns = columns,
            .rows = try result_rows.toOwnedSlice(allocator),
            .allocator = allocator,
        };
    }

    fn printError(self: *Database) void {
        if (self.conn.err) |error_msg| {
            std.debug.print("Error: {s}\n", .{error_msg});
        }
    }
};

/// Format a row's values as strings
fn formatRow(allocator: Allocator, row: zuckdb.Row, rows: *zuckdb.Rows) ![][]const u8 {
    const col_count = rows.column_count;
    var cells = try allocator.alloc([]const u8, col_count);
    errdefer {
        for (cells, 0..) |_, i| {
            if (cells[i].len > 0) allocator.free(cells[i]);
        }
        allocator.free(cells);
    }

    for (0..col_count) |i| {
        cells[i] = try formatValue(allocator, row, rows, i);
    }
    return cells;
}

/// Format a single value as a string
fn formatValue(allocator: Allocator, row: zuckdb.Row, rows: *zuckdb.Rows, col_idx: usize) ![]const u8 {
    const col_type = rows.columnType(col_idx);

    return switch (col_type) {
        .varchar => blk: {
            const val = row.get(?[]const u8, col_idx);
            if (val) |v| {
                break :blk try allocator.dupe(u8, v);
            } else {
                break :blk try allocator.dupe(u8, "NULL");
            }
        },
        .bigint => blk: {
            const val = row.get(?i64, col_idx);
            if (val) |v| {
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{v});
            } else {
                break :blk try allocator.dupe(u8, "NULL");
            }
        },
        .hugeint => blk: {
            const val = row.get(?i128, col_idx);
            if (val) |v| {
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{v});
            } else {
                break :blk try allocator.dupe(u8, "NULL");
            }
        },
        .uhugeint => blk: {
            const val = row.get(?u128, col_idx);
            if (val) |v| {
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{v});
            } else {
                break :blk try allocator.dupe(u8, "NULL");
            }
        },
        .integer => blk: {
            const val = row.get(?i32, col_idx);
            if (val) |v| {
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{v});
            } else {
                break :blk try allocator.dupe(u8, "NULL");
            }
        },
        .double => blk: {
            const val = row.get(?f64, col_idx);
            if (val) |v| {
                break :blk try std.fmt.allocPrint(allocator, "{d}", .{v});
            } else {
                break :blk try allocator.dupe(u8, "NULL");
            }
        },
        .boolean => blk: {
            const val = row.get(?bool, col_idx);
            if (val) |v| {
                break :blk try allocator.dupe(u8, if (v) "true" else "false");
            } else {
                break :blk try allocator.dupe(u8, "NULL");
            }
        },
        .timestamp => blk: {
            const val = row.get(?i64, col_idx);
            if (val) |micros| {
                break :blk try formatTimestamp(allocator, micros);
            } else {
                break :blk try allocator.dupe(u8, "NULL");
            }
        },
        .uuid => blk: {
            const val = row.get(?zuckdb.UUID, col_idx);
            if (val) |uuid_bytes| {
                break :blk try allocator.dupe(u8, &uuid_bytes);
            } else {
                break :blk try allocator.dupe(u8, "NULL");
            }
        },
        else => try allocator.dupe(u8, "?"),
    };
}

/// Format timestamp as "YYYY-MM-DD HH:MM:SS.mmm"
pub fn formatTimestamp(allocator: Allocator, micros: i64) ![]const u8 {
    const ms = @divFloor(micros, 1000);
    const epoch_seconds: u64 = @intCast(@divFloor(ms, 1000));
    const remaining_ms: u64 = @intCast(@mod(@abs(ms), 1000));

    const epoch = std.time.epoch.EpochSeconds{ .secs = epoch_seconds };
    const day_seconds = epoch.getDaySeconds();
    const year_day = epoch.getEpochDay().calculateYearDay();

    const hour = day_seconds.getHoursIntoDay();
    const minute = day_seconds.getMinutesIntoHour();
    const second = day_seconds.getSecondsIntoMinute();

    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        hour,
        minute,
        second,
        remaining_ms,
    });
}

test "formatTimestamp matches Node output" {
    const allocator = std.testing.allocator;
    const micros: i64 = 1736039614310000; // 2025-01-05 01:13:34.310
    const result = try formatTimestamp(allocator, micros);
    defer allocator.free(result);
    try std.testing.expectEqualStrings("2025-01-05 01:13:34.310", result);
}

test "Database init and query" {
    const allocator = std.testing.allocator;
    var db = try Database.init(allocator);
    defer db.deinit();

    try db.exec("CREATE TABLE test (id INTEGER, name VARCHAR)");
    try db.exec("INSERT INTO test VALUES (1, 'hello'), (2, 'world')");

    var result = try db.query(allocator, "SELECT * FROM test ORDER BY id");
    defer result.deinit();

    try std.testing.expectEqual(@as(usize, 2), result.columns.len);
    try std.testing.expectEqualStrings("id", result.columns[0]);
    try std.testing.expectEqualStrings("name", result.columns[1]);

    try std.testing.expectEqual(@as(usize, 2), result.rows.len);
    try std.testing.expectEqualStrings("1", result.rows[0][0]);
    try std.testing.expectEqualStrings("hello", result.rows[0][1]);
}
