# Scribe — Design Document

**Version**: 0.1.0 (Design Phase)
**Author**: Apollo Mondesir / Rocksteady Consulting
**Repository**: github.com/SpaceAM23/scribe (private)

---

## 1. What Scribe Is

A silent AI session journal that works across Claude Code, Claude Desktop, and Claude Web App. It observes sessions, records decisions, learnings, corrections, and growth patterns, tracks behavioral signals, and provides honest feedback on demand.

Unlike a chatbot's built-in memory, Scribe is **longitudinal** — it builds a picture over weeks and months, identifies patterns across sessions, gives evidence-based reflection when asked, and evolves to become a better observer for each specific user.

Scribe never interrupts. Never flatters. Tells you what the data shows.

---

## 2. Architecture

### 2.1 Two-Location Separation

The skill (engine) and user data (journal) live in separate locations:

```
~/.claude/scribe/              <- SKILL INSTALLATION (replaceable)
  core/                        <- Prompts, schema, behavioral library
  adapters/                    <- Platform-specific I/O
  scripts/                     <- install.sh, update logic
  templates/                   <- Config templates, onboarding

~/Desktop/Scribe/              <- USER DATA (permanent, never touched by updates)
  config.json                  <- User preferences, storage targets, skill registry
  entries/                     <- Individual JSON entry files
  journal.jsonl                <- Append-only JSONL index (THE source of truth)
  index.json                   <- Stats, tag cloud, growth summary (derived)
  seen-hashes.txt              <- Content-hash dedup ledger (derived)
  session-counter.json         <- Session numbering
  correction-tracker.json      <- Correction frequency per pattern (derived)
  canonical/                   <- Taxonomy: projects.json (registry + aliases),
                                  correction-patterns.json (vocabulary),
                                  taxonomy-suggestions.jsonl (pending mints)
  briefs/                      <- Per-project session briefs + _portfolio.md
  sync-queue.jsonl             <- Failed Supabase writes awaiting reconcile
  sync-dead-letter.jsonl       <- Permanently-failed sync entries (annotated)
  normalizations.jsonl         <- Every write-time repair, logged
  duplicates.jsonl             <- Refused duplicates (full payload preserved)
  tuning.json                  <- User-approved self-optimization config
  inbox/                       <- Received Scribe packets
  outbox/                      <- Sent Scribe packets (archive)
  revisions/                   <- Backup-before-delete (30-day retention)
```

Everything except `journal.jsonl` and `entries/` is either configuration or *derived state* — `core/doctor.py` can regenerate index.json, seen-hashes.txt, and (via the journal) the correction tracker at any time.

**pointer.json** (in the skill directory) points to the data directory:
```json
{
  "data_path": "~/Desktop/Scribe",
  "created": "2026-05-10T00:00:00Z"
}
```

Why: `scribe update` pulls the latest skill from GitHub without touching user data. The skill is the engine — replaceable, version-controlled. The journal is the user's data — portable, durable, theirs.

### 2.2 One Core, Three Adapters

```
core/
  observer-prompt.md           <- Main observation intelligence
  reader-prompt.md             <- Reflection/analysis intelligence
  behavioral-library.md        <- Full psychological/sociological framework
  schema.json                  <- Entry schema v2 (additive-only)
  packet-schema.json           <- Scribe-to-Scribe packet format
  correction-escalation.md     <- Escalation protocol
  writer.sh                    <- Multi-target write pipeline (locked, deduped)
  track-corrections.py         <- Vocabulary-driven correction tracker
  brief.py                     <- Session-brief compiler (the read path)
  doctor.py                    <- Derived-state check/fix from the journal
  taxonomy.py                  <- Deliberate category minting + suggestions
  reconcile.sh                 <- Sync-queue replay with dead-letter handling
  heal.py / heal-trend.py      <- Self-healing analysis
  librarian.py                 <- NEXUS promotion engine

adapters/
  claude-code/                 <- Bash scripts, slash commands, status line
  claude-desktop/              <- MCP server (Node.js)
  claude-web/                  <- Project instructions + Drive MCP config
```

All three adapters share the same core intelligence. The adapter handles I/O; the core handles thinking.

### 2.3 Multi-Target Writer Pipeline

Entry JSON flows through a single hardened door (`core/writer.sh`). The governing principle is **no data loss**: an entry is repaired and normalized, never rejected (the only hard failures are unparseable JSON and missing required fields).

```
Entry JSON
  -> validate JSON + required fields
  -> repair invalid id/timestamp at the door (logged to normalizations.jsonl)
  -> resolve project aliases (canonical/projects.json)
  -> normalize unknown project -> "meta"   + queue taxonomy suggestion
  -> normalize invalid enums from schema.json (never hardcoded)
  -> normalize unknown type -> nearest core type + queue taxonomy suggestion
  == ACQUIRE WRITER LOCK (mkdir lock, stale-lock stealing) ==
  -> content-hash dedup check (duplicates -> duplicates.jsonl, full payload)
  -> write local file (entries/<id>.json)              [if enabled]
  -> append to journal.jsonl
  -> record content hash (ONLY after the append succeeded)
  -> write to Supabase; on failure queue to sync-queue.jsonl
  -> write Google Drive marker                         [if enabled]
  -> update index.json stats (atomic tmp+rename; corrupt copy quarantined)
  -> update correction-tracker.json via track-corrections.py (stdin-piped)
  == RELEASE WRITER LOCK ==
  -> display receipt to user
  -> post-write hook: regenerate briefs/<project>.md (non-fatal)
```

Each target fails independently — a Supabase outage doesn't block local writes; the failed insert is queued and `core/reconcile.sh` replays it later (poison entries dead-letter instead of wedging the queue). Local files are always the primary source of truth when available.

Concurrency: parallel writers are serialized by a bash-3.2-safe mkdir lock in the data dir (`.writer.lock/`), with the holder pid recorded for stale-lock recovery. On lock timeout the writer proceeds *unlocked* rather than dropping the entry — a rare index race is repairable by the doctor; a dropped entry is not.

### 2.3b Derived State and the Doctor

`journal.jsonl` is the source of truth; index.json, seen-hashes.txt, and the correction tracker are derived. `core/doctor.py --check` verifies all derived state against the journal (plus id well-formedness/uniqueness); `--fix` rebuilds it atomically while holding the same writer lock, and aborts rather than racing a live writer. Repairs are logged to `doctor-repairs-<date>.json`.

### 2.3c The Read Path: Session Briefs

`core/brief.py` compiles `briefs/<project>.md` (hard-capped at 60 lines: LANDMINES, KNOWLEDGE, RECENT, OPEN THREADS, meta budget) and `briefs/_portfolio.md` (per-project rollup, pending taxonomy suggestions, doctor status). Agents read the brief at session start instead of grepping the raw journal. The writer regenerates the touched project's brief after every write.

### 2.3d Taxonomy

Categories are minted deliberately, never automatically. The writer queues unknown projects/types to `canonical/taxonomy-suggestions.jsonl`; `core/taxonomy.py` lists suggestions and mints projects (canonical/projects.json), entry types (DATA_DIR schema.json enum, seeded from core), and correction patterns (canonical/correction-patterns.json — inserted before the catch-all, since matcher order is semantic). Every mutation backs up the target file first and validates the JSON after writing.

### 2.4 Storage Matrix

| Platform | Local Files | Google Drive | Supabase |
|---|---|---|---|
| Claude Code | Primary | Optional | Optional |
| Claude Desktop | Primary | Optional | Optional |
| Claude Web App | N/A | Primary | Optional |

Users choose their combination during setup. Local is always primary when available (Code and Desktop). Web App users must use Drive or Supabase since they lack filesystem access.

---

## 3. Onboarding

### 3.1 Installation

```bash
git clone https://github.com/SpaceAM23/scribe.git ~/.claude/scribe
cd ~/.claude/scribe && ./install.sh
```

The installer:
1. Creates the data directory (user chooses location, default `~/Desktop/Scribe/`)
2. Creates `pointer.json` linking skill -> data
3. Adds Scribe directives to the user's `CLAUDE.md`
4. Launches the intake scan (optional)
5. Walks through configuration (storage, behavioral tracking, encryption, status line)
6. Scans for installed skills and populates skill registry

### 3.2 Intake Scan

On first run, Scribe offers to scan the user's existing context:

- Exported chat history from other AI tools (ChatGPT, Gemini, etc.)
- Existing Claude project directories
- Past conversation exports

The scan uses deep analysis to identify:
- User's role and expertise areas
- Projects they work on
- Patterns in their work
- Technical stack and preferences
- Collaboration relationships

**Verification is mandatory.** Every finding gets a confidence tag:
- **HIGH** — multiple data points confirm this
- **MEDIUM** — reasonable inference from available data
- **LOW** — single mention or weak signal

The user reviews all findings before anything becomes a seed entry. Nothing is assumed. Nothing is fabricated.

### 3.3 Configuration (`config.json`)

```json
{
  "scribe_version": "0.1.0",
  "schema_version": 1,
  "user_id": "user-uuid",
  "user_profile": {
    "name": "",
    "role": "",
    "expertise": [],
    "working_style": "",
    "communication_preferences": {}
  },
  "data_path": "~/Desktop/Scribe",
  "projects": {},
  "storage": {
    "local": { "enabled": true },
    "google_drive": { "enabled": false, "folder_id": null },
    "supabase": {
      "enabled": false,
      "url": null,
      "anon_key": null,
      "db_connection": null
    }
  },
  "behavioral_tracking": false,
  "encryption": {
    "enabled": false,
    "algorithm": "AES-256-GCM",
    "key_derivation": "PBKDF2"
  },
  "status_line": {
    "enabled": true,
    "metrics": ["session_count", "total_count", "lrn", "cor", "dec", "feat", "bug"]
  },
  "transparency": "detailed",
  "scribe_to_scribe": {
    "enabled": true,
    "auto_accept": false,
    "share_defaults": {
      "include_role": true,
      "include_working_style": true,
      "include_expertise": true,
      "include_communication_prefs": true
    }
  },
  "skill_integrations": {}
}
```

---

## 4. Entry Schema

### 4.1 Required Fields

| Field | Type | Purpose |
|---|---|---|
| `id` | UUID v4 | Unique entry identifier |
| `timestamp` | ISO 8601 | When the entry was created |
| `session_id` | string | Groups entries within a session |
| `user_id` | string | Owner identifier (for team/packet features) |
| `project` | string | Which project this entry belongs to (user-defined, not hardcoded) |
| `type` | string | Entry type (extensible enum with core set) |
| `title` | string | Short descriptive title (max 120 chars) |
| `summary` | string | What happened and why it matters (no char limit) |

### 4.2 Optional Fields

| Field | Type | Purpose |
|---|---|---|
| `decisions[]` | array of strings | Choices made, alternatives considered, reasoning |
| `learnings[]` | array of strings | Genuinely new understanding gained |
| `corrections[]` | array of strings | Mistakes — unvarnished, naming cause and fix |
| `metrics` | object | `files_changed`, `lines_added`, `lines_removed`, `duration_minutes`, `agents_dispatched`, `version_shipped` |
| `connections` | object | `builds_on[]`, `related_projects[]`, `tags[]` |
| `growth` | object | `skill_area`, `complexity`, `autonomy`, `notes` |
| `behavioral` | object | (opt-in) `drive_state`, `energy`, `triggers[]`, `avoidance_signals[]`, `language_markers[]`, `cognitive_load`, `pattern_flags[]`, `notes` |
| `learning_story` | object | (for packets) `attempts[]`, `thinking`, `outcome` |

### 4.3 Schema Rules

- **Additive only**: new fields can be added, existing fields are never removed or renamed
- **schema_version**: integer version in the schema; old entries remain valid forever
- **User-defined projects**: the `project` field is not a hardcoded enum — it's validated against the user's config
- **User-defined types**: core types provided, users can add custom types
- **Encrypted fields**: when encryption is enabled, content fields (summary, decisions, learnings, corrections, behavioral notes) are encrypted; metadata fields (id, timestamp, project, type) stay readable so counters and status line still work

---

## 5. Behavioral Library

### 5.1 Philosophy

Scribe internalizes a comprehensive psychological and sociological knowledge base as part of the core skill. This is NOT a database the user sees — it's the lens through which Scribe observes.

The library covers:
- **Cognitive patterns**: decision-making biases, information processing styles, learning preferences, attention and focus models
- **Motivational patterns**: intrinsic/extrinsic drivers, goal orientation, persistence profiles, delay discounting
- **Work patterns**: flow states, context-switching costs, energy cycles, productivity rhythms, approach vs. avoidance
- **Interpersonal patterns**: communication styles, conflict approaches, leadership tendencies, collaboration dynamics
- **Growth patterns**: learning curves, plateau signals, comfort zone boundaries, breakthrough indicators, Dunning-Kruger awareness

### 5.2 How It Works

The full library is always loaded. Scribe observes through ALL lenses simultaneously but only surfaces what's relevant. It doesn't select frameworks per user — it starts with everything and lets observation determine what matters.

### 5.3 Opt-In

Behavioral tracking is opt-in during setup and can be toggled anytime via `/scribe-config`. When disabled, Scribe still records decisions, learnings, and corrections — it just doesn't write the `behavioral` field to entries.

---

## 6. Observation and Writing

### 6.1 When Scribe Writes

- Session open/close
- Feature shipped or bug fixed
- Architectural decision with reasoning
- Learning (genuinely new understanding only)
- Correction (unvarnished — name the mistake, cause, and fix)
- Pattern detected that matches known correction categories
- Guardrail violation (correction pattern about to recur)

### 6.2 Honesty Rules (Non-Negotiable)

1. No inflated complexity — routine work is routine
2. No softened corrections — name the mistake directly
3. Flag repeated patterns — if the same correction appears 3x, say so
4. Growth notes must be specific — not "improved at debugging" but "identified root cause via log analysis instead of shotgun fixes"
5. Evidence over opinion — cite specific entries
6. Patterns over individual events — a single mistake is noise; three is signal

### 6.3 Transparency

Every entry produces a receipt shown to the user. Receipts include:
- What was saved (type, title, key details)
- A tracking purpose note ("This helps identify patterns in your architectural decisions")

Receipts are **detailed early** (first ~5 sessions), **concise later**, but **never silent**. Transparency is permanent, not a training-wheels phase that drops off.

---

## 7. Correction Escalation Protocol

The core intelligence gap: logging a mistake and preventing its recurrence are two different things. Corrections logged in a journal don't automatically change behavior. Scribe bridges this gap through systematic escalation.

### 7.1 How It Works

Corrections are classified against a **controlled vocabulary** (`canonical/correction-patterns.json`, ~10 named patterns with ordered regex/keyword matchers) by `core/track-corrections.py`. New pattern slugs are never minted automatically — auto-slugging one pattern per phrasing buries the real patterns and kills repeat-detection. Anything unmatched lands in an explicit `uncategorized` catch-all with its full text preserved for later manual reclassification (it never escalates). New patterns are minted deliberately with `core/taxonomy.py add-pattern`.

Scribe maintains the resulting `correction-tracker.json` in the user's data directory:

```json
{
  "patterns": {
    "skipping-file-reads": {
      "description": "Modifying or deleting files without reading them first",
      "occurrences": [
        { "entry_id": "abc123", "date": "2026-04-15", "context": "Deleted component without checking imports" },
        { "entry_id": "def456", "date": "2026-04-22", "context": "Edited function without reading full file" },
        { "entry_id": "ghi789", "date": "2026-05-01", "context": "Overwrote config without checking current values" }
      ],
      "level": "guardrail",
      "escalated_at": "2026-05-01",
      "resolved": false
    }
  }
}
```

### 7.2 Escalation Levels

| Occurrences | Level | Behavior |
|---|---|---|
| 1-2 | `observation` | Logged normally as a correction in the entry |
| 3+ | `guardrail` | Surfaced at session start, monitored during session |
| 5+ with no improvement | `critical` | Scribe proposes structural intervention to user |

### 7.3 Session-Start Guardrails

When active guardrails exist, Scribe surfaces them at the beginning of every session:

```
SCRIBE GUARDRAILS (3 active):
  [GUARDRAIL] Read files before modifying — 5 occurrences, still recurring
  [GUARDRAIL] Paginate Supabase queries on large tables — 4 occurrences
  [GUARDRAIL] Verify write operations succeed — 3 occurrences
```

### 7.4 Real-Time Monitoring

During a session, if the AI is about to repeat a known correction pattern, Scribe flags it immediately — not after the fact:

```
SCRIBE: Pattern match — "skipping-file-reads" (5 prior occurrences).
This file has not been read yet. Read before modifying.
```

### 7.5 Critical Escalation

When a pattern reaches 5+ occurrences with no improvement, Scribe presents the situation to the user during the next Reader session:

> "The pattern 'skipping-file-reads' has occurred 5 times despite being logged as a correction each time. The current approach (logging it) isn't preventing recurrence. Options:
> - Add a pre-action checklist to CLAUDE.md that enforces file reads before edits
> - Generate a guardrail skill similar to research-gate
> - Add it to the observer's real-time monitoring with hard stops
>
> Which approach would you like to try?"

The user decides. Scribe proposes, the user disposes. No autonomous changes.

---

## 8. User-Guided Growth

### 8.1 Philosophy

Scribe doesn't randomly upgrade itself. It observes its own effectiveness, presents findings to the user, and asks for direction. The user guides Scribe's evolution the way a manager coaches an employee.

### 8.2 Self-Performance Observations

Scribe maintains a `tuning.json` in the user's data directory (user-approved, never auto-generated):

```json
{
  "approved_at": "2026-05-10T14:00:00Z",
  "observation_weights": {
    "architectural_decisions": {
      "weight": "high",
      "reason": "User references these in 70% of reflections"
    },
    "routine_features": {
      "weight": "low",
      "reason": "User never revisits these entries"
    }
  },
  "self_notes": [
    "Session-open entries are never referenced — consider reducing detail",
    "Corrections in data pipeline area correlate with sessions where research was skipped",
    "Most impactful entries connect skill usage to outcomes"
  ],
  "active_experiments": [
    {
      "change": "Reduced routine feature entry detail to 1-2 sentences",
      "started": "2026-05-10",
      "status": "testing",
      "result": null
    }
  ]
}
```

### 8.3 When Growth Proposals Happen

During Reader sessions (when the user asks for reflection), Scribe includes a section on its own performance:

> **Scribe Self-Assessment:**
> - 12 of your last 20 entries are type `feature_shipped` with `routine` complexity. You never reference these in reflections. Should I reduce their detail level?
> - Your most-referenced entries are `decision_made` and `correction`. I could weight observation toward those.
> - The guardrail for "skipping-file-reads" has been active for 2 weeks with 1 new occurrence (down from 3/week). Trending in the right direction.
>
> Any adjustments you'd like me to make?

### 8.4 No Silent Upgrades

Every change to Scribe's behavior requires user approval:
1. Scribe observes a pattern in its own effectiveness
2. Scribe proposes a specific change with rationale
3. User approves, rejects, or modifies
4. Approved changes are written to `tuning.json` with timestamp
5. Scribe reads `tuning.json` on session start to load approved adjustments

---

## 9. Skill Awareness (Meta-Skill)

### 9.1 Concept

Scribe functions as a meta-skill — it understands the user's installed skills, what they do, why they exist, and how they connect. It observes skill usage patterns and correlates them with outcomes.

### 9.2 Skill Registry

During setup, Scribe scans for installed skills and builds a registry in config:

```json
"skill_integrations": {
  "research-gate": {
    "path": "~/.claude/skills/research-gate/",
    "purpose": "Enforces reading code before building",
    "origin": "Created after 19 corrections for skipping research",
    "observation_link": "Track when skipped — correlates with corrections"
  },
  "superpowers": {
    "path": "~/.claude/skills/superpowers/",
    "purpose": "Workflow orchestration for feature development",
    "observation_link": "Track brainstorm-spec-plan-build pipeline adherence"
  }
}
```

### 9.3 Skill-Outcome Correlation

Scribe tracks:
- When skills are used vs. skipped
- Correction rates in sessions where a relevant skill was used vs. skipped
- Whether skills are actually preventing the problems they were built to prevent

This data feeds into Reader reflections:

> "Sessions where research-gate was followed: 2 corrections in 15 sessions.
> Sessions where research-gate was skipped: 8 corrections in 6 sessions.
> The skill is working — the gap is compliance."

### 9.4 Skill Suggestions

Based on observed patterns, Scribe can suggest creating new skills:

> "You've logged 'untested code shipped' as a correction 4 times. A pre-commit verification skill (similar to research-gate) could enforce testing before commits. Want me to draft one?"

The user decides whether to create it. Scribe doesn't auto-generate skills.

---

## 10. Scribe-to-Scribe Packets

### 10.1 Concept

A Scribe packet is a **trusted handshake** between two Scribe users working on shared projects. It's not a data export — it's a relational introduction that lets each person's Claude understand the other person, their role, how they think, how they work, and how the two should interact to serve shared goals.

When Apollo sends a packet to Shawn, Shawn's Claude doesn't just learn "Apollo made these architectural decisions." It learns: "Apollo is the systems architect on this project. He thinks in data pipelines and patterns. He values operational accuracy over speed. When his decisions arrive, they're well-reasoned but may not account for front-of-house realities — that's where Shawn's perspective is the check."

### 10.2 What Gets Shared vs. What Stays Private

| Shared (in the packet) | Private (never leaves your Scribe) |
|---|---|
| Role, expertise, working style | Behavioral observations (drive state, energy, triggers) |
| Communication preferences | Growth assessments (complexity, autonomy ratings) |
| Decisions on shared projects | Personal corrections unrelated to shared work |
| Learnings that affect shared work | Encrypted content |
| Features shipped that affect the other person | Entries on unrelated projects |
| Architecture patterns and conventions adopted | Avoidance signals, cognitive load notes |
| Work status (done, in progress, blocked) | Reader reflections |
| How the sender relates to the receiver | Private project entries |
| What the sender needs from the receiver | Tuning data |
| Working agreements (shared conventions) | |
| Learning stories (full journey, not just outcome) | |
| Open questions for the receiver | |

### 10.3 Packet Format

```json
{
  "scribe_packet": "1.0",
  "generated": "2026-05-10T14:30:00Z",
  "packet_id": "pkt-uuid",

  "sender": {
    "name": "Apollo",
    "scribe_id": "apollo-abc123",
    "role": "COO / Project Manager",
    "expertise": ["operations", "data pipelines", "system architecture"],
    "working_style": "Systems thinker. Designs for the future but ships for today. Mobile-first. Prefers medallion architecture for data flows. Values audit trails.",
    "communication_preferences": {
      "detail_level": "concise with evidence",
      "decision_style": "collaborative but decisive",
      "feedback_style": "direct, unvarnished",
      "preferred_format": "bullet points over paragraphs"
    }
  },

  "receiver": {
    "name": "Shawn",
    "known_role": "Owner / Operator",
    "notes": "Shawn runs the restaurant day-to-day. His perspective is operational reality — if a feature doesn't work during a Friday dinner rush, it doesn't work."
  },

  "relationship": {
    "shared_projects": ["blackfin"],
    "how_we_work_together": "Apollo handles architecture, backend, data pipeline, and technical direction. Shawn handles operations, testing in production, and front-of-house feedback. Decisions are collaborative but Shawn has final say on anything that touches the floor.",
    "trust_level": "full",
    "collaboration_since": "2026-01",
    "interaction_patterns": "Async most of the time. Apollo ships features, Shawn tests in the restaurant. Feedback cycles are 1-3 days.",
    "shared_vocabulary": ["jacket", "medallion", "bronze/silver/gold"],
    "tension_points": "Apollo sometimes over-engineers for future flexibility. Shawn needs things that work now. Both perspectives are valid — the tension produces better decisions."
  },

  "for_receiver_claude": {
    "integration_guidance": "When Apollo sends architectural decisions, adopt them unless Shawn has operational context that contradicts them. If there's a conflict, surface it explicitly — don't silently override either person.",
    "watch_for": "Apollo's decisions are systems-level. Shawn's reality is kitchen-level. If a decision seems impractical for daily ops, flag it as a question back to Apollo rather than just implementing it.",
    "how_to_use_this_context": "This isn't a directive — it's background. Use it to make better suggestions, catch potential conflicts early, and help Shawn communicate effectively with Apollo when needed.",
    "when_to_reference": "When Shawn is working on shared project code, when he asks about a decision Apollo made, when there's an architectural question Apollo has already answered, or when Shawn's work would benefit from knowing Apollo's current direction."
  },

  "project_context": {
    "project": "blackfin",
    "description": "Restaurant management platform — inventory, recipes, cost tracking, vendor management",
    "current_phase": "Active development, production use",
    "stack": "Next.js 15.5, React 19, TypeScript, Tailwind 4, Supabase",
    "key_patterns": [
      "Medallion architecture for all data ingestion (bronze -> silver -> gold)",
      "Jacket concept: every entity has a complete traceability record",
      "Mobile-responsive for tablet use in kitchen"
    ]
  },

  "decisions": [
    {
      "title": "Adopted medallion architecture for receipt pipeline",
      "reasoning": "Bronze (raw scan) -> Silver (enriched) -> Gold (confirmed by user). Ensures data quality while allowing fast capture.",
      "affects_receiver": "All scanner and receipt work should follow this three-stage pattern.",
      "date": "2026-04-27"
    }
  ],

  "active_work": [
    {
      "title": "Refactoring vendor management module",
      "status": "in_progress",
      "touches": ["vendors table", "receipt_items FK"],
      "blocked_by": null,
      "blocks": "Catalog price comparison feature",
      "eta": "next week"
    }
  ],

  "learnings": [
    {
      "title": "Supabase RLS requires explicit policy per role",
      "detail": "Silent failure when a new role was added without a corresponding policy. No error — just empty results.",
      "relevance": "Any new role or permission level needs RLS policies added immediately."
    }
  ],

  "learning_stories": [
    {
      "title": "Data pipeline architecture",
      "attempts": [
        "First attempt: flat pipeline, no validation stages. Result: bad data reached production, 3 corrections logged.",
        "Second attempt: added bronze/silver/gold stages with validation gates at each transition."
      ],
      "thinking": "Raw data can't be trusted at the point of capture. You need progressive enrichment with human checkpoints. Each stage has clear entry/exit criteria.",
      "outcome": "Zero data quality corrections in 6 weeks after adopting medallion pattern.",
      "transferable_lesson": "Apply progressive validation to any data ingestion — don't trust raw input."
    }
  ],

  "working_agreements": [
    "Mobile breakpoint is 767px — all views must work at this width",
    "All data pipelines follow medallion: bronze -> silver -> gold",
    "Every entity has a 'jacket' — a complete record with full traceability"
  ],

  "open_questions": [
    "Shawn — are you tracking vendor price changes per receipt or per catalog update?",
    "Do we need a shared products table across modules, or keep inventory and recipes separate?"
  ]
}
```

### 10.4 Storage

```
~/Desktop/Scribe/
  inbox/                                    <- Received packets
    apollo-blackfin-2026-05-10.packet.json
    bilal-naturejab-2026-05-08.packet.json
  outbox/                                   <- Sent packets (archive)
    shawn-blackfin-2026-05-10.packet.json
```

Filename convention: `<sender>-<project>-<date>.packet.json`

### 10.5 Commands

| Command | Purpose |
|---|---|
| `scribe share <project> --to <name>` | Generate a packet for someone |
| `scribe inbox` | List received packets |
| `scribe read-packet <filename>` | View a packet's contents |
| `scribe accept-packet <filename>` | Integrate packet context into active session |
| `scribe preview-packet` | Review a packet before sending |

### 10.6 The Flow

1. **User says**: "Share my Blackfin context with Shawn's Scribe"
2. **Scribe**:
   - Filters entries to the specified project
   - Strips all behavioral/growth/personal data
   - Pulls sender profile from config (role, expertise, style)
   - Pulls relationship info if a prior packet exchange exists
   - Generates `for_receiver_claude` guidance
   - Builds learning stories from relevant correction-to-resolution chains
   - Packages decisions, active work, learnings, agreements, questions
3. **Saves** to sender's `outbox/` and produces the `.packet.json` file
4. **Delivery** is the user's choice — email, shared Drive folder, Slack, AirDrop. Scribe doesn't handle transport.
5. **Receiver** drops the packet into their Scribe's `inbox/`
6. **On session start**, receiver's Scribe detects new packets and announces:

```
Scribe: New packet from Apollo [blackfin, 2026-05-10]
  Sender: Apollo — COO / Project Manager, systems architect
  3 decisions, 1 active work item, 2 learnings, 1 learning story, 1 open question

  Apollo asks: "Are you tracking vendor price changes per receipt
  or per catalog update?"

  Type 'scribe accept-packet apollo-blackfin-2026-05-10' to integrate.
```

7. **Receiver accepts** — their Claude now understands who the sender is, how they think, what they've decided and why, what work is in flight, how the two should interact, and what transferable lessons apply.

### 10.7 Learning Stories — Collective Intelligence

The `learning_stories` section is what makes packets more than data exports. A learning story captures the full journey:

- **What was tried** (including failures)
- **The thinking** behind the eventual solution
- **The outcome** (measured, not claimed)
- **The transferable lesson** (what the receiver can apply without repeating the journey)

When multiple Scribes share learning stories, the team's collective correction rate drops — not because everyone made every mistake, but because one person's journey became everyone's shortcut.

### 10.8 Relational Intelligence

The `sender`, `receiver`, `relationship`, and `for_receiver_claude` sections together form a relational model:

- **Bidirectional awareness**: When both people exchange packets, each Claude knows both sides
- **Tension is acknowledged**: `tension_points` explicitly names where perspectives differ — prevents Claudes from silently choosing one side
- **Integration guidance is actionable**: Tells the receiving Claude HOW to use the context, not just WHAT it is
- **Shared vocabulary prevents miscommunication**: Both Claudes use the same terms the same way
- **Working agreements create alignment**: Both Claudes enforce the same conventions

### 10.9 Packet Evolution

Over time, packets between the same two people build a shared context layer:
- Subsequent packets include only **changes** since the last one (new decisions, completed work, new questions)
- The receiving Scribe maintains a **composite view** of all packets from a sender
- The Reader can factor in collaboration patterns: "Apollo has sent 4 packets. You've never sent one back. Is there context his Claude is missing?"

### 10.10 Team Onboarding

When a new person joins a project, they receive a packet from each existing collaborator. Their Scribe ingests all of them, and their Claude starts with full project context and relational understanding from day one.

### 10.11 Privacy Boundaries

- Sender explicitly controls what goes in the packet via `config.json` share defaults
- `auto_accept: false` by default — packets sit in inbox until the user reviews them
- Behavioral data NEVER appears in packets regardless of settings
- Growth assessments NEVER appear in packets
- Encrypted content NEVER appears in packets
- The user can inspect any packet before sending (`scribe preview-packet`)

---

## 11. Reader (Reflection Engine)

### 11.1 Pull-Based Only

Users initiate reflection. Scribe never offers unsolicited check-ins. The Reader activates when the user asks naturally:

- "How am I doing?" — full development check-in
- "What patterns do you see?" — repeated corrections, comfort zones, decision reversals
- "Where am I growing?" — evidence-based growth report with cited entries
- "Where am I stuck?" — stagnation signals and plateau detection
- "What should I work on next?" — development priorities based on gaps
- "[Project] deep dive" — growth narrative for a specific project

### 11.2 Self-Performance Reporting

During Reader sessions, Scribe includes its own performance assessment alongside the user's:

- Which entry types are most/least referenced
- Whether guardrails are working (correction frequency before/after escalation)
- Self-notes on its own observation effectiveness
- Proposed adjustments (user approves before any changes take effect)

### 11.3 Packet-Aware Analysis

When the user has accepted packets from collaborators, the Reader factors in collaboration context:

- Decisions from collaborators that affect the user's work
- Learning stories that are relevant to the user's current projects
- Collaboration patterns ("you've received 4 packets but sent 0 — is there context others need?")

### 11.4 `/scribe-help`

Always available. Shows all commands, reflection prompts, and a brief explanation of how Scribe works. Not a one-time tutorial — a permanent reference the user can access anytime.

---

## 12. Status Line

### 12.1 Format

```
SCRIBE: 3 SESSION / 171 TOTAL | LRN 1 | COR 0 | DEC 2 | FEAT 0 | BUG 0
```

- Three-letter abbreviations for metrics
- All metrics always visible (including zeros)
- SESSION count resets per session; TOTAL is cumulative

### 12.2 Configuration

Users are asked during setup if they want status line integration. Can be added or removed anytime via `/scribe-config`. Integrates with existing status line content — doesn't replace it.

---

## 13. Entry Management

### 13.1 Commands

| Command | Purpose |
|---|---|
| `scribe list` | Browse entries with filters |
| `scribe list --project blackfin` | Filter by project |
| `scribe list --type correction` | Filter by type |
| `scribe list --since 2026-04-01` | Filter by date |
| `scribe list --search "medallion"` | Full-text search |
| `scribe edit <id>` | Modify an entry (updates all storage targets) |
| `scribe delete <id>` | Remove from all targets (backup in revisions/) |

### 13.2 Listing Format

```
ID          DATE        PROJECT     TYPE        TITLE
a1b2c3d4    2026-05-08  blackfin    decision    Adopted medallion architecture
e5f6g7h8    2026-05-09  blackfin    correction  Missed RLS policy on vendor table
i9j0k1l2    2026-05-10  naturejab   feature     Shipped asset gallery component
```

Short IDs (first 8 chars), human-readable, sortable.

### 13.3 Deletion Safety

- Deleted entries are moved to `revisions/` with a timestamp prefix
- 30-day retention in revisions before permanent removal
- Deletion cascades to all storage targets (local, Drive, Supabase)
- Audit-logged: the deletion itself becomes an entry

---

## 14. Encryption

### 14.1 Field-Level Encryption

When enabled, only content fields are encrypted:
- **Encrypted**: summary, decisions, learnings, corrections, behavioral notes, growth notes
- **Unencrypted**: id, timestamp, session_id, project, type, title, user_id, metrics (counts only), connections (tags)

This preserves status line counters, entry type tracking, and index stats while protecting sensitive content.

### 14.2 Implementation

- Algorithm: AES-256-GCM
- Key derivation: PBKDF2 from user password
- Recovery key generated on setup (user stores it securely)
- Encrypted entries are base64-encoded in the JSON fields
- Decryption happens at read time (Reader, list, edit)

---

## 15. Updates

### 15.1 Distribution

Updates are pushed to the GitHub repo (`SpaceAM23/scribe`). Users pull them:

```bash
scribe update
```

### 15.2 Safety

- `scribe update` ONLY touches the skill directory (`~/.claude/scribe/`)
- User data directory is NEVER modified by updates
- Schema is additive-only — old entries remain valid forever
- Config migrations are handled by the update script (adds new fields with defaults, never removes)

---

## 16. Platform Adapters

### 16.1 Claude Code

- Installation: `./install.sh` (copies to `~/.claude/scribe/`)
- Commands: slash commands (`/scribe-help`, `/scribe-config`, etc.)
- Writer: bash script with multi-target pipeline
- Status line: integrated segment
- Storage: Local + Drive + Supabase

### 16.2 Claude Desktop

- Installation: `npm install -g @rocksteady/scribe-mcp`
- Interface: MCP server that Claude Desktop connects to
- Writer: Node.js implementation of the same pipeline
- Storage: Local + Drive + Supabase

### 16.3 Claude Web App

- Installation: Copy project instructions from `adapters/claude-web/`
- Interface: Project knowledge instructions that guide Claude's behavior
- Writer: Google Drive MCP for storage
- Storage: Drive + Supabase (no local filesystem access)

---

## 17. Command Reference

| Command | Purpose |
|---|---|
| `/scribe-help` | Full menu of commands and reflection prompts |
| `/scribe-status` | Quick stats and session metrics |
| `/scribe-list` | Browse and search entries |
| `/scribe-config` | View or update all settings |
| `/scribe-sync` | Push local entries to cloud targets |
| `/scribe-export` | Export as JSON, CSV, or markdown |
| `/scribe-update` | Pull latest core from GitHub |
| `/scribe-import` | Import from Drive, chat exports, or JSON |
| `scribe edit <id>` | Modify an entry across all storage targets |
| `scribe delete <id>` | Remove an entry from all storage targets |
| `scribe list` | Browse with filters (--project, --type, --since, --search) |
| `scribe share <project> --to <name>` | Generate a Scribe-to-Scribe packet |
| `scribe inbox` | List received packets |
| `scribe read-packet <file>` | View a packet's contents |
| `scribe accept-packet <file>` | Integrate packet into active session |
| `scribe preview-packet` | Review a packet before sending |

---

## 18. Build Phases

### Phase 1 — Core Generalization
Generalize prompts, schema, and behavioral library from Apollo's personal Scribe. Remove hardcoded references. Add correction escalation, skill awareness, and user-guided growth foundations.

### Phase 2 — Claude Code Adapter
Install script, interactive setup, intake scan, multi-target writer, slash commands, status line, entry management, encryption.

### Phase 3 — Claude Desktop Adapter
MCP server implementation. Same writer pipeline in Node.js. Connection to local + Drive + Supabase.

### Phase 4 — Claude Web Adapter
Project instructions template. Drive MCP integration guide. Web-specific onboarding flow.

### Phase 5 — Scribe-to-Scribe
Packet generation from entries + profile. Inbox/outbox management. Packet acceptance and context integration. Relational model building. Learning stories. Composite view from multiple packets.

### Phase 6 — Intelligence Layer
Correction escalation (tracker, guardrails, real-time monitoring, critical proposals). User-guided growth (self-performance observation, tuning proposals, experiment tracking). Skill awareness (registry, correlation tracking, skill suggestions).

### Phase 7 — Polish
Update mechanism, documentation, error handling, cross-platform testing.
