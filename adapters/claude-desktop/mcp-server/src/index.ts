/**
 * Scribe MCP Server for Claude Desktop
 *
 * A Model Context Protocol server that exposes Scribe journal operations
 * as tools and resources. Claude Desktop connects via stdio transport.
 *
 * Claude Desktop configuration (~/.config/claude/claude_desktop_config.json):
 *
 *   {
 *     "mcpServers": {
 *       "scribe": {
 *         "command": "node",
 *         "args": ["/path/to/scribe/adapters/claude-desktop/mcp-server/dist/index.js"],
 *         "env": {
 *           "SCRIBE_DATA_PATH": "/Users/username/Desktop/Scribe"
 *         }
 *       }
 *     }
 *   }
 */

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { v4 as uuidv4 } from "uuid";

// ---------------------------------------------------------------------------
// 1. Data Path Resolution
// ---------------------------------------------------------------------------

function resolveDataPath(): string {
  // Priority 1: Environment variable
  if (process.env.SCRIBE_DATA_PATH) {
    return expandTilde(process.env.SCRIBE_DATA_PATH);
  }

  // Priority 2: pointer.json in the package directory (or parent directories)
  const candidates = [
    path.resolve(__dirname, "..", "pointer.json"),
    path.resolve(__dirname, "..", "..", "pointer.json"),
    path.resolve(__dirname, "..", "..", "..", "pointer.json"),
    path.resolve(__dirname, "..", "..", "..", "..", "pointer.json"),
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) {
      try {
        const pointer = JSON.parse(fs.readFileSync(candidate, "utf-8"));
        if (pointer.data_path) {
          return expandTilde(pointer.data_path);
        }
      } catch {
        // Ignore malformed pointer.json, continue to next candidate
      }
    }
  }

  // Priority 3: Default location
  return path.join(os.homedir(), "Desktop", "Scribe");
}

function expandTilde(filePath: string): string {
  if (filePath.startsWith("~/")) {
    return path.join(os.homedir(), filePath.slice(2));
  }
  return filePath;
}

// ---------------------------------------------------------------------------
// 2. File System Helpers
// ---------------------------------------------------------------------------

const DATA_DIR = resolveDataPath();

function dataPath(...segments: string[]): string {
  return path.join(DATA_DIR, ...segments);
}

function ensureDir(dirPath: string): void {
  if (!fs.existsSync(dirPath)) {
    fs.mkdirSync(dirPath, { recursive: true });
  }
}

function readJsonFile<T>(filePath: string, fallback: T): T {
  try {
    if (!fs.existsSync(filePath)) return fallback;
    const raw = fs.readFileSync(filePath, "utf-8");
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

function writeJsonFile(filePath: string, data: unknown): void {
  ensureDir(path.dirname(filePath));
  fs.writeFileSync(filePath, JSON.stringify(data, null, 2) + "\n", "utf-8");
}

function appendJsonlLine(filePath: string, data: unknown): void {
  ensureDir(path.dirname(filePath));
  fs.appendFileSync(filePath, JSON.stringify(data) + "\n", "utf-8");
}

function readJsonlFile(filePath: string): unknown[] {
  if (!fs.existsSync(filePath)) return [];
  const raw = fs.readFileSync(filePath, "utf-8");
  const lines = raw.split("\n").filter((line) => line.trim().length > 0);
  const results: unknown[] = [];
  for (const line of lines) {
    try {
      results.push(JSON.parse(line));
    } catch {
      // Skip malformed lines
    }
  }
  return results;
}

function readTextFile(filePath: string): string | null {
  try {
    if (!fs.existsSync(filePath)) return null;
    return fs.readFileSync(filePath, "utf-8");
  } catch {
    return null;
  }
}

function shortId(uuid: string): string {
  return uuid.slice(0, 8);
}

function nowISO(): string {
  return new Date().toISOString();
}

// ---------------------------------------------------------------------------
// 2b. Error Logging
// ---------------------------------------------------------------------------

function logError(
  component: string,
  errorType: string,
  message: string,
  context?: string,
  stack?: string,
): void {
  const versionFile = path.resolve(__dirname, "..", "..", "..", "..", "VERSION");
  let scribeVersion = "unknown";
  try {
    if (fs.existsSync(versionFile)) {
      scribeVersion = fs.readFileSync(versionFile, "utf-8").trim();
    }
  } catch { /* ignore */ }

  const config = readJsonFile<Record<string, unknown>>(dataPath("config.json"), {});
  const index = readJsonFile<Record<string, unknown>>(dataPath("index.json"), {});

  const entry = {
    error_id: uuidv4(),
    timestamp: nowISO(),
    scribe_version: scribeVersion,
    component,
    error_type: errorType,
    message,
    context: context || "",
    stack: stack || "",
    platform: "claude-desktop",
    system: {
      os: os.platform(),
      os_version: os.release(),
      node: process.version,
      config_exists: Object.keys(config).length > 0,
      total_entries: (index as { total_entries?: number }).total_entries ?? "unknown",
    },
    submitted: false,
  };

  try {
    appendJsonlLine(dataPath("errors.jsonl"), entry);
  } catch {
    console.error("Failed to write to error log:", message);
  }
}

// ---------------------------------------------------------------------------
// 3. Schema Types
// ---------------------------------------------------------------------------

// Core entry types from schema.json
const CORE_TYPES = [
  "session_open",
  "feature_shipped",
  "bug_fixed",
  "decision_made",
  "learning",
  "correction",
  "process_created",
  "tool_discovered",
  "feedback_received",
  "milestone",
  "reflection",
] as const;

const REQUIRED_FIELDS = [
  "id",
  "timestamp",
  "session_id",
  "user_id",
  "project",
  "type",
  "title",
  "summary",
] as const;

interface ScribeEntry {
  id: string;
  timestamp: string;
  session_id: string;
  user_id: string;
  project: string;
  type: string;
  title: string;
  summary: string;
  decisions?: string[];
  learnings?: string[];
  corrections?: string[];
  metrics?: {
    files_changed?: number;
    lines_added?: number;
    lines_removed?: number;
    duration_minutes?: number;
    agents_dispatched?: number;
    version_shipped?: string | null;
  };
  connections?: {
    builds_on?: string[];
    related_projects?: string[];
    tags?: string[];
  };
  growth?: {
    skill_area?: string;
    complexity?: string;
    autonomy?: string;
    notes?: string;
  };
  behavioral?: {
    drive_state?: string;
    energy?: string;
    triggers?: string[];
    avoidance_signals?: string[];
    language_markers?: string[];
    cognitive_load?: string;
    pattern_flags?: string[];
    notes?: string;
  };
  learning_story?: {
    attempts?: string[];
    thinking?: string;
    outcome?: string;
    transferable_lesson?: string;
  };
}

interface IndexJson {
  total_entries: number;
  projects: Record<
    string,
    { entries: number; last_session: string }
  >;
  tag_cloud: Record<string, number>;
  growth_summary: {
    total_features: number;
    total_bugs_fixed: number;
    total_learnings: number;
    total_corrections: number;
    skill_distribution: Record<string, number>;
  };
  last_updated: string | null;
}

interface CorrectionPattern {
  description: string;
  occurrences: Array<{
    entry_id: string;
    date: string;
    context: string;
  }>;
  level: "observation" | "guardrail" | "critical";
  escalated_at: string | null;
  resolved: boolean;
  resolved_at?: string | null;
  resolution_method?: string | null;
  last_updated: string;
}

interface CorrectionTracker {
  schema_version?: number;
  patterns: Record<string, CorrectionPattern>;
  last_updated?: string;
}

interface SessionCounter {
  total_sessions: number;
  last_session_date: string | null;
}

interface JournalLine {
  id: string;
  timestamp: string;
  project: string;
  type: string;
  title: string;
  file: string;
  user_id?: string;
  summary?: string;
  decisions?: string[];
  learnings?: string[];
  corrections?: string[];
  metrics?: Record<string, unknown>;
  growth?: Record<string, unknown>;
  connections?: Record<string, unknown>;
  behavioral?: Record<string, unknown>;
}

// ---------------------------------------------------------------------------
// 4. Index Update Logic (mirrors writer.sh sections 16-17)
// ---------------------------------------------------------------------------

function getDefaultIndex(): IndexJson {
  return {
    total_entries: 0,
    projects: {},
    tag_cloud: {},
    growth_summary: {
      total_features: 0,
      total_bugs_fixed: 0,
      total_learnings: 0,
      total_corrections: 0,
      skill_distribution: {},
    },
    last_updated: null,
  };
}

function updateIndex(entry: ScribeEntry): void {
  const indexPath = dataPath("index.json");
  const index = readJsonFile<IndexJson>(indexPath, getDefaultIndex());
  const now = nowISO();
  const sessionDate = entry.timestamp.slice(0, 10);

  // Increment total entries
  index.total_entries += 1;

  // Update project stats
  if (!index.projects[entry.project]) {
    index.projects[entry.project] = { entries: 0, last_session: sessionDate };
  }
  index.projects[entry.project].entries += 1;
  index.projects[entry.project].last_session = sessionDate;

  // Update tag cloud
  const tags = entry.connections?.tags;
  if (tags && tags.length > 0) {
    for (const tag of tags) {
      index.tag_cloud[tag] = (index.tag_cloud[tag] || 0) + 1;
    }
  }

  // Update growth summary counters
  switch (entry.type) {
    case "feature_shipped":
      index.growth_summary.total_features += 1;
      break;
    case "bug_fixed":
      index.growth_summary.total_bugs_fixed += 1;
      break;
    case "learning":
      index.growth_summary.total_learnings += 1;
      break;
    case "correction":
      index.growth_summary.total_corrections += 1;
      break;
  }

  // Update skill distribution
  const skillArea = entry.growth?.skill_area;
  if (skillArea && skillArea.length > 0) {
    index.growth_summary.skill_distribution[skillArea] =
      (index.growth_summary.skill_distribution[skillArea] || 0) + 1;
  }

  index.last_updated = now;
  writeJsonFile(indexPath, index);
}

function decrementIndex(entry: ScribeEntry): void {
  const indexPath = dataPath("index.json");
  const index = readJsonFile<IndexJson>(indexPath, getDefaultIndex());
  const now = nowISO();

  index.total_entries = Math.max(0, index.total_entries - 1);

  if (index.projects[entry.project]) {
    index.projects[entry.project].entries = Math.max(
      0,
      index.projects[entry.project].entries - 1
    );
    if (index.projects[entry.project].entries === 0) {
      delete index.projects[entry.project];
    }
  }

  // Decrement tag cloud
  const tags = entry.connections?.tags;
  if (tags && tags.length > 0) {
    for (const tag of tags) {
      if (index.tag_cloud[tag]) {
        index.tag_cloud[tag] -= 1;
        if (index.tag_cloud[tag] <= 0) {
          delete index.tag_cloud[tag];
        }
      }
    }
  }

  // Decrement growth summary counters
  switch (entry.type) {
    case "feature_shipped":
      index.growth_summary.total_features = Math.max(
        0,
        index.growth_summary.total_features - 1
      );
      break;
    case "bug_fixed":
      index.growth_summary.total_bugs_fixed = Math.max(
        0,
        index.growth_summary.total_bugs_fixed - 1
      );
      break;
    case "learning":
      index.growth_summary.total_learnings = Math.max(
        0,
        index.growth_summary.total_learnings - 1
      );
      break;
    case "correction":
      index.growth_summary.total_corrections = Math.max(
        0,
        index.growth_summary.total_corrections - 1
      );
      break;
  }

  // Decrement skill distribution
  const skillArea = entry.growth?.skill_area;
  if (skillArea && index.growth_summary.skill_distribution[skillArea]) {
    index.growth_summary.skill_distribution[skillArea] -= 1;
    if (index.growth_summary.skill_distribution[skillArea] <= 0) {
      delete index.growth_summary.skill_distribution[skillArea];
    }
  }

  index.last_updated = now;
  writeJsonFile(indexPath, index);
}

// ---------------------------------------------------------------------------
// 5. Correction Tracker Logic (mirrors writer.sh section 17)
// ---------------------------------------------------------------------------

function updateCorrectionTracker(entry: ScribeEntry): void {
  const corrections = entry.corrections;
  if (!corrections || corrections.length === 0) return;

  const trackerPath = dataPath("correction-tracker.json");
  const tracker = readJsonFile<CorrectionTracker>(trackerPath, {
    schema_version: 1,
    patterns: {},
  });

  const now = nowISO();
  const entryDate = entry.timestamp.slice(0, 10);
  const sid = shortId(entry.id);

  for (const correction of corrections) {
    if (!correction.trim()) continue;

    const correctionLower = correction.toLowerCase();

    // Try to match against existing patterns
    let matchedKey: string | null = null;
    for (const [key, pattern] of Object.entries(tracker.patterns)) {
      const descLower = (pattern.description || "").toLowerCase();
      if (correctionLower.includes(descLower) || descLower.includes(correctionLower)) {
        matchedKey = key;
        break;
      }
    }

    if (matchedKey) {
      // Add occurrence to existing pattern
      const pattern = tracker.patterns[matchedKey];
      pattern.occurrences.push({
        entry_id: sid,
        date: entryDate,
        context: correction,
      });
      pattern.last_updated = now;

      // Escalation logic
      const count = pattern.occurrences.length;
      if (count >= 5 && pattern.level !== "critical") {
        pattern.level = "critical";
        pattern.escalated_at = now;
      } else if (count >= 3 && pattern.level === "observation") {
        pattern.level = "guardrail";
        pattern.escalated_at = now;
      }
    } else {
      // Create new pattern with a slug from the first few words
      let slug = correction
        .toLowerCase()
        .replace(/[^a-z0-9 ]/g, "")
        .split(/\s+/)
        .slice(0, 4)
        .join("-")
        .slice(0, 40);

      // Ensure slug is unique
      if (tracker.patterns[slug]) {
        slug = `${slug}-${sid}`;
      }

      tracker.patterns[slug] = {
        description: correction,
        occurrences: [
          { entry_id: sid, date: entryDate, context: correction },
        ],
        level: "observation",
        escalated_at: null,
        resolved: false,
        last_updated: now,
      };
    }
  }

  tracker.last_updated = now;
  writeJsonFile(trackerPath, tracker);
}

// ---------------------------------------------------------------------------
// 6. Journal Line Builder
// ---------------------------------------------------------------------------

function buildJournalLine(entry: ScribeEntry): JournalLine {
  const sid = shortId(entry.id);
  const line: JournalLine = {
    id: entry.id,
    timestamp: entry.timestamp,
    project: entry.project,
    type: entry.type,
    title: entry.title,
    file: `entries/${sid}.json`,
    user_id: entry.user_id,
  };

  if (entry.summary) line.summary = entry.summary;
  if (entry.decisions && entry.decisions.length > 0) line.decisions = entry.decisions;
  if (entry.learnings && entry.learnings.length > 0) line.learnings = entry.learnings;
  if (entry.corrections && entry.corrections.length > 0) line.corrections = entry.corrections;
  if (entry.metrics && Object.keys(entry.metrics).length > 0)
    line.metrics = entry.metrics as Record<string, unknown>;
  if (entry.growth && Object.keys(entry.growth).length > 0)
    line.growth = entry.growth as Record<string, unknown>;
  if (entry.connections && Object.keys(entry.connections).length > 0)
    line.connections = entry.connections as Record<string, unknown>;
  if (entry.behavioral && Object.keys(entry.behavioral).length > 0)
    line.behavioral = entry.behavioral as Record<string, unknown>;

  return line;
}

// ---------------------------------------------------------------------------
// 7. Entry Validation
// ---------------------------------------------------------------------------

function validateEntry(entry: Record<string, unknown>): string | null {
  for (const field of REQUIRED_FIELDS) {
    if (!entry[field] || (typeof entry[field] === "string" && !(entry[field] as string).trim())) {
      return `Missing required field: ${field}`;
    }
  }

  // Validate title length
  if (typeof entry.title === "string" && entry.title.length > 120) {
    return `Title exceeds 120 characters (got ${entry.title.length})`;
  }

  return null;
}

// ---------------------------------------------------------------------------
// 8. Entry Finder (supports full UUID or short ID)
// ---------------------------------------------------------------------------

function findEntryFile(entryId: string): string | null {
  const entriesDir = dataPath("entries");
  if (!fs.existsSync(entriesDir)) return null;

  // Try direct short ID match
  const sid = entryId.length >= 8 ? entryId.slice(0, 8) : entryId;
  const directPath = path.join(entriesDir, `${sid}.json`);
  if (fs.existsSync(directPath)) return directPath;

  // Scan entries directory for a matching file
  const files = fs.readdirSync(entriesDir).filter((f) => f.endsWith(".json"));
  for (const file of files) {
    if (file.startsWith(entryId) || file === `${entryId}.json`) {
      return path.join(entriesDir, file);
    }
    // Check inside the file for full ID match
    try {
      const content = JSON.parse(fs.readFileSync(path.join(entriesDir, file), "utf-8"));
      if (content.id === entryId) {
        return path.join(entriesDir, file);
      }
    } catch {
      // Skip unreadable files
    }
  }

  return null;
}

// ---------------------------------------------------------------------------
// 9. JSONL Rewrite (for edit and delete operations)
// ---------------------------------------------------------------------------

function rewriteJournalLine(entryId: string, updatedLine: JournalLine | null): void {
  const journalPath = dataPath("journal.jsonl");
  if (!fs.existsSync(journalPath)) return;

  const lines = readJsonlFile(journalPath) as JournalLine[];
  const newLines: string[] = [];

  for (const line of lines) {
    if (line.id === entryId) {
      if (updatedLine !== null) {
        // Replace the line
        newLines.push(JSON.stringify(updatedLine));
      }
      // If updatedLine is null, we're deleting — skip it
    } else {
      newLines.push(JSON.stringify(line));
    }
  }

  fs.writeFileSync(journalPath, newLines.join("\n") + (newLines.length > 0 ? "\n" : ""), "utf-8");
}

// ---------------------------------------------------------------------------
// 10. Packet Builder (for scribe_share)
// ---------------------------------------------------------------------------

function buildPacket(
  project: string,
  recipientName: string,
  entries: ScribeEntry[],
  config: Record<string, unknown>
): Record<string, unknown> {
  const now = nowISO();
  const packetId = uuidv4();

  // Build sender profile from config
  const senderProfile = (config.profile || {}) as Record<string, unknown>;
  const sender: Record<string, unknown> = {
    name: senderProfile.name || "Unknown",
    scribe_id: senderProfile.scribe_id || "unset",
  };
  if (senderProfile.role) sender.role = senderProfile.role;
  if (senderProfile.expertise) sender.expertise = senderProfile.expertise;
  if (senderProfile.working_style) sender.working_style = senderProfile.working_style;
  if (senderProfile.communication_preferences)
    sender.communication_preferences = senderProfile.communication_preferences;

  // Filter entries to project and extract decisions, learnings, learning stories
  const decisions: Array<Record<string, string>> = [];
  const learnings: Array<Record<string, string>> = [];
  const learningStories: Array<Record<string, unknown>> = [];

  for (const entry of entries) {
    if (entry.decisions) {
      for (const d of entry.decisions) {
        decisions.push({
          title: d,
          date: entry.timestamp.slice(0, 10),
        });
      }
    }
    if (entry.learnings) {
      for (const l of entry.learnings) {
        learnings.push({ title: l });
      }
    }
    if (entry.learning_story) {
      learningStories.push({
        title: entry.title,
        attempts: entry.learning_story.attempts || [],
        thinking: entry.learning_story.thinking || "",
        outcome: entry.learning_story.outcome || "",
        transferable_lesson: entry.learning_story.transferable_lesson || "",
      });
    }
  }

  const packet: Record<string, unknown> = {
    scribe_packet: "1.0",
    generated: now,
    packet_id: packetId,
    sender,
    receiver: { name: recipientName },
    project_context: { project },
    decisions: decisions.length > 0 ? decisions : undefined,
    learnings: learnings.length > 0 ? learnings : undefined,
    learning_stories: learningStories.length > 0 ? learningStories : undefined,
  };

  // Remove undefined keys
  return JSON.parse(JSON.stringify(packet));
}

// ---------------------------------------------------------------------------
// 11. Core Prompt File Resolver
// ---------------------------------------------------------------------------

function findCoreFile(filename: string): string | null {
  // The core/ directory is relative to the project root, not the MCP server
  // Walk up from __dirname to find the scribe project root
  const candidates = [
    path.resolve(__dirname, "..", "..", "..", "..", "core", filename),
    path.resolve(__dirname, "..", "..", "..", "core", filename),
    path.resolve(__dirname, "..", "core", filename),
  ];

  for (const candidate of candidates) {
    if (fs.existsSync(candidate)) return candidate;
  }

  return null;
}

// ---------------------------------------------------------------------------
// 12. MCP Server Setup
// ---------------------------------------------------------------------------

const server = new McpServer({
  name: "scribe",
  version: "0.1.0",
});

// ---------------------------------------------------------------------------
// Tool: scribe_write_entry
// ---------------------------------------------------------------------------

server.tool(
  "scribe_write_entry",
  "Write a new Scribe journal entry. Validates required fields, writes to local files (entries/<short-id>.json + journal.jsonl), updates index.json stats, and updates correction-tracker.json if the entry has corrections.",
  {
    entry: z
      .string()
      .describe("Full entry JSON as a string, conforming to the Scribe entry schema"),
  },
  async ({ entry: entryJson }) => {
    try {
      const entry = JSON.parse(entryJson) as ScribeEntry;

      // Validate required fields
      const validationError = validateEntry(entry as unknown as Record<string, unknown>);
      if (validationError) {
        return { content: [{ type: "text" as const, text: `Validation error: ${validationError}` }], isError: true };
      }

      const sid = shortId(entry.id);

      // Ensure data directories exist
      ensureDir(dataPath("entries"));

      // 1. Write individual entry file
      const entryFilePath = dataPath("entries", `${sid}.json`);
      writeJsonFile(entryFilePath, entry);

      // 2. Append to journal.jsonl
      const journalLine = buildJournalLine(entry);
      appendJsonlLine(dataPath("journal.jsonl"), journalLine);

      // 3. Update index.json
      try {
        updateIndex(entry);
      } catch (err) {
        // Non-fatal: entry is saved even if index update fails
        console.error("Warning: index.json update failed:", err);
      }

      // 4. Update correction tracker
      try {
        updateCorrectionTracker(entry);
      } catch (err) {
        console.error("Warning: correction-tracker.json update failed:", err);
      }

      // Build receipt
      const receipt = [
        `SCRIBE RECEIPT`,
        `  Entry:   ${entry.title}`,
        `  Type:    ${entry.type}`,
        `  Project: ${entry.project}`,
        `  ID:      ${sid}`,
        `  Targets: file+index`,
      ].join("\n");

      return { content: [{ type: "text" as const, text: receipt }] };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError("mcp-server", "runtime", `Failed to write entry: ${message}`, undefined, err instanceof Error ? err.stack : undefined);
      return { content: [{ type: "text" as const, text: `Failed to write entry: ${message}` }], isError: true };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: scribe_list_entries
// ---------------------------------------------------------------------------

server.tool(
  "scribe_list_entries",
  "List Scribe journal entries with optional filters. Reads journal.jsonl and returns matching entries.",
  {
    project: z.string().optional().describe("Filter by project name"),
    type: z.string().optional().describe("Filter by entry type"),
    since: z.string().optional().describe("Filter entries after this ISO date (e.g. 2026-05-01)"),
    search: z.string().optional().describe("Search term to match against title and summary"),
    limit: z.number().optional().describe("Maximum number of entries to return (default: 50)"),
  },
  async ({ project, type, since, search, limit }) => {
    try {
      const lines = readJsonlFile(dataPath("journal.jsonl")) as JournalLine[];
      const maxResults = limit || 50;

      let filtered = lines;

      if (project) {
        filtered = filtered.filter((l) => l.project === project);
      }

      if (type) {
        filtered = filtered.filter((l) => l.type === type);
      }

      if (since) {
        filtered = filtered.filter((l) => l.timestamp >= since);
      }

      if (search) {
        const term = search.toLowerCase();
        filtered = filtered.filter(
          (l) =>
            l.title.toLowerCase().includes(term) ||
            (l.summary && l.summary.toLowerCase().includes(term))
        );
      }

      // Most recent first
      filtered.sort((a, b) => b.timestamp.localeCompare(a.timestamp));

      // Apply limit
      const results = filtered.slice(0, maxResults);

      const output = results.map((l) => ({
        id: l.id,
        short_id: shortId(l.id),
        date: l.timestamp.slice(0, 10),
        project: l.project,
        type: l.type,
        title: l.title,
      }));

      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify(
              { total: filtered.length, showing: results.length, entries: output },
              null,
              2
            ),
          },
        ],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError("mcp-server", "runtime", `Failed to list entries: ${message}`, undefined, err instanceof Error ? err.stack : undefined);
      return { content: [{ type: "text" as const, text: `Failed to list entries: ${message}` }], isError: true };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: scribe_get_status
// ---------------------------------------------------------------------------

server.tool(
  "scribe_get_status",
  "Get Scribe system status: total entries, session count, entries by type and project, active guardrails, and growth summary.",
  {},
  async () => {
    try {
      const index = readJsonFile<IndexJson>(dataPath("index.json"), getDefaultIndex());
      const sessionCounter = readJsonFile<SessionCounter>(dataPath("session-counter.json"), {
        total_sessions: 0,
        last_session_date: null,
      });
      const tracker = readJsonFile<CorrectionTracker>(dataPath("correction-tracker.json"), {
        patterns: {},
      });

      // Count entries by type from journal.jsonl
      const lines = readJsonlFile(dataPath("journal.jsonl")) as JournalLine[];
      const byType: Record<string, number> = {};
      for (const line of lines) {
        byType[line.type] = (byType[line.type] || 0) + 1;
      }

      // Active guardrails
      const guardrails: Array<{
        pattern: string;
        description: string;
        level: string;
        occurrences: number;
      }> = [];
      for (const [key, pattern] of Object.entries(tracker.patterns)) {
        if (
          (pattern.level === "guardrail" || pattern.level === "critical") &&
          !pattern.resolved
        ) {
          guardrails.push({
            pattern: key,
            description: pattern.description,
            level: pattern.level,
            occurrences: pattern.occurrences.length,
          });
        }
      }

      const status = {
        data_path: DATA_DIR,
        total_entries: index.total_entries,
        total_sessions: sessionCounter.total_sessions,
        last_session: sessionCounter.last_session_date,
        entries_by_type: byType,
        entries_by_project: Object.fromEntries(
          Object.entries(index.projects).map(([k, v]) => [k, v.entries])
        ),
        active_guardrails: guardrails,
        growth_summary: index.growth_summary,
        last_updated: index.last_updated,
      };

      return {
        content: [{ type: "text" as const, text: JSON.stringify(status, null, 2) }],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError("mcp-server", "runtime", `Failed to get status: ${message}`, undefined, err instanceof Error ? err.stack : undefined);
      return { content: [{ type: "text" as const, text: `Failed to get status: ${message}` }], isError: true };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: scribe_get_entry
// ---------------------------------------------------------------------------

server.tool(
  "scribe_get_entry",
  "Retrieve a full Scribe journal entry by ID. Accepts a full UUID or short ID (first 8 characters).",
  {
    entry_id: z.string().describe("Entry ID — full UUID or short ID (first 8 chars)"),
  },
  async ({ entry_id }) => {
    try {
      const filePath = findEntryFile(entry_id);
      if (!filePath) {
        return {
          content: [{ type: "text" as const, text: `Entry not found: ${entry_id}` }],
          isError: true,
        };
      }

      const entry = JSON.parse(fs.readFileSync(filePath, "utf-8"));
      return {
        content: [{ type: "text" as const, text: JSON.stringify(entry, null, 2) }],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError("mcp-server", "runtime", `Failed to get entry: ${message}`, undefined, err instanceof Error ? err.stack : undefined);
      return { content: [{ type: "text" as const, text: `Failed to get entry: ${message}` }], isError: true };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: scribe_edit_entry
// ---------------------------------------------------------------------------

server.tool(
  "scribe_edit_entry",
  "Edit an existing Scribe journal entry. Reads the entry, merges the provided fields, writes back to the entry file, and updates the journal.jsonl line.",
  {
    entry_id: z.string().describe("Entry ID — full UUID or short ID"),
    updates: z
      .string()
      .describe("JSON string of fields to update (e.g. {\"title\": \"New title\", \"summary\": \"Updated summary\"})"),
  },
  async ({ entry_id, updates: updatesJson }) => {
    try {
      const filePath = findEntryFile(entry_id);
      if (!filePath) {
        return {
          content: [{ type: "text" as const, text: `Entry not found: ${entry_id}` }],
          isError: true,
        };
      }

      const existing = JSON.parse(fs.readFileSync(filePath, "utf-8")) as ScribeEntry;
      const updates = JSON.parse(updatesJson) as Partial<ScribeEntry>;

      // Prevent changing the entry ID
      delete (updates as Record<string, unknown>).id;

      // Merge updates into existing entry
      const merged = { ...existing, ...updates } as ScribeEntry;

      // Write updated entry file
      writeJsonFile(filePath, merged);

      // Update journal.jsonl line
      const updatedLine = buildJournalLine(merged);
      rewriteJournalLine(existing.id, updatedLine);

      return {
        content: [
          {
            type: "text" as const,
            text: `Entry ${shortId(existing.id)} updated. Changed fields: ${Object.keys(updates).join(", ")}`,
          },
        ],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError("mcp-server", "runtime", `Failed to edit entry: ${message}`, undefined, err instanceof Error ? err.stack : undefined);
      return { content: [{ type: "text" as const, text: `Failed to edit entry: ${message}` }], isError: true };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: scribe_delete_entry
// ---------------------------------------------------------------------------

server.tool(
  "scribe_delete_entry",
  "Delete a Scribe journal entry. Moves the entry file to revisions/ with a timestamp prefix, removes it from journal.jsonl, and decrements index.json counts.",
  {
    entry_id: z.string().describe("Entry ID — full UUID or short ID"),
  },
  async ({ entry_id }) => {
    try {
      const filePath = findEntryFile(entry_id);
      if (!filePath) {
        return {
          content: [{ type: "text" as const, text: `Entry not found: ${entry_id}` }],
          isError: true,
        };
      }

      const entry = JSON.parse(fs.readFileSync(filePath, "utf-8")) as ScribeEntry;
      const sid = shortId(entry.id);

      // Move to revisions/ with timestamp prefix
      const revisionsDir = dataPath("revisions");
      ensureDir(revisionsDir);
      const timestamp = new Date()
        .toISOString()
        .replace(/[:.]/g, "-")
        .slice(0, 19);
      const revisionFilename = `${timestamp}_${sid}.json`;
      fs.renameSync(filePath, path.join(revisionsDir, revisionFilename));

      // Remove from journal.jsonl
      rewriteJournalLine(entry.id, null);

      // Decrement index.json
      try {
        decrementIndex(entry);
      } catch (err) {
        console.error("Warning: index.json decrement failed:", err);
      }

      return {
        content: [
          {
            type: "text" as const,
            text: `Entry ${sid} deleted. Backup saved to revisions/${revisionFilename}`,
          },
        ],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError("mcp-server", "runtime", `Failed to delete entry: ${message}`, undefined, err instanceof Error ? err.stack : undefined);
      return { content: [{ type: "text" as const, text: `Failed to delete entry: ${message}` }], isError: true };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: scribe_share
// ---------------------------------------------------------------------------

server.tool(
  "scribe_share",
  "Generate a Scribe-to-Scribe packet for a project. Filters entries to the specified project, strips behavioral and growth data, builds a packet with sender profile, and saves to outbox/.",
  {
    project: z.string().describe("Project name to share entries for"),
    recipient: z.string().describe("Name of the person receiving the packet"),
  },
  async ({ project, recipient }) => {
    try {
      const config = readJsonFile<Record<string, unknown>>(dataPath("config.json"), {});

      // Read all entries for this project
      const entriesDir = dataPath("entries");
      const projectEntries: ScribeEntry[] = [];

      if (fs.existsSync(entriesDir)) {
        const files = fs.readdirSync(entriesDir).filter((f) => f.endsWith(".json"));
        for (const file of files) {
          try {
            const entry = JSON.parse(
              fs.readFileSync(path.join(entriesDir, file), "utf-8")
            ) as ScribeEntry;
            if (entry.project === project) {
              // Strip behavioral and growth data for sharing
              const stripped = { ...entry };
              delete stripped.behavioral;
              delete stripped.growth;
              projectEntries.push(stripped);
            }
          } catch {
            // Skip unreadable files
          }
        }
      }

      if (projectEntries.length === 0) {
        return {
          content: [
            {
              type: "text" as const,
              text: `No entries found for project "${project}". Nothing to share.`,
            },
          ],
          isError: true,
        };
      }

      const packet = buildPacket(project, recipient, projectEntries, config);

      // Save to outbox
      const outboxDir = dataPath("outbox");
      ensureDir(outboxDir);
      const packetDate = new Date().toISOString().slice(0, 10);
      const packetFilename = `${project}-to-${recipient.toLowerCase().replace(/\s+/g, "-")}-${packetDate}.packet.json`;
      writeJsonFile(path.join(outboxDir, packetFilename), packet);

      return {
        content: [
          {
            type: "text" as const,
            text: [
              `Packet generated: ${packetFilename}`,
              `  Project:    ${project}`,
              `  Recipient:  ${recipient}`,
              `  Entries:    ${projectEntries.length}`,
              `  Decisions:  ${(packet.decisions as unknown[])?.length || 0}`,
              `  Learnings:  ${(packet.learnings as unknown[])?.length || 0}`,
              `  Stories:    ${(packet.learning_stories as unknown[])?.length || 0}`,
              ``,
              `Saved to: outbox/${packetFilename}`,
              ``,
              `Packet content for review:`,
              JSON.stringify(packet, null, 2),
            ].join("\n"),
          },
        ],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError("mcp-server", "runtime", `Failed to generate packet: ${message}`, undefined, err instanceof Error ? err.stack : undefined);
      return { content: [{ type: "text" as const, text: `Failed to generate packet: ${message}` }], isError: true };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: scribe_inbox
// ---------------------------------------------------------------------------

server.tool(
  "scribe_inbox",
  "List received Scribe-to-Scribe packets in the inbox/ directory.",
  {},
  async () => {
    try {
      const inboxDir = dataPath("inbox");
      if (!fs.existsSync(inboxDir)) {
        return {
          content: [{ type: "text" as const, text: "Inbox is empty (directory does not exist)." }],
        };
      }

      const files = fs
        .readdirSync(inboxDir)
        .filter((f) => f.endsWith(".packet.json"));

      if (files.length === 0) {
        return {
          content: [{ type: "text" as const, text: "Inbox is empty." }],
        };
      }

      const summaries = files.map((file) => {
        try {
          const packet = JSON.parse(
            fs.readFileSync(path.join(inboxDir, file), "utf-8")
          ) as Record<string, unknown>;
          const sender = (packet.sender || {}) as Record<string, unknown>;
          const projectCtx = (packet.project_context || {}) as Record<string, unknown>;
          return {
            filename: file,
            sender: sender.name || "Unknown",
            project: projectCtx.project || "Unknown",
            date: (packet.generated as string)?.slice(0, 10) || "Unknown",
            decisions: Array.isArray(packet.decisions)
              ? packet.decisions.length
              : 0,
            learnings: Array.isArray(packet.learnings)
              ? packet.learnings.length
              : 0,
            stories: Array.isArray(packet.learning_stories)
              ? packet.learning_stories.length
              : 0,
          };
        } catch {
          return { filename: file, error: "Failed to parse packet" };
        }
      });

      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify({ packets: summaries }, null, 2),
          },
        ],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError("mcp-server", "runtime", `Failed to read inbox: ${message}`, undefined, err instanceof Error ? err.stack : undefined);
      return { content: [{ type: "text" as const, text: `Failed to read inbox: ${message}` }], isError: true };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: scribe_accept_packet
// ---------------------------------------------------------------------------

server.tool(
  "scribe_accept_packet",
  "Accept a Scribe-to-Scribe packet from the inbox. Reads the packet file and returns its full content for Claude to integrate into session context.",
  {
    filename: z.string().describe("Packet filename (e.g. project-to-name-2026-05-10.packet.json)"),
  },
  async ({ filename }) => {
    try {
      const packetPath = dataPath("inbox", filename);
      if (!fs.existsSync(packetPath)) {
        return {
          content: [
            {
              type: "text" as const,
              text: `Packet not found: ${filename}. Run scribe_inbox to list available packets.`,
            },
          ],
          isError: true,
        };
      }

      const packet = JSON.parse(fs.readFileSync(packetPath, "utf-8"));
      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify(packet, null, 2),
          },
        ],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      logError("mcp-server", "runtime", `Failed to accept packet: ${message}`, undefined, err instanceof Error ? err.stack : undefined);
      return { content: [{ type: "text" as const, text: `Failed to accept packet: ${message}` }], isError: true };
    }
  }
);

// ---------------------------------------------------------------------------
// Tool: scribe_get_guardrails
// ---------------------------------------------------------------------------

server.tool(
  "scribe_get_guardrails",
  "Get active correction guardrails. Returns patterns that have reached guardrail or critical level, with descriptions and occurrence counts.",
  {},
  async () => {
    try {
      const tracker = readJsonFile<CorrectionTracker>(
        dataPath("correction-tracker.json"),
        { patterns: {} }
      );

      const guardrails: Array<{
        pattern: string;
        description: string;
        level: string;
        occurrences: number;
        last_occurrence: string | null;
        escalated_at: string | null;
      }> = [];

      for (const [key, pattern] of Object.entries(tracker.patterns)) {
        if (
          (pattern.level === "guardrail" || pattern.level === "critical") &&
          !pattern.resolved
        ) {
          const lastOccurrence =
            pattern.occurrences.length > 0
              ? pattern.occurrences[pattern.occurrences.length - 1].date
              : null;

          guardrails.push({
            pattern: key,
            description: pattern.description,
            level: pattern.level,
            occurrences: pattern.occurrences.length,
            last_occurrence: lastOccurrence,
            escalated_at: pattern.escalated_at,
          });
        }
      }

      // Sort: critical first, then by occurrence count
      guardrails.sort((a, b) => {
        if (a.level !== b.level) {
          return a.level === "critical" ? -1 : 1;
        }
        return b.occurrences - a.occurrences;
      });

      if (guardrails.length === 0) {
        return {
          content: [
            {
              type: "text" as const,
              text: "No active guardrails. All correction patterns are at observation level or resolved.",
            },
          ],
        };
      }

      return {
        content: [
          {
            type: "text" as const,
            text: JSON.stringify({ active_guardrails: guardrails }, null, 2),
          },
        ],
      };
    } catch (err) {
      const message = err instanceof Error ? err.message : String(err);
      return {
        content: [{ type: "text" as const, text: `Failed to get guardrails: ${message}` }],
        isError: true,
      };
    }
  }
);

// ---------------------------------------------------------------------------
// Resource: scribe://config
// ---------------------------------------------------------------------------

server.resource(
  "config",
  "scribe://config",
  { description: "The user's Scribe configuration file (config.json)" },
  async () => {
    const config = readJsonFile(dataPath("config.json"), {});
    return {
      contents: [
        {
          uri: "scribe://config",
          mimeType: "application/json",
          text: JSON.stringify(config, null, 2),
        },
      ],
    };
  }
);

// ---------------------------------------------------------------------------
// Resource: scribe://observer-prompt
// ---------------------------------------------------------------------------

server.resource(
  "observer-prompt",
  "scribe://observer-prompt",
  { description: "The Scribe observer prompt — core observation intelligence" },
  async () => {
    const promptPath = findCoreFile("observer-prompt.md");
    const text = promptPath ? readTextFile(promptPath) : null;
    return {
      contents: [
        {
          uri: "scribe://observer-prompt",
          mimeType: "text/markdown",
          text: text || "Observer prompt not found. Ensure the Scribe core/ directory is accessible.",
        },
      ],
    };
  }
);

// ---------------------------------------------------------------------------
// Resource: scribe://reader-prompt
// ---------------------------------------------------------------------------

server.resource(
  "reader-prompt",
  "scribe://reader-prompt",
  { description: "The Scribe reader prompt — reflection and analysis intelligence" },
  async () => {
    const promptPath = findCoreFile("reader-prompt.md");
    const text = promptPath ? readTextFile(promptPath) : null;
    return {
      contents: [
        {
          uri: "scribe://reader-prompt",
          mimeType: "text/markdown",
          text: text || "Reader prompt not found. Ensure the Scribe core/ directory is accessible.",
        },
      ],
    };
  }
);

// ---------------------------------------------------------------------------
// 13. Start Server
// ---------------------------------------------------------------------------

async function main(): Promise<void> {
  // Ensure the data directory exists
  ensureDir(DATA_DIR);
  ensureDir(dataPath("entries"));
  ensureDir(dataPath("inbox"));
  ensureDir(dataPath("outbox"));
  ensureDir(dataPath("revisions"));

  const transport = new StdioServerTransport();
  await server.connect(transport);
}

main().catch((err) => {
  console.error("Scribe MCP server failed to start:", err);
  process.exit(1);
});
