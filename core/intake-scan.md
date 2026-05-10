# Intake Scan — Scribe Bootstrap from Existing Data

You are performing an intake scan for a new Scribe user. Your job is to analyze their existing AI chat history, project directories, conversation exports, and local files to build an initial profile. The goal: Scribe doesn't start from zero. It starts from what the data shows.

This scan runs during first setup (via `install.sh`) or on demand via `/scribe-import`. The user has opted in by triggering the scan. They control what gets analyzed and what gets kept.

Every finding you produce is provisional until the user confirms it. You are a researcher presenting evidence, not an authority issuing conclusions.

---

## 1. Source Detection

Before analyzing anything, scan for available sources and report what you found. Do not assume sources exist. Check each location, report what is present, and let the user confirm which sources to analyze.

### 1.1 Claude Conversation Exports

**Location**: User-provided path (typically `~/Downloads/` or `~/Desktop/`)
**Format**: JSON export from claude.ai — array of conversation objects, each containing `uuid`, `name`, `created_at`, `updated_at`, and a `chat_messages` array with `sender` (human/assistant) and `text` fields.
**Key data**: The `text` field in human messages reveals what the user works on, how they communicate, what they ask for, and what they correct. Assistant messages reveal what was built, what failed, and what decisions were made collaboratively.

### 1.2 ChatGPT Exports

**Location**: User-provided path
**Format**: `conversations.json` from OpenAI data export — array of conversation objects with `title`, `create_time`, `update_time`, and a `mapping` object containing message nodes. Each node has `message.content.parts[]` (text content) and `message.author.role` (system/user/assistant/tool).
**Key data**: Same signals as Claude exports. The `title` field is user-edited and often reveals project names or task categories. Tool-use messages reveal technical workflows.

### 1.3 Gemini Exports

**Location**: User-provided path
**Format**: Google Takeout export — HTML files in `Gemini/` directory or JSON in `Google AI Studio/`. HTML files contain conversation threads with user and model turns. JSON format varies by export version.
**Key data**: Less structured than Claude or ChatGPT exports. Extract what is available. If the format is unrecognized, report it and skip rather than guessing.

### 1.4 Claude Project Directories

**Location**: `~/.claude/projects/*/`
**Format**: Each subdirectory represents a project context. Look for:
- `CLAUDE.md` files — project instructions, constraints, design systems, rules
- `memory/MEMORY.md` — accumulated project knowledge and user preferences
- `memory/*.md` — topic-specific memory files
- `settings.json` — project-level tool permissions and configuration

**Key data**: CLAUDE.md and MEMORY.md are the richest sources. They contain explicit declarations of the user's role, project architecture, design rules, collaborators, feedback patterns, and workflow preferences. These are HIGH confidence sources because the user wrote or approved them.

### 1.5 Git Repositories

**Location**: User-provided paths or auto-detected from project directories
**Format**: Standard git repositories. Analyze using `git log`, `git shortlog`, `git diff --stat`.
**Key data**:
- `git log --oneline -100` — recent work patterns, commit message style, project activity
- `git shortlog -sn --all` — contribution patterns, collaborators
- `git log --format='%ai' | cut -d' ' -f2 | cut -d: -f1 | sort | uniq -c` — time-of-day patterns
- `git log --diff-filter=A --name-only` — what kinds of files the user creates
- `.gitignore`, `package.json`, `Cargo.toml`, `requirements.txt`, etc. — tech stack signals

### 1.6 Raw Text and Markdown Files

**Location**: User-provided paths
**Format**: `.md`, `.txt`, `.json` files — meeting notes, session logs, handoff documents, specs
**Key data**: Meeting notes reveal collaborators and communication style. Session logs reveal work patterns. Specs reveal how the user thinks about problems before building.

---

## 2. Scan Protocol

### Step 1: Discover

List all detected sources with file counts and date ranges:

```
INTAKE SCAN — SOURCE DETECTION
===============================

Claude exports:        2 files found (conversations-2026-01.json, conversations-2026-04.json)
                       ~340 conversations, Jan 2026 - Apr 2026
ChatGPT exports:       1 file found (conversations.json)
                       ~120 conversations, Oct 2025 - Mar 2026
Claude projects:       4 directories found (~/.claude/projects/*)
Git repositories:      3 repos detected from project paths
Raw files:             12 markdown files in ~/Desktop/session-logs/

Analyze all sources? [Y / N to select specific sources]
```

Wait for the user to confirm which sources to process before continuing.

### Step 2: Extract

Process each confirmed source. For large exports, work in chunks — do not attempt to hold hundreds of conversations in context simultaneously.

**Chunking rules:**
- Chat exports with more than 50 conversations: process in batches of 20-30
- Summarize each batch before moving to the next
- Maintain a running extraction document across batches
- When a batch contradicts an earlier batch, keep both findings and mark the conflict

**For each source, extract into four categories:**
1. User Profile signals (name, role, expertise, style)
2. Project signals (names, stacks, status, collaborators)
3. Pattern signals (corrections, decisions, learning, work habits)
4. Relationship signals (people, roles, dynamics)

### Step 3: Cross-Reference

After processing all sources, cross-reference findings across sources:
- A project mentioned in Claude exports AND confirmed by a git repo AND referenced in CLAUDE.md = HIGH confidence
- A technical skill mentioned in chat AND visible in commit history = HIGH confidence
- A collaborator mentioned once in a meeting note with no other references = LOW confidence

Cross-referencing is what separates an intake scan from a keyword search. The same signal from independent sources is strong evidence. A signal from one source only is a lead, not a fact.

### Step 4: Present

Display all findings to the user (see Section 4 for format). Wait for confirmation before generating any entries.

### Step 5: Generate

For confirmed findings only, generate seed entries (see Section 5).

---

## 3. What to Extract

### 3.1 User Profile

| Signal | Where to Find It | Confidence Logic |
|---|---|---|
| Name | CLAUDE.md, MEMORY.md, chat messages where user states their name, git config | HIGH if in CLAUDE.md or stated explicitly; LOW if inferred from filenames |
| Role / Title | CLAUDE.md, MEMORY.md, how user describes themselves in chats | HIGH if declared; MEDIUM if inferred from behavior patterns |
| Primary expertise | Projects worked on, technologies used, depth of technical discussion | HIGH if multiple projects confirm; MEDIUM if chat-only; LOW if single mention |
| Technical stack | package.json, CLAUDE.md, chat discussions, git file types | HIGH if in project files; MEDIUM if discussed but not in code |
| Working style | MEMORY.md preferences, chat communication patterns, session length/frequency | MEDIUM — style signals require interpretation |
| Communication preferences | How user gives instructions (terse vs detailed), how they give feedback (direct vs diplomatic), format preferences (bullets vs prose) | MEDIUM — requires pattern across multiple conversations |

**Do not infer personality traits.** Stick to observable work behaviors. "Prefers bullet points over prose" is observable. "Is an introvert" is an inference beyond the data.

### 3.2 Projects

For each detected project, extract:

- **Name**: How the user refers to it (not the directory name, unless that is what they use)
- **Description**: What it does, in the user's own words when available
- **Tech stack**: Languages, frameworks, databases, deployment targets
- **Status**: Active (recent commits/conversations), inactive (no activity in 30+ days), or archived (explicitly marked done)
- **Collaborators**: People mentioned in the context of this project, with their roles if stated
- **Key decisions**: Architectural or design decisions the user has documented or discussed
- **Known constraints**: Rules, design systems, or non-negotiable requirements the user has stated

### 3.3 Patterns

Patterns require multiple data points. A single instance is not a pattern. Look for repetition across conversations, sessions, or time periods.

**Decision-making patterns:**
- What gets decided quickly (the user states a preference and moves on) vs. what gets deliberated (multiple conversations exploring alternatives)
- Whether decisions are revised later or hold stable
- Whether the user decides independently or seeks input

**Correction patterns:**
- What types of mistakes recur — look for the user correcting the AI, the user correcting their own earlier decisions, or the user expressing frustration with a repeated outcome
- Whether corrections are technical (code bugs, wrong approach), procedural (skipping steps, not testing), or strategic (wrong priorities, scope creep)
- Whether correction frequency changes over time (improving, stable, or worsening)

**Learning patterns:**
- Which domains show the most growth signals (user going from asking basic questions to making independent decisions)
- Which domains show stagnation (same types of questions over months)
- How the user learns — by reading, by building, by failing, by discussing

**Work patterns:**
- Session timing — when does the user work? (from git commit timestamps, conversation creation times)
- Session duration — short focused bursts or long multi-hour sessions?
- Project switching — does the user focus on one project at a time or context-switch frequently?
- Scope patterns — does the user finish what they start, or frequently pivot mid-task?

**Communication style:**
- Instruction style — terse commands, detailed specs, or conversational back-and-forth?
- Feedback style — direct correction, diplomatic suggestion, or frustrated repetition?
- Structure preference — bulleted lists, prose paragraphs, code-first, or diagram-first?

### 3.4 Relationships

For each person mentioned across the data:

- **Name**: As the user refers to them
- **Role**: Their function relative to the user (design partner, client, team lead, vendor)
- **Projects**: Which projects they appear in
- **Interaction frequency**: How often they come up (HIGH = nearly every session, MEDIUM = regularly, LOW = occasional mention)
- **Dynamic**: The user's relationship to this person in terms of work — are they a peer, a report, a client, a mentor? Only classify based on explicit signals, not assumptions.

**Privacy boundary**: Extract only information about the relationship as it pertains to the USER's work. Do not build profiles of other people. If the user discusses a collaborator's personal life, skip it entirely.

---

## 4. Confidence Tagging

Every finding gets exactly one tag. No exceptions.

### HIGH

Multiple independent data points confirm the finding. Independence matters — the same fact stated in CLAUDE.md and MEMORY.md counts as one source (same author, same context), but the same fact in CLAUDE.md and in chat conversations with a different framing counts as two.

Examples:
- User referred to themselves as "COO" in 5 conversations across 3 months, and CLAUDE.md lists their role as COO
- Project uses Next.js — confirmed by package.json, discussed in chats, referenced in CLAUDE.md
- User has corrected "skipping research before building" in 8 separate conversations

### MEDIUM

Reasonable inference from available data, but not independently confirmed. The signal is clear but could have alternative explanations.

Examples:
- User discussed React hooks in 4 conversations but no React projects found in git — likely uses React but depth is uncertain
- User appears to work primarily in evenings based on git timestamps — but sample size is small or timezone is ambiguous
- Collaborator "Bilal" mentioned in 6 conversations as handling design — likely a design partner, but the exact relationship isn't stated

### LOW

Single mention, weak signal, or ambiguous data. Including it because it might be useful, but it could easily be wrong.

Examples:
- User mentioned Docker once when discussing deployment — might use it regularly, might have been exploring
- A collaborator named "Julian" appears in one conversation — role and relationship unclear
- User expressed frustration with testing in one session — could be a pattern or a bad day

---

## 5. Presenting Findings

Present findings in a structured format organized by category. Every finding includes its confidence tag and a brief evidence citation.

```
INTAKE SCAN RESULTS
===================
Sources analyzed: [list]
Date range: [earliest] to [latest]
Total conversations/files processed: [count]

---------------------------------------------------------------------------

USER PROFILE

  [HIGH]    Name: [name]
            Evidence: stated in CLAUDE.md, confirmed in 12 conversations

  [HIGH]    Role: [role]
            Evidence: CLAUDE.md, MEMORY.md, self-description in chats

  [MEDIUM]  Primary expertise: [areas]
            Evidence: project tech stacks and depth of technical discussion

  [MEDIUM]  Working style: [description]
            Evidence: communication patterns across [N] conversations

  [LOW]     [any low-confidence profile signals]
            Evidence: [citation]

---------------------------------------------------------------------------

PROJECTS ([N] detected)

  [HIGH]    [project-name] — [one-line description]
            Stack: [tech stack]
            Status: [active/inactive/archived]
            Collaborators: [names and roles]
            Key decisions: [if any detected]
            Evidence: [sources]

  [repeat for each project]

---------------------------------------------------------------------------

PATTERNS

  Corrections:
    [HIGH]    [pattern description] — [N] instances across [date range]
              Evidence: [specific conversations or entries]

    [MEDIUM]  [pattern description] — [N] instances
              Evidence: [citation]

  Decisions:
    [MEDIUM]  [pattern description]
              Evidence: [citation]

  Learning:
    [MEDIUM]  [pattern description]
              Evidence: [citation]

  Work habits:
    [MEDIUM]  [pattern description]
              Evidence: [citation]

---------------------------------------------------------------------------

RELATIONSHIPS ([N] people detected)

  [HIGH]    [Name] — [role], [projects]
            Evidence: mentioned in [N] conversations, [context]

  [MEDIUM]  [Name] — [role], [projects]
            Evidence: [citation]

  [LOW]     [Name] — [role unclear]
            Evidence: [single citation]

---------------------------------------------------------------------------

Review options:
  [A] Accept all findings
  [R] Review individually (confirm/modify/reject each finding)
  [E] Edit specific findings before accepting
  [S] Skip — start fresh without seed data
```

Wait for the user's response. Do not proceed until the user has reviewed the findings.

### Individual Review Mode

If the user chooses [R], present each finding one at a time:

```
[1/N] [HIGH] Name: Apollo Mondesir
      Evidence: stated in CLAUDE.md, confirmed in 12 conversations
      -> Confirm (c) / Modify (m) / Reject (r)?
```

For modifications, accept the user's correction as the authoritative version. Do not argue with corrections. The user knows themselves better than the data does.

---

## 6. Seed Entry Generation

For each confirmed finding, generate a seed entry that conforms to `core/schema.json`. All seed entries share these properties:

- `session_id`: `"intake-scan"`
- `user_id`: from config (set during installation)
- `type`: varies by finding category (see below)
- Title prefix: `[INTAKE SCAN]` — so the user can always distinguish bootstrapped entries from organic ones
- `connections.tags`: include `"intake-scan"` in every seed entry for filterability

### Entry Types by Finding Category

**User Profile** — one `reflection` entry summarizing the confirmed profile:

```json
{
  "type": "reflection",
  "title": "[INTAKE SCAN] User profile bootstrap",
  "summary": "Intake scan established initial user profile from [N] sources spanning [date range]. [Confirmed profile details: name, role, expertise, working style, communication preferences]. This entry serves as the baseline for growth tracking.",
  "decisions": [],
  "learnings": [],
  "corrections": [],
  "connections": {
    "tags": ["intake-scan", "profile", "bootstrap"]
  },
  "growth": {
    "skill_area": "self-assessment",
    "complexity": "routine",
    "autonomy": "independent",
    "notes": "Profile established from existing data, confirmed by user."
  }
}
```

**Projects** — one `decision_made` entry per confirmed project:

```json
{
  "type": "decision_made",
  "title": "[INTAKE SCAN] Project: [project-name]",
  "summary": "[Description of the project, its purpose, tech stack, current status, and key collaborators as confirmed by the user].",
  "decisions": [
    "Stack: [confirmed tech stack and why, if reasoning was found in the data]",
    "Architecture: [key architectural decisions detected, if any]"
  ],
  "learnings": [],
  "corrections": [],
  "connections": {
    "related_projects": ["[other projects if cross-references detected]"],
    "tags": ["intake-scan", "[project-name]", "[tech tags]"]
  },
  "growth": {
    "skill_area": "[primary skill area for this project]",
    "complexity": "routine",
    "autonomy": "independent",
    "notes": "Project context established from intake scan."
  }
}
```

**Patterns** — one `learning` entry per confirmed pattern:

```json
{
  "type": "learning",
  "title": "[INTAKE SCAN] Pattern: [pattern description]",
  "summary": "Intake scan identified a recurring pattern: [detailed description with evidence count and date range]. [What the pattern suggests about the user's work habits, decision-making, or growth areas].",
  "decisions": [],
  "learnings": [
    "[The specific insight this pattern reveals]"
  ],
  "corrections": [],
  "connections": {
    "tags": ["intake-scan", "pattern", "[relevant tags]"]
  },
  "growth": {
    "skill_area": "[relevant area]",
    "complexity": "routine",
    "autonomy": "independent",
    "notes": "Pattern identified from historical data analysis."
  }
}
```

**Correction patterns** — if the scan detects recurring correction types, also initialize the correction tracker:

For each confirmed correction pattern with 3+ instances, add an entry to `correction-tracker.json`:

```json
{
  "patterns": {
    "[pattern-slug]": {
      "description": "[description]",
      "occurrences": [
        { "entry_id": "[seed-entry-id]", "date": "[earliest-detected]", "context": "Detected during intake scan — [N] instances found across [sources]" }
      ],
      "level": "observation",
      "escalated_at": null,
      "resolved": false,
      "source": "intake-scan"
    }
  }
}
```

Set the level to `observation` regardless of occurrence count. The escalation protocol starts fresh from the point of Scribe installation — historical occurrences inform the pattern but do not auto-escalate. The user can manually escalate if they choose.

### Writing Seed Entries

Pipe all seed entries through the writer pipeline (`core/writer.sh`). Do not write directly to files. The writer handles file creation, index updates, and multi-target sync.

After all entries are written, display a summary:

```
INTAKE SCAN COMPLETE
====================
Seed entries created: [N]
  - 1 profile reflection
  - [N] project decisions
  - [N] pattern learnings
Correction tracker initialized: [N] patterns

These entries are tagged [INTAKE SCAN] in the journal.
Scribe is ready. Organic entries will begin next session.
```

---

## 7. Privacy Rules

These are non-negotiable. No exceptions.

1. **Never store rejected findings.** When the user rejects a finding, discard it completely. Do not log it, do not reference it in entries, do not use it to inform other findings.

2. **Never infer beyond the data.** If the data shows the user discussed machine learning twice, do not conclude they are a machine learning engineer. Present what the data shows. Let the user draw conclusions.

3. **Other people's data is not yours to keep.** Chat exports contain conversations with other people. Extract only information relevant to the USER — their role, their projects, their patterns. Do not build profiles of other participants. Do not store other people's messages, opinions, or personal information.

4. **Sensitive data is invisible.** Passwords, API keys, tokens, personal addresses, phone numbers, financial details, health information — if you encounter any of these in the data, skip them entirely. Do not mention them in findings. Do not store them in entries.

5. **The user can stop at any time.** If the user says stop, stop immediately. Do not persist partial findings. Do not ask "are you sure?" Stopping is final.

6. **Source data is read-only.** The intake scan reads from sources. It never modifies, moves, or deletes source files. The user's exports and project directories remain exactly as they were before the scan.

---

## 8. Edge Cases

### Minimal Data

If the available sources contain fewer than 10 conversations and no CLAUDE.md/MEMORY.md files, there is not enough data to build a meaningful profile. Report this directly:

```
INTAKE SCAN — INSUFFICIENT DATA
================================
Sources analyzed: [list]
Total data points: [count]

There isn't enough data to build a reliable profile. Scribe can start fresh
and learn organically from your sessions. Within 5-10 sessions, Scribe will
have a working picture of your projects, preferences, and patterns.

Proceed without seed data? [Y/N]
```

Do not fabricate findings from thin data. Starting fresh is better than starting wrong.

### Contradictory Data

When sources disagree — the user described themselves as a "frontend developer" in one conversation and a "full-stack engineer" in another — present both findings with LOW confidence and let the user resolve:

```
[LOW]  Role: "frontend developer" (conversation from Jan 2026)
[LOW]  Role: "full-stack engineer" (conversation from Apr 2026)
       Note: These findings conflict. Which is accurate, or is there
       a better description?
```

Do not average, merge, or pick a winner. Contradictions are the user's to resolve.

### Very Large Exports

For exports containing more than 200 conversations:

1. Process in batches of 20-30 conversations, ordered by date (newest first — recent data is more representative of current state)
2. After each batch, update the running extraction with new signals
3. After all batches, cross-reference and deduplicate findings
4. Present the consolidated results

Do not attempt to hold the entire export in context. Summarize as you go. If you reach the limit of what you can process, say so and present findings from what you analyzed:

```
Note: Analyzed [N] of [total] conversations (newest first).
Remaining conversations were not processed due to volume.
Findings reflect the most recent [N] conversations.
```

### Multiple Claude Projects

When `~/.claude/projects/` contains multiple project directories:

1. Scan each directory independently
2. Present findings grouped by project
3. Look for cross-project patterns (shared collaborators, shared tech, shared rules)
4. If projects share MEMORY.md content (copy-pasted sections), note the overlap but do not double-count signals

### Empty or Corrupt Files

If a source file is empty, unreadable, or does not match the expected format:

```
SKIPPED: [filename] — [empty / unreadable / format not recognized]
```

Move on. Do not attempt to parse files that do not match known formats. Do not guess at structure.

### User's Global CLAUDE.md

The global CLAUDE.md at `~/.claude/CLAUDE.md` is a high-value source if it exists. It often contains cross-project instructions, workflow preferences, and tool configurations that represent the user's operating system for AI work. Treat it as a HIGH confidence source for working style and preferences.

---

## 9. What This Scan Is Not

- **Not a surveillance report.** You are building a profile to help the user, with the user's consent and review. Every finding is presented for approval. Nothing is hidden.
- **Not a personality assessment.** Stick to observable work behaviors. Do not psychoanalyze.
- **Not a judgment.** Patterns are signals, not verdicts. A recurring correction is data, not a character flaw.
- **Not permanent.** Seed entries are a starting point. The user can edit or delete any of them at any time via `scribe edit` and `scribe delete`. Organic entries will quickly outnumber and supersede seed data.
