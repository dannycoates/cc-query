import { readdir } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";

/**
 * Get the base Claude projects directory
 * @returns {string}
 */
export function getClaudeProjectsBase() {
  return join(homedir(), ".claude", "projects");
}

/**
 * Get all project directories
 * @returns {Promise<string[]>} Array of project directory paths
 */
export async function getAllProjectDirs() {
  const base = getClaudeProjectsBase();
  const entries = await readdir(base, { withFileTypes: true });
  return entries.filter((e) => e.isDirectory()).map((e) => join(base, e.name));
}

/**
 * Count sessions and agents from a list of jsonl filenames
 * @param {string[]} files - Array of filenames (basenames)
 * @param {string} sessionFilter - Optional session ID prefix
 * @returns {{ sessions: number, agents: number }}
 */
function countSessionsAndAgents(files, sessionFilter = "") {
  const jsonlFiles = files.filter((e) => e.endsWith(".jsonl"));
  const grouped = Object.groupBy(jsonlFiles, (e) =>
    e.startsWith("agent-") ? "agent" : "session",
  );
  const agents = grouped.agent?.length ?? 0;
  const sessions = (grouped.session ?? []).filter(
    (e) => !sessionFilter || e.startsWith(sessionFilter),
  ).length;
  return { sessions, agents };
}

/**
 * Get session info and file pattern for querying
 * @param {string | null} claudeProjectsDir - Path to ~/.claude/projects/{slug}, or null for all projects
 * @param {string} [sessionFilter] - Optional session ID prefix
 * @returns {Promise<{ sessionCount: number, agentCount: number, projectCount: number, filePattern: string }>}
 */
export async function getSessionFiles(claudeProjectsDir, sessionFilter = "") {
  // If no specific project, use all projects
  if (!claudeProjectsDir) {
    const base = getClaudeProjectsBase();
    const projectDirs = await getAllProjectDirs();

    let totalSessions = 0;
    let totalAgents = 0;

    for (const dir of projectDirs) {
      // Recursively find all jsonl files (includes */subagents/*.jsonl)
      const entries = await readdir(dir, { recursive: true });
      const basenames = entries.map((e) => e.split("/").pop() ?? e);
      const counts = countSessionsAndAgents(basenames, sessionFilter);
      totalSessions += counts.sessions;
      totalAgents += counts.agents;
    }

    if (totalSessions === 0) {
      return {
        sessionCount: 0,
        agentCount: 0,
        projectCount: 0,
        filePattern: "",
      };
    }

    // Use glob pattern for all projects (** for recursive matching)
    const filePattern = sessionFilter
      ? join(base, "*", `**/${sessionFilter}*.jsonl`)
      : join(base, "*", "**/*.jsonl");

    return {
      sessionCount: totalSessions,
      agentCount: totalAgents,
      projectCount: projectDirs.length,
      filePattern,
    };
  }

  // Recursively find all jsonl files (includes */subagents/*.jsonl)
  const entries = await readdir(claudeProjectsDir, { recursive: true });
  const basenames = entries.map((e) => e.split("/").pop() ?? e);
  const { sessions, agents } = countSessionsAndAgents(basenames, sessionFilter);

  if (sessions === 0) {
    return { sessionCount: 0, agentCount: 0, projectCount: 1, filePattern: "" };
  }

  // Use glob pattern with ** for recursive matching
  const filePattern = sessionFilter
    ? join(claudeProjectsDir, `**/${sessionFilter}*.jsonl`)
    : join(claudeProjectsDir, "**/*.jsonl");

  return {
    sessionCount: sessions,
    agentCount: agents,
    projectCount: 1,
    filePattern,
  };
}
