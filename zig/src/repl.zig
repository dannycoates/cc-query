const std = @import("std");
const Allocator = std.mem.Allocator;
const database = @import("database.zig");
const formatter = @import("formatter.zig");
const types = @import("types.zig");
const paths = @import("paths.zig");

const HISTORY_SIZE: usize = 100;

/// Help text for .help command
const help_text =
    \\
    \\Commands:
    \\  .help, .h      Show this help
    \\  .schema, .s    Show schemas for all views
    \\  .schema <view> Show schema for a specific view
    \\  .quit, .q      Exit
    \\
    \\Views:
    \\  messages            All messages (user, assistant, system)
    \\  user_messages       User messages with user-specific fields
    \\  human_messages      Human-typed messages (excludes tool results)
    \\  assistant_messages  Assistant messages with error, requestId, etc.
    \\  system_messages     System messages with hooks, retry info, etc.
    \\  raw_messages        Raw JSON for each message by uuid
    \\  tool_uses           All tool calls with unnested content blocks
    \\  tool_results        Tool results with duration and error status
    \\  token_usage         Token counts per assistant message
    \\  bash_commands       Bash tool calls with extracted command
    \\  file_operations     Read/Write/Edit/Glob/Grep with file paths
    \\
    \\Example queries:
    \\  -- Count messages by type
    \\  SELECT type, count(*) as cnt FROM messages GROUP BY type ORDER BY cnt DESC;
    \\
    \\  -- Messages by project (when querying all projects)
    \\  SELECT project, count(*) as cnt FROM messages GROUP BY project ORDER BY cnt DESC;
    \\
    \\  -- Recent assistant messages
    \\  SELECT timestamp, message->>'role', message->>'stop_reason'
    \\  FROM assistant_messages ORDER BY timestamp DESC LIMIT 10;
    \\
    \\  -- Tool usage
    \\  SELECT message->>'stop_reason' as reason, count(*) as cnt
    \\  FROM assistant_messages
    \\  GROUP BY reason ORDER BY cnt DESC;
    \\
    \\  -- Sessions summary
    \\  SELECT sessionId, count(*) as msgs, min(timestamp) as started
    \\  FROM messages GROUP BY sessionId ORDER BY started DESC;
    \\
    \\  -- System message subtypes
    \\  SELECT subtype, count(*) FROM system_messages GROUP BY subtype;
    \\
    \\  -- Agent vs main session breakdown
    \\  SELECT isAgent, count(*) FROM messages GROUP BY isAgent;
    \\
    \\JSON field access (DuckDB syntax):
    \\  message->'field'        Access JSON field (returns JSON)
    \\  message->>'field'       Access JSON field as string
    \\  message->'a'->'b'       Nested access
    \\
    \\Useful functions:
    \\  arr[n]                 Get nth element (1-indexed)
    \\  UNNEST(arr)            Expand array into rows
    \\  json_extract_string()  Extract string from JSON
    \\
;

/// All view names
const all_views = [_][]const u8{
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
};

/// REPL state machine
pub const Repl = struct {
    state: types.ReplState,
    buffer: std.ArrayListUnmanaged(u8),
    db: *database.Database,
    allocator: Allocator,
    history: std.ArrayListUnmanaged([]const u8),
    history_path: []const u8,
    session_info: types.SessionInfo,
    session_filter: ?[]const u8,

    pub fn init(allocator: Allocator, db: *database.Database, session_info: types.SessionInfo, session_filter: ?[]const u8) !Repl {
        const history_path = try getHistoryPath(allocator);
        return .{
            .state = .ready,
            .buffer = .{},
            .db = db,
            .allocator = allocator,
            .history = .{},
            .history_path = history_path,
            .session_info = session_info,
            .session_filter = session_filter,
        };
    }

    pub fn deinit(self: *Repl) void {
        self.buffer.deinit(self.allocator);
        for (self.history.items) |item| self.allocator.free(item);
        self.history.deinit(self.allocator);
        self.allocator.free(self.history_path);
    }

    /// Run the REPL (interactive or piped)
    pub fn run(self: *Repl) !void {
        const stdin_file = std.fs.File.stdin();
        const is_tty = stdin_file.isTty();

        if (is_tty) {
            try self.runInteractive();
        } else {
            try self.runPiped();
        }
    }

    /// Run in piped mode (non-interactive)
    fn runPiped(self: *Repl) !void {
        // Set up buffered I/O
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

        const stdin = std.fs.File.stdin();

        // Read all input
        var input: std.ArrayListUnmanaged(u8) = .{};
        defer input.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = stdin.read(&buf) catch break;
            if (n == 0) break;
            try input.appendSlice(self.allocator, buf[0..n]);
        }

        // Split by semicolons and execute
        var is_first_output = true;
        var start: usize = 0;
        var i: usize = 0;

        while (i < input.items.len) : (i += 1) {
            if (input.items[i] == ';') {
                const stmt = std.mem.trim(u8, input.items[start .. i + 1], " \t\n\r");
                if (stmt.len > 0 and !std.mem.eql(u8, stmt, ";")) {
                    if (stmt[0] == '.') {
                        const should_exit = try self.handleDotCommand(stmt, stdout, stderr);
                        if (should_exit) return;
                    } else {
                        if (!is_first_output) {
                            try stdout.print("---\n", .{});
                        }
                        try self.executeQuery(stmt, stdout, true);
                        is_first_output = false;
                    }
                }
                start = i + 1;
            }
        }

        // Handle any remaining statement without semicolon
        const remaining = std.mem.trim(u8, input.items[start..], " \t\n\r");
        if (remaining.len > 0) {
            if (remaining[0] == '.') {
                _ = try self.handleDotCommand(remaining, stdout, stderr);
            } else {
                if (!is_first_output) {
                    try stdout.print("---\n", .{});
                }
                try self.executeQuery(remaining, stdout, true);
            }
        }
    }

    /// Run in interactive mode
    fn runInteractive(self: *Repl) !void {
        // Set up buffered I/O
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

        const stdin = std.fs.File.stdin();

        // Print banner
        if (self.session_info.project_count > 1) {
            try stdout.print("Loaded {d} project(s), {d} session(s), {d} agent file(s)\n", .{
                self.session_info.project_count,
                self.session_info.session_count,
                self.session_info.agent_count,
            });
        } else {
            try stdout.print("Loaded {d} session(s), {d} agent file(s)\n", .{
                self.session_info.session_count,
                self.session_info.agent_count,
            });
        }
        if (self.session_filter) |filter| {
            try stdout.print("Filter: {s}*\n", .{filter});
        }
        try stdout.print("Type \".help\" for usage hints.\n\n", .{});
        try stdout.flush();

        // Load history
        self.loadHistory() catch {};
        defer self.saveHistory() catch {};

        // Main loop
        while (true) {
            // Print prompt
            const prompt = if (self.state == .ready) "cc-query> " else "      -> ";
            try stdout.print("{s}", .{prompt});
            try stdout.flush();

            // Read line
            var line_buf: std.ArrayListUnmanaged(u8) = .{};
            defer line_buf.deinit(self.allocator);

            var single_byte: [1]u8 = undefined;
            var eof = false;
            while (true) {
                const n = stdin.read(&single_byte) catch break;
                if (n == 0) {
                    eof = true;
                    break;
                }
                if (single_byte[0] == '\n') break;
                try line_buf.append(self.allocator, single_byte[0]);
            }

            if (eof and line_buf.items.len == 0) {
                // EOF with no data
                try stdout.print("\nGoodbye!\n", .{});
                break;
            }

            const line = line_buf.items;

            const trimmed = std.mem.trim(u8, line, " \t\r");

            // Add to history
            if (trimmed.len > 0) {
                const saved = try self.allocator.dupe(u8, trimmed);
                try self.history.append(self.allocator, saved);
            }

            // Handle based on state
            if (self.state == .accumulating) {
                try self.buffer.append(self.allocator, '\n');
                try self.buffer.appendSlice(self.allocator, line);

                if (std.mem.endsWith(u8, trimmed, ";")) {
                    try self.executeQuery(self.buffer.items, stdout, false);
                    self.buffer.clearRetainingCapacity();
                    self.state = .ready;
                }
                // Continue accumulating
            } else if (trimmed.len > 0 and trimmed[0] == '.') {
                const should_exit = try self.handleDotCommand(trimmed, stdout, stderr);
                if (should_exit) {
                    try stdout.print("\nGoodbye!\n", .{});
                    break;
                }
            } else if (trimmed.len > 0) {
                if (std.mem.endsWith(u8, trimmed, ";")) {
                    try self.executeQuery(trimmed, stdout, false);
                } else {
                    // Start multi-line mode
                    try self.buffer.appendSlice(self.allocator, line);
                    self.state = .accumulating;
                }
            }
        }
    }

    /// Execute a SQL query and print results
    fn executeQuery(self: *Repl, query: []const u8, stdout: anytype, use_tsv: bool) !void {
        var result = self.db.query(self.allocator, query) catch {
            // Error already printed by database
            return;
        };
        defer result.deinit();

        if (result.columns.len == 0) return;

        const output = if (use_tsv)
            try formatter.formatTsv(self.allocator, &result)
        else
            try formatter.formatTable(self.allocator, &result);
        defer self.allocator.free(output);

        try stdout.print("{s}", .{output});
        try stdout.flush();
    }

    /// Handle dot commands, returns true if should exit
    fn handleDotCommand(self: *Repl, command: []const u8, stdout: anytype, stderr: anytype) !bool {
        // Lowercase for comparison
        var cmd_lower: [64]u8 = undefined;
        const len = @min(command.len, cmd_lower.len);
        for (0..len) |i| {
            cmd_lower[i] = std.ascii.toLower(command[i]);
        }
        const cmd = cmd_lower[0..len];

        if (std.mem.eql(u8, cmd, ".quit") or std.mem.eql(u8, cmd, ".exit") or std.mem.eql(u8, cmd, ".q")) {
            return true;
        }

        if (std.mem.eql(u8, cmd, ".help") or std.mem.eql(u8, cmd, ".h")) {
            try stdout.print("{s}\n", .{help_text});
            try stdout.flush();
            return false;
        }

        if (std.mem.eql(u8, cmd, ".schema") or std.mem.eql(u8, cmd, ".s")) {
            for (all_views) |view| {
                try stdout.print("\n=== {s} ===\n", .{view});
                const describe = try std.fmt.allocPrint(self.allocator, "DESCRIBE {s}", .{view});
                defer self.allocator.free(describe);
                try self.executeQuery(describe, stdout, false);
            }
            return false;
        }

        if (std.mem.startsWith(u8, cmd, ".schema ") or std.mem.startsWith(u8, cmd, ".s ")) {
            // Extract view name from original command (preserve case)
            var iter = std.mem.splitScalar(u8, command, ' ');
            _ = iter.next(); // Skip .schema/.s
            if (iter.next()) |view| {
                const describe = try std.fmt.allocPrint(self.allocator, "DESCRIBE {s}", .{view});
                defer self.allocator.free(describe);
                try self.executeQuery(describe, stdout, false);
            }
            return false;
        }

        try stderr.print("Unknown command: {s}. Type .help for usage.\n", .{command});
        try stderr.flush();
        return false;
    }

    fn loadHistory(self: *Repl) !void {
        const file = std.fs.openFileAbsolute(self.history_path, .{}) catch return;
        defer file.close();

        // Read entire file and split by lines
        var content: std.ArrayListUnmanaged(u8) = .{};
        defer content.deinit(self.allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = file.read(&buf) catch break;
            if (n == 0) break;
            try content.appendSlice(self.allocator, buf[0..n]);
        }

        // Split by newlines
        var iter = std.mem.splitScalar(u8, content.items, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) {
                const saved = try self.allocator.dupe(u8, trimmed);
                try self.history.append(self.allocator, saved);
            }
        }

        // Keep only last HISTORY_SIZE entries
        if (self.history.items.len > HISTORY_SIZE) {
            const to_remove = self.history.items.len - HISTORY_SIZE;
            for (0..to_remove) |i| {
                self.allocator.free(self.history.items[i]);
            }
            std.mem.copyForwards([]const u8, self.history.items[0..HISTORY_SIZE], self.history.items[to_remove..]);
            self.history.shrinkRetainingCapacity(HISTORY_SIZE);
        }
    }

    fn saveHistory(self: *Repl) !void {
        const file = try std.fs.createFileAbsolute(self.history_path, .{});
        defer file.close();

        var writer_buf: [4096]u8 = undefined;
        var file_writer = file.writer(&writer_buf);
        const writer = &file_writer.interface;
        defer writer.flush() catch {};

        // Save last HISTORY_SIZE entries
        const start = if (self.history.items.len > HISTORY_SIZE) self.history.items.len - HISTORY_SIZE else 0;
        for (self.history.items[start..]) |entry| {
            try writer.print("{s}\n", .{entry});
        }
    }
};

fn getHistoryPath(allocator: Allocator) ![]const u8 {
    const home = try paths.getHomeDir();
    return std.fmt.allocPrint(allocator, "{s}/.cc_query_history", .{home});
}
