import { homedir } from "node:os";
import { join, resolve, isAbsolute } from "node:path";

/**
 * Resolve a project path to an absolute path
 * @param {string} projectPath - Path like ~/code/foo, ./foo, or /home/user/code/foo
 * @returns {string} - Absolute path
 */
function resolveProjectPath(projectPath) {
  let resolved = projectPath.replace(/^~/, homedir());
  if (!isAbsolute(resolved)) {
    const baseDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
    resolved = resolve(baseDir, resolved);
  }
  return resolved;
}

/**
 * Get project slug from a filesystem path
 * @param {string} projectPath - Path like ~/code/zombie-brainz or /home/user/code/zombie-brainz
 * @returns {string} - Project slug like -home-user-code-zombie-brainz
 */
export function getProjectSlug(projectPath) {
  return resolveProjectPath(projectPath).replace(/[/.]/g, "-");
}

/**
 * Convert a project path to the Claude projects directory path
 * @param {string} projectPath - Path like ~/code/zombie-brainz or /home/user/code/zombie-brainz
 * @returns {{ projectPath: string, claudeProjectsDir: string }}
 */
export function resolveProjectDir(projectPath) {
  const resolved = resolveProjectPath(projectPath);
  const slug = getProjectSlug(projectPath);
  const claudeProjectsDir = join(homedir(), ".claude", "projects", slug);
  return { projectPath: resolved, claudeProjectsDir };
}
