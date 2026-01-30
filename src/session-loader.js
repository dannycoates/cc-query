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
 * Count sessions and agents from a list of file paths
 * @param {string[]} files - Array of relative file paths from project directory
 * @param {string} sessionFilter - Optional session ID prefix
 * @returns {{ sessions: number, agents: number }}
 */
function countSessionsAndAgents(files, sessionFilter = "") {
  const jsonlFiles = files.filter((e) => e.endsWith(".jsonl"));

  let sessions = 0;
  let agents = 0;

  for (const file of jsonlFiles) {
    const basename = file.split("/").pop() ?? file;
    const isSubagentPath = file.includes("/subagents/");

    if (isSubagentPath && basename.startsWith("agent-")) {
      // Subagent file: {sessionId}/subagents/agent-xxx.jsonl
      // Check if this subagent belongs to a filtered session
      if (sessionFilter) {
        const sessionDir = file.split("/")[0];
        if (sessionDir?.startsWith(sessionFilter)) {
          agents++;
        }
      } else {
        agents++;
      }
    } else if (!basename.startsWith("agent-") && !isSubagentPath) {
      // Session file: {sessionId}.jsonl (top-level, not agent- prefixed)
      if (!sessionFilter || basename.startsWith(sessionFilter)) {
        sessions++;
      }
    }
  }

  return { sessions, agents };
}

/**
 * Get session info and file pattern for querying
 * @param {string | null} claudeProjectsDir - Path to ~/.claude/projects/{slug}, or null for all projects
 * @param {string} [sessionFilter] - Optional session ID prefix
 * @returns {Promise<{ sessionCount: number, agentCount: number, projectCount: number, filePattern: string | string[] }>}
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
      const counts = countSessionsAndAgents(entries, sessionFilter);
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
    // When session filter is provided, include both the filtered session AND its subagents
    // Subagents are stored in {session_id}/subagents/*.jsonl
    // Only include subagents pattern if there are actually subagent files
    let filePattern;
    if (sessionFilter) {
      filePattern = [join(base, "*", `${sessionFilter}*.jsonl`)];
      if (totalAgents > 0) {
        filePattern.push(join(base, "*", `${sessionFilter}*/subagents/*.jsonl`));
      }
    } else {
      filePattern = join(base, "*", "**/*.jsonl");
    }

    return {
      sessionCount: totalSessions,
      agentCount: totalAgents,
      projectCount: projectDirs.length,
      filePattern,
    };
  }

  // Recursively find all jsonl files (includes */subagents/*.jsonl)
  const entries = await readdir(claudeProjectsDir, { recursive: true });
  const { sessions, agents } = countSessionsAndAgents(entries, sessionFilter);

  if (sessions === 0) {
    return { sessionCount: 0, agentCount: 0, projectCount: 1, filePattern: "" };
  }

  // Use glob pattern for matching
  // When session filter is provided, include both the filtered session AND its subagents
  // Subagents are stored in {session_id}/subagents/*.jsonl
  // Only include subagents pattern if there are actually subagent files
  let filePattern;
  if (sessionFilter) {
    filePattern = [join(claudeProjectsDir, `${sessionFilter}*.jsonl`)];
    if (agents > 0) {
      filePattern.push(
        join(claudeProjectsDir, `${sessionFilter}*/subagents/*.jsonl`),
      );
    }
  } else {
    filePattern = join(claudeProjectsDir, "**/*.jsonl");
  }

  return {
    sessionCount: sessions,
    agentCount: agents,
    projectCount: 1,
    filePattern,
  };
}
