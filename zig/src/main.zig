const std = @import("std");
const zuckdb = @import("zuckdb");

// Import modules for compilation and testing
pub const types = @import("types.zig");
pub const paths = @import("paths.zig");
pub const views = @import("views.zig");
pub const session_loader = @import("session_loader.zig");
pub const database = @import("database.zig");
pub const formatter = @import("formatter.zig");
pub const repl = @import("repl.zig");

const help_text =
    \\Usage: cc-query [options] [project-path]
    \\
    \\Interactive SQL REPL for querying Claude Code session data.
    \\Uses DuckDB to query JSONL session files.
    \\
    \\Arguments:
    \\  project-path            Path to project (omit for all projects)
    \\
    \\Options:
    \\  --session, -s <prefix>  Filter to sessions matching the ID prefix
    \\  --data-dir, -d <dir>    Use directory directly as JSONL data source
    \\  --help, -h              Show this help message
    \\
    \\Examples:
    \\  cc-query                          # All projects
    \\  cc-query ~/code/my-project        # Specific project
    \\  cc-query -s abc123 .              # Filter by session prefix
    \\
    \\Piped input (like psql):
    \\  echo "SELECT count(*) FROM messages;" | cc-query .
    \\  cat queries.sql | cc-query .
    \\
    \\REPL Commands:
    \\  .help      Show available tables and example queries
    \\  .schema    Show table schema
    \\  .quit      Exit the REPL
    \\
;

/// CLI configuration
const Config = struct {
    session_filter: ?[]const u8 = null,
    data_dir: ?[]const u8 = null,
    project_path: ?[]const u8 = null,
    help: bool = false,
};

fn parseArgs(args: []const []const u8) Config {
    var config = Config{};
    var i: usize = 1; // Skip program name

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            config.help = true;
        } else if (std.mem.eql(u8, arg, "--session") or std.mem.eql(u8, arg, "-s")) {
            if (i + 1 < args.len) {
                i += 1;
                config.session_filter = args[i];
            }
        } else if (std.mem.eql(u8, arg, "--data-dir") or std.mem.eql(u8, arg, "-d")) {
            if (i + 1 < args.len) {
                i += 1;
                config.data_dir = args[i];
            }
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            // Positional argument - project path
            config.project_path = arg;
        }
    }

    return config;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Buffered stdout/stderr for Zig 0.15
    const stdout_file = std.fs.File.stdout();
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = stdout_file.writer(&stdout_buf);
    const stdout = &stdout_writer.interface;
    defer stdout.flush() catch {};

    const stderr_file = std.fs.File.stderr();
    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = stderr_file.writer(&stderr_buf);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // Parse command line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    const config = parseArgs(args);

    if (config.help) {
        try stdout.print("{s}\n", .{help_text});
        return;
    }

    // Resolve project path
    var claude_projects_dir: ?[]const u8 = null;
    var project_path_resolved: ?[]const u8 = null;
    defer if (project_path_resolved) |p| allocator.free(p);
    defer if (claude_projects_dir) |p| allocator.free(p);

    if (config.project_path) |proj_path| {
        const result = paths.resolveProjectDir(allocator, proj_path) catch |err| {
            try stderr.print("Error: Invalid path: {s}\n", .{@errorName(err)});
            std.process.exit(1);
        };
        claude_projects_dir = result.claude_projects_dir;
        project_path_resolved = result.project_path;
    }

    // Resolve data_dir to absolute path if provided
    var data_dir_resolved: ?[]const u8 = null;
    defer if (data_dir_resolved) |p| allocator.free(p);

    if (config.data_dir) |data_dir| {
        if (!std.fs.path.isAbsolute(data_dir)) {
            var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.fs.cwd().realpath(".", &cwd_buf) catch {
                try stderr.print("Error: Failed to get current directory\n", .{});
                std.process.exit(1);
            };
            data_dir_resolved = try std.fs.path.join(allocator, &.{ cwd, data_dir });
        } else {
            data_dir_resolved = try allocator.dupe(u8, data_dir);
        }
    }

    // Get session files
    var session_info = session_loader.getSessionFiles(
        allocator,
        claude_projects_dir,
        config.session_filter,
        .{ .data_dir = data_dir_resolved },
    ) catch |err| {
        try stderr.print("Error: Failed to find session files: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer session_info.deinit(allocator);

    // Check for no sessions
    if (session_info.session_count == 0 and session_info.agent_count == 0) {
        if (config.data_dir) |data_dir| {
            try stderr.print("Error: No JSONL files found in {s}\n", .{data_dir});
        } else if (project_path_resolved) |proj_path| {
            try stderr.print("Error: No Claude Code data found for {s}\n", .{proj_path});
            if (claude_projects_dir) |cpd| {
                try stderr.print("Expected: {s}\n", .{cpd});
            }
        } else {
            try stderr.print("Error: No Claude Code sessions found\n", .{});
        }
        stderr.flush() catch {};
        std.process.exit(1);
    }

    // Initialize database
    var db = database.Database.init(allocator) catch |err| {
        try stderr.print("Error: Failed to initialize database: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer db.deinit();

    // Format file pattern for SQL
    const file_pattern_sql = session_info.file_pattern.format(allocator) catch |err| {
        try stderr.print("Error: Failed to format file pattern: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(file_pattern_sql);

    // Create views
    const create_views_sql = views.getCreateViewsSql(allocator, file_pattern_sql) catch |err| {
        try stderr.print("Error: Failed to generate views SQL: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer allocator.free(create_views_sql);

    db.exec(create_views_sql) catch |err| {
        try stderr.print("Error: Failed to create views: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    // Run REPL
    var r = repl.Repl.init(allocator, &db, session_info, config.session_filter) catch |err| {
        try stderr.print("Error: Failed to initialize REPL: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer r.deinit();

    r.run() catch |err| {
        try stderr.print("Error: REPL error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

// Run tests from all modules
test {
    _ = types;
    _ = paths;
    _ = views;
    _ = session_loader;
    _ = database;
    _ = formatter;
    _ = repl;
}
