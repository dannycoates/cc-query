const std = @import("std");
const Allocator = std.mem.Allocator;

/// CLI configuration - owns nothing, just references
pub const Config = struct {
    session_filter: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    project_path: ?[]const u8 = null,
    help: bool = false,
};

/// File pattern for DuckDB read_ndjson()
pub const FilePattern = union(enum) {
    single: []const u8,
    multiple: []const []const u8,

    /// Format for SQL - returns owned string
    pub fn format(self: FilePattern, allocator: Allocator) ![]const u8 {
        return switch (self) {
            .single => |p| std.fmt.allocPrint(allocator, "'{s}'", .{p}),
            .multiple => |ps| blk: {
                var buf: std.ArrayListUnmanaged(u8) = .{};
                errdefer buf.deinit(allocator);
                try buf.append(allocator, '[');
                for (ps, 0..) |p, i| {
                    if (i > 0) try buf.appendSlice(allocator, ", ");
                    const formatted = try std.fmt.allocPrint(allocator, "'{s}'", .{p});
                    defer allocator.free(formatted);
                    try buf.appendSlice(allocator, formatted);
                }
                try buf.append(allocator, ']');
                break :blk try buf.toOwnedSlice(allocator);
            },
        };
    }

    pub fn deinit(self: *FilePattern, allocator: Allocator) void {
        switch (self.*) {
            .single => |s| allocator.free(s),
            .multiple => |ps| {
                for (ps) |p| allocator.free(p);
                allocator.free(ps);
            },
        }
    }
};

/// Session discovery results
pub const SessionInfo = struct {
    session_count: usize,
    agent_count: usize,
    project_count: usize,
    file_pattern: FilePattern, // Owned, must call deinit

    pub fn deinit(self: *SessionInfo, allocator: Allocator) void {
        self.file_pattern.deinit(allocator);
    }
};

/// Errors specific to cc-query
pub const Error = error{
    NoSessions,
    NoJsonlFiles,
    NoHomeDir,
    InvalidPath,
    DatabaseError,
};

/// REPL state machine
pub const ReplState = enum {
    ready,
    accumulating, // Multi-line query in progress
};

test "FilePattern.format single" {
    const allocator = std.testing.allocator;
    // Note: Don't call deinit on patterns with string literals - only on allocated strings
    const pattern: FilePattern = .{ .single = "/path/to/file.jsonl" };
    const formatted = try pattern.format(allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("'/path/to/file.jsonl'", formatted);
}

test "FilePattern.format multiple" {
    const allocator = std.testing.allocator;
    const paths = &[_][]const u8{ "/a.jsonl", "/b.jsonl" };
    const formatted = try FilePattern.format(.{ .multiple = paths }, allocator);
    defer allocator.free(formatted);
    try std.testing.expectEqualStrings("['/a.jsonl', '/b.jsonl']", formatted);
}
