const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("database.zig");

/// Format result set as TSV (tab-separated values)
pub fn formatTsv(allocator: Allocator, result: *const database.ResultSet) ![]const u8 {
    if (result.columns.len == 0) return try allocator.dupe(u8, "");

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    // Header row
    for (result.columns, 0..) |col, i| {
        if (i > 0) try output.append(allocator, '\t');
        try output.appendSlice(allocator, col);
    }
    try output.append(allocator, '\n');

    // Data rows
    for (result.rows) |row| {
        for (row, 0..) |cell, i| {
            if (i > 0) try output.append(allocator, '\t');
            try output.appendSlice(allocator, cell);
        }
        try output.append(allocator, '\n');
    }

    return try output.toOwnedSlice(allocator);
}

/// Format result set as a table with box-drawing characters
pub fn formatTable(allocator: Allocator, result: *const database.ResultSet) ![]const u8 {
    if (result.columns.len == 0) return try allocator.dupe(u8, "");

    var output: std.ArrayListUnmanaged(u8) = .{};
    errdefer output.deinit(allocator);

    const col_count = result.columns.len;

    // Calculate column widths
    var widths = try allocator.alloc(usize, col_count);
    defer allocator.free(widths);

    for (result.columns, 0..) |col, i| {
        widths[i] = col.len;
    }

    for (result.rows) |row| {
        for (row, 0..) |cell, i| {
            if (cell.len > widths[i]) widths[i] = cell.len;
        }
    }

    // Top border: ┌──┬──┐
    try output.appendSlice(allocator, "┌");
    for (widths, 0..) |w, i| {
        if (i > 0) try output.appendSlice(allocator, "┬");
        try appendRepeated(&output, allocator, "─", w + 2);
    }
    try output.appendSlice(allocator, "┐\n");

    // Header row: │ col1 │ col2 │
    try output.appendSlice(allocator, "│ ");
    for (result.columns, 0..) |col, i| {
        if (i > 0) try output.appendSlice(allocator, " │ ");
        try output.appendSlice(allocator, col);
        try appendSpaces(&output, allocator, widths[i] - col.len);
    }
    try output.appendSlice(allocator, " │\n");

    // Header separator: ├──┼──┤
    try output.appendSlice(allocator, "├");
    for (widths, 0..) |w, i| {
        if (i > 0) try output.appendSlice(allocator, "┼");
        try appendRepeated(&output, allocator, "─", w + 2);
    }
    try output.appendSlice(allocator, "┤\n");

    // Data rows
    for (result.rows) |row| {
        try output.appendSlice(allocator, "│ ");
        for (row, 0..) |cell, i| {
            if (i > 0) try output.appendSlice(allocator, " │ ");
            try output.appendSlice(allocator, cell);
            try appendSpaces(&output, allocator, widths[i] - cell.len);
        }
        try output.appendSlice(allocator, " │\n");
    }

    // Bottom border: └──┴──┘
    try output.appendSlice(allocator, "└");
    for (widths, 0..) |w, i| {
        if (i > 0) try output.appendSlice(allocator, "┴");
        try appendRepeated(&output, allocator, "─", w + 2);
    }
    try output.appendSlice(allocator, "┘\n");

    // Row count
    const row_word = if (result.rows.len == 1) "row" else "rows";
    const footer = try std.fmt.allocPrint(allocator, "({d} {s})\n", .{ result.rows.len, row_word });
    defer allocator.free(footer);
    try output.appendSlice(allocator, footer);

    return try output.toOwnedSlice(allocator);
}

fn appendSpaces(output: *std.ArrayListUnmanaged(u8), allocator: Allocator, count: usize) !void {
    for (0..count) |_| {
        try output.append(allocator, ' ');
    }
}

fn appendRepeated(output: *std.ArrayListUnmanaged(u8), allocator: Allocator, s: []const u8, count: usize) !void {
    for (0..count) |_| {
        try output.appendSlice(allocator, s);
    }
}

test "formatTsv basic" {
    const allocator = std.testing.allocator;

    // Create a fake ResultSet
    var columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "id");
    columns[1] = try allocator.dupe(u8, "name");

    var rows = try allocator.alloc([][]const u8, 2);

    rows[0] = try allocator.alloc([]const u8, 2);
    rows[0][0] = try allocator.dupe(u8, "1");
    rows[0][1] = try allocator.dupe(u8, "hello");

    rows[1] = try allocator.alloc([]const u8, 2);
    rows[1][0] = try allocator.dupe(u8, "2");
    rows[1][1] = try allocator.dupe(u8, "world");

    var result = database.ResultSet{
        .columns = columns,
        .rows = rows,
        .allocator = allocator,
    };
    defer result.deinit();

    const tsv = try formatTsv(allocator, &result);
    defer allocator.free(tsv);

    try std.testing.expectEqualStrings("id\tname\n1\thello\n2\tworld\n", tsv);
}

test "formatTable basic" {
    const allocator = std.testing.allocator;

    var columns = try allocator.alloc([]const u8, 2);
    columns[0] = try allocator.dupe(u8, "id");
    columns[1] = try allocator.dupe(u8, "name");

    var rows = try allocator.alloc([][]const u8, 1);
    rows[0] = try allocator.alloc([]const u8, 2);
    rows[0][0] = try allocator.dupe(u8, "1");
    rows[0][1] = try allocator.dupe(u8, "hello");

    var result = database.ResultSet{
        .columns = columns,
        .rows = rows,
        .allocator = allocator,
    };
    defer result.deinit();

    const table = try formatTable(allocator, &result);
    defer allocator.free(table);

    // Check it has box-drawing characters and row count
    try std.testing.expect(std.mem.indexOf(u8, table, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "│") != null);
    try std.testing.expect(std.mem.indexOf(u8, table, "(1 row)") != null);
}
