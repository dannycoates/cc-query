const std = @import("std");
const Allocator = std.mem.Allocator;
const paths = @import("paths.zig");
const types = @import("types.zig");

/// Count result for sessions and agents
pub const Counts = struct {
    sessions: usize,
    agents: usize,
};

/// Count sessions and agents from a list of file paths
pub fn countSessionsAndAgents(files: []const []const u8, session_filter: ?[]const u8) Counts {
    var sessions: usize = 0;
    var agents: usize = 0;

    for (files) |file| {
        if (!std.mem.endsWith(u8, file, ".jsonl")) continue;

        // Get basename
        const basename = if (std.mem.lastIndexOf(u8, file, "/")) |idx|
            file[idx + 1 ..]
        else
            file;

        const is_subagent_path = std.mem.indexOf(u8, file, "/subagents/") != null;

        if (is_subagent_path and std.mem.startsWith(u8, basename, "agent-")) {
            // Subagent file: {sessionId}/subagents/agent-xxx.jsonl
            if (session_filter) |filter| {
                // Check if this subagent belongs to a filtered session
                const session_dir = if (std.mem.indexOf(u8, file, "/")) |idx|
                    file[0..idx]
                else
                    file;
                if (std.mem.startsWith(u8, session_dir, filter)) {
                    agents += 1;
                }
            } else {
                agents += 1;
            }
        } else if (!std.mem.startsWith(u8, basename, "agent-") and !is_subagent_path) {
            // Session file: {sessionId}.jsonl (top-level, not agent- prefixed)
            if (session_filter) |filter| {
                if (std.mem.startsWith(u8, basename, filter)) {
                    sessions += 1;
                }
            } else {
                sessions += 1;
            }
        }
    }

    return .{ .sessions = sessions, .agents = agents };
}

/// Find all JSONL files in a directory recursively
/// Returns owned list of owned strings
pub fn findJsonlFiles(allocator: Allocator, base_path: []const u8) ![][]const u8 {
    var files: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }

    // Handle relative paths by opening from CWD
    var dir = (if (std.fs.path.isAbsolute(base_path))
        std.fs.openDirAbsolute(base_path, .{ .iterate = true })
    else
        std.fs.cwd().openDir(base_path, .{ .iterate = true })) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) {
            return try files.toOwnedSlice(allocator);
        }
        return err;
    };
    defer dir.close();

    var walker = try dir.walk(allocator);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.path, ".jsonl")) {
            // entry.path is relative to base_path, just copy it
            const path_copy = try allocator.dupe(u8, entry.path);
            try files.append(allocator, path_copy);
        }
    }

    return try files.toOwnedSlice(allocator);
}

/// Get all project directories in ~/.claude/projects
pub fn getAllProjectDirs(allocator: Allocator) ![][]const u8 {
    const base = try paths.getClaudeProjectsBase(allocator);
    defer allocator.free(base);

    var dirs: std.ArrayListUnmanaged([]const u8) = .{};
    errdefer {
        for (dirs.items) |d| allocator.free(d);
        dirs.deinit(allocator);
    }

    var dir = std.fs.openDirAbsolute(base, .{ .iterate = true }) catch |err| {
        if (err == error.FileNotFound or err == error.NotDir) {
            return try dirs.toOwnedSlice(allocator);
        }
        return err;
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .directory) {
            const full_path = try std.fs.path.join(allocator, &.{ base, entry.name });
            try dirs.append(allocator, full_path);
        }
    }

    return try dirs.toOwnedSlice(allocator);
}

/// Options for getSessionFiles
pub const GetSessionFilesOptions = struct {
    data_dir: ?[]const u8 = null,
};

/// Get session info and file pattern for querying
pub fn getSessionFiles(
    allocator: Allocator,
    claude_projects_dir: ?[]const u8,
    session_filter: ?[]const u8,
    options: GetSessionFilesOptions,
) !types.SessionInfo {
    // If dataDir is specified, use it directly
    if (options.data_dir) |data_dir| {
        const files = try findJsonlFiles(allocator, data_dir);
        defer {
            for (files) |f| allocator.free(f);
            allocator.free(files);
        }

        const counts = countSessionsAndAgents(files, session_filter);

        if (counts.sessions == 0 and counts.agents == 0) {
            // Check for any JSONL files
            var jsonl_count: usize = 0;
            for (files) |f| {
                if (std.mem.endsWith(u8, f, ".jsonl")) jsonl_count += 1;
            }

            if (jsonl_count == 0) {
                return .{
                    .session_count = 0,
                    .agent_count = 0,
                    .project_count = 0,
                    .file_pattern = .{ .single = try allocator.dupe(u8, "") },
                };
            }

            // Has JSONL files but don't match normal session naming
            const pattern = try std.fs.path.join(allocator, &.{ data_dir, "**/*.jsonl" });
            return .{
                .session_count = jsonl_count,
                .agent_count = 0,
                .project_count = 1,
                .file_pattern = .{ .single = pattern },
            };
        }

        if (session_filter) |filter| {
            var patterns: std.ArrayListUnmanaged([]const u8) = .{};
            errdefer {
                for (patterns.items) |p| allocator.free(p);
                patterns.deinit(allocator);
            }

            const session_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}*.jsonl", .{ data_dir, filter });
            try patterns.append(allocator, session_pattern);

            if (counts.agents > 0) {
                const agent_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}*/subagents/*.jsonl", .{ data_dir, filter });
                try patterns.append(allocator, agent_pattern);
            }

            return .{
                .session_count = counts.sessions,
                .agent_count = counts.agents,
                .project_count = 1,
                .file_pattern = .{ .multiple = try patterns.toOwnedSlice(allocator) },
            };
        } else {
            const pattern = try std.fs.path.join(allocator, &.{ data_dir, "**/*.jsonl" });
            return .{
                .session_count = counts.sessions,
                .agent_count = counts.agents,
                .project_count = 1,
                .file_pattern = .{ .single = pattern },
            };
        }
    }

    // If no specific project, use all projects
    if (claude_projects_dir == null) {
        const base = try paths.getClaudeProjectsBase(allocator);
        defer allocator.free(base);

        const project_dirs = try getAllProjectDirs(allocator);
        defer {
            for (project_dirs) |d| allocator.free(d);
            allocator.free(project_dirs);
        }

        var total_sessions: usize = 0;
        var total_agents: usize = 0;

        for (project_dirs) |dir| {
            const files = try findJsonlFiles(allocator, dir);
            defer {
                for (files) |f| allocator.free(f);
                allocator.free(files);
            }
            const counts = countSessionsAndAgents(files, session_filter);
            total_sessions += counts.sessions;
            total_agents += counts.agents;
        }

        if (total_sessions == 0) {
            return .{
                .session_count = 0,
                .agent_count = 0,
                .project_count = 0,
                .file_pattern = .{ .single = try allocator.dupe(u8, "") },
            };
        }

        if (session_filter) |filter| {
            var patterns: std.ArrayListUnmanaged([]const u8) = .{};
            errdefer {
                for (patterns.items) |p| allocator.free(p);
                patterns.deinit(allocator);
            }

            const session_pattern = try std.fmt.allocPrint(allocator, "{s}/*/{s}*.jsonl", .{ base, filter });
            try patterns.append(allocator, session_pattern);

            if (total_agents > 0) {
                const agent_pattern = try std.fmt.allocPrint(allocator, "{s}/*/{s}*/subagents/*.jsonl", .{ base, filter });
                try patterns.append(allocator, agent_pattern);
            }

            return .{
                .session_count = total_sessions,
                .agent_count = total_agents,
                .project_count = project_dirs.len,
                .file_pattern = .{ .multiple = try patterns.toOwnedSlice(allocator) },
            };
        } else {
            const pattern = try std.fmt.allocPrint(allocator, "{s}/*/**/*.jsonl", .{base});
            return .{
                .session_count = total_sessions,
                .agent_count = total_agents,
                .project_count = project_dirs.len,
                .file_pattern = .{ .single = pattern },
            };
        }
    }

    // Specific project directory
    const proj_dir = claude_projects_dir.?;
    const files = try findJsonlFiles(allocator, proj_dir);
    defer {
        for (files) |f| allocator.free(f);
        allocator.free(files);
    }

    const counts = countSessionsAndAgents(files, session_filter);

    if (counts.sessions == 0) {
        return .{
            .session_count = 0,
            .agent_count = 0,
            .project_count = 1,
            .file_pattern = .{ .single = try allocator.dupe(u8, "") },
        };
    }

    if (session_filter) |filter| {
        var patterns: std.ArrayListUnmanaged([]const u8) = .{};
        errdefer {
            for (patterns.items) |p| allocator.free(p);
            patterns.deinit(allocator);
        }

        const session_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}*.jsonl", .{ proj_dir, filter });
        try patterns.append(allocator, session_pattern);

        if (counts.agents > 0) {
            const agent_pattern = try std.fmt.allocPrint(allocator, "{s}/{s}*/subagents/*.jsonl", .{ proj_dir, filter });
            try patterns.append(allocator, agent_pattern);
        }

        return .{
            .session_count = counts.sessions,
            .agent_count = counts.agents,
            .project_count = 1,
            .file_pattern = .{ .multiple = try patterns.toOwnedSlice(allocator) },
        };
    } else {
        const pattern = try std.fs.path.join(allocator, &.{ proj_dir, "**/*.jsonl" });
        return .{
            .session_count = counts.sessions,
            .agent_count = counts.agents,
            .project_count = 1,
            .file_pattern = .{ .single = pattern },
        };
    }
}

test "countSessionsAndAgents distinguishes file types" {
    const files = &[_][]const u8{
        "abc123.jsonl",
        "abc123/subagents/agent-xyz.jsonl",
        "def456.jsonl",
    };
    const counts = countSessionsAndAgents(files, null);
    try std.testing.expectEqual(@as(usize, 2), counts.sessions);
    try std.testing.expectEqual(@as(usize, 1), counts.agents);
}

test "countSessionsAndAgents with filter" {
    const files = &[_][]const u8{
        "abc123.jsonl",
        "abc123/subagents/agent-xyz.jsonl",
        "def456.jsonl",
    };
    const counts = countSessionsAndAgents(files, "abc");
    try std.testing.expectEqual(@as(usize, 1), counts.sessions);
    try std.testing.expectEqual(@as(usize, 1), counts.agents);
}

test "countSessionsAndAgents excludes non-jsonl" {
    const files = &[_][]const u8{
        "abc123.jsonl",
        "readme.md",
        "config.json",
    };
    const counts = countSessionsAndAgents(files, null);
    try std.testing.expectEqual(@as(usize, 1), counts.sessions);
    try std.testing.expectEqual(@as(usize, 0), counts.agents);
}
