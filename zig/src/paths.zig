const std = @import("std");
const Allocator = std.mem.Allocator;

/// Get the home directory from HOME environment variable
pub fn getHomeDir() ![]const u8 {
    return std.posix.getenv("HOME") orelse return error.NoHomeDir;
}

/// Expand ~ to home directory, resolve relative paths
/// Returns owned string that must be freed by caller
pub fn resolveProjectPath(allocator: Allocator, project_path: []const u8) ![]const u8 {
    // Expand ~
    var resolved: []const u8 = undefined;
    var owns_resolved = false;

    if (std.mem.startsWith(u8, project_path, "~/")) {
        const home = try getHomeDir();
        resolved = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home, project_path[1..] });
        owns_resolved = true;
    } else if (std.mem.eql(u8, project_path, "~")) {
        resolved = try allocator.dupe(u8, try getHomeDir());
        owns_resolved = true;
    } else {
        resolved = project_path;
    }
    errdefer if (owns_resolved) allocator.free(resolved);

    // Resolve relative paths
    if (!std.fs.path.isAbsolute(resolved)) {
        const base_dir = std.posix.getenv("CLAUDE_PROJECT_DIR") orelse blk: {
            var buf: [std.fs.max_path_bytes]u8 = undefined;
            const cwd = std.fs.cwd().realpath(".", &buf) catch return error.InvalidPath;
            break :blk cwd;
        };

        const joined = try std.fs.path.join(allocator, &.{ base_dir, resolved });
        if (owns_resolved) allocator.free(resolved);
        return joined;
    }

    // If we already own resolved, return it; otherwise dupe it
    if (owns_resolved) {
        return resolved;
    } else {
        return try allocator.dupe(u8, resolved);
    }
}

/// Generate project slug: /path/to/project → -path-to-project
/// Returns owned string that must be freed by caller
pub fn getProjectSlug(allocator: Allocator, project_path: []const u8) ![]const u8 {
    const resolved = try resolveProjectPath(allocator, project_path);
    defer allocator.free(resolved);

    // Replace / and . with -
    var result = try allocator.alloc(u8, resolved.len);
    for (resolved, 0..) |c, i| {
        result[i] = if (c == '/' or c == '.') '-' else c;
    }
    return result;
}

/// Result from resolveProjectDir
pub const ProjectDirResult = struct {
    project_path: []const u8,
    claude_projects_dir: []const u8,

    pub fn deinit(self: *ProjectDirResult, allocator: Allocator) void {
        allocator.free(self.project_path);
        allocator.free(self.claude_projects_dir);
    }
};

/// Combine: resolve path + generate slug + return claude projects dir
/// Returns owned strings that must be freed by caller
pub fn resolveProjectDir(allocator: Allocator, project_path: []const u8) !ProjectDirResult {
    const resolved = try resolveProjectPath(allocator, project_path);
    errdefer allocator.free(resolved);

    const slug = try getProjectSlug(allocator, project_path);
    defer allocator.free(slug);

    const home = try getHomeDir();
    const claude_projects_dir = try std.fs.path.join(allocator, &.{ home, ".claude", "projects", slug });

    return .{
        .project_path = resolved,
        .claude_projects_dir = claude_projects_dir,
    };
}

/// Get the base Claude projects directory (~/.claude/projects)
pub fn getClaudeProjectsBase(allocator: Allocator) ![]const u8 {
    const home = try getHomeDir();
    return std.fs.path.join(allocator, &.{ home, ".claude", "projects" });
}

test "resolveProjectPath expands tilde" {
    const allocator = std.testing.allocator;
    const result = try resolveProjectPath(allocator, "~/code/foo");
    defer allocator.free(result);
    try std.testing.expect(!std.mem.startsWith(u8, result, "~"));
    try std.testing.expect(std.mem.endsWith(u8, result, "/code/foo"));
}

test "getProjectSlug replaces slashes and dots" {
    const allocator = std.testing.allocator;
    const result = try getProjectSlug(allocator, "/home/user/my.project");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("-home-user-my-project", result);
}

test "resolveProjectDir returns both paths" {
    const allocator = std.testing.allocator;
    var result = try resolveProjectDir(allocator, "/home/user/myproject");
    defer result.deinit(allocator);
    try std.testing.expectEqualStrings("/home/user/myproject", result.project_path);
    try std.testing.expect(std.mem.endsWith(u8, result.claude_projects_dir, "/.claude/projects/-home-user-myproject"));
}
