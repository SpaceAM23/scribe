# Scribe

A silent AI session journal for Claude. Tracks your decisions, learnings, corrections, and growth patterns — then gives you honest feedback when you ask for it.

Scribe observes your Claude sessions, records what matters, and builds a longitudinal picture of how you work and where you're growing. It never interrupts. It never flatters. It tells you what the data shows.

## What Scribe Does

- **Observes** your Claude sessions silently, recording decisions, learnings, mistakes, and milestones
- **Tracks growth** across skill areas with honest complexity and autonomy assessments
- **Identifies patterns** — repeated corrections, comfort zones, avoidance signals, plateaus
- **Escalates corrections** — when a mistake recurs 3+ times, Scribe promotes it from observation to active guardrail, surfacing it at session start and flagging it in real time
- **Behavioral analysis** (opt-in) — cognitive and motivational patterns grounded in psychological research, 51 patterns across 5 categories
- **Reflects on demand** — ask "How am I doing?" and get evidence-based feedback, not flattery
- **Self-improves with your guidance** — Scribe evaluates its own effectiveness and proposes adjustments for your approval
- **Shares context between collaborators** — Scribe-to-Scribe packets carry relational intelligence, not just data

## What's New in 0.2.0

The largest update since inception — the write path, read path, and taxonomy were rebuilt around one principle: **no data loss, ever**.

- **Session briefs — the read path** (`core/brief.py`). Agents no longer grep the raw journal at session start. Every write regenerates `briefs/<project>.md` — a 60-line-capped brief with the project's LANDMINES (correction patterns with lifetime/30-day counts), KNOWLEDGE, RECENT session summaries, OPEN THREADS, and a meta-budget line — plus `briefs/_portfolio.md`, a one-line-per-project rollup with pending taxonomy suggestions and doctor status.
- **Concurrency-safe writer** (`core/writer.sh`). A bash-3.2-safe mkdir lock serializes parallel writers around the critical section (dedup check → journal append → index → tracker), with stale-lock recovery via atomic rename-aside. index.json updates are atomic (tmp+rename) with corrupt-file quarantine. The content hash is recorded only *after* the journal append succeeds, so a crash can never poison dedup into refusing a real entry. The locale is pinned so cron and interactive writes hash identically.
- **Doctor** (`core/doctor.py`). Regenerates ALL derived state from journal.jsonl in one pass: rebuilds seen-hashes.txt with the exact writer hash recipe, recomputes every index.json counter, and validates/repairs entry ids (malformed, uppercase, duplicate). `--check` reports; `--fix` repairs atomically under the same writer lock, aborting rather than racing a live writer. Every repair is logged.
- **Taxonomy minting** (`core/taxonomy.py`). Unknown projects/types are never rejected and never silently misfiled: the writer normalizes them (to `meta`/`milestone`), logs the repair, and queues the ORIGINAL value to `canonical/taxonomy-suggestions.jsonl`. `taxonomy.py` is how you deliberately mint new projects, entry types, and correction patterns — with backups, atomic writes, and suggestion resolution. Pending suggestions surface in the portfolio brief.
- **Hardened sync** (`core/reconcile.sh`). The Supabase replay queue can no longer wedge: unparseable or permanently-failing entries (bad casts, constraint violations) move to `sync-dead-letter.jsonl` — annotated, never deleted — and transient failures retry up to 5 attempts. Signal-safe temp-file cleanup, plus a hardlink swap-guard so entries appended mid-replay are never dropped.
- **Vocabulary-driven correction tracking** (`core/track-corrections.py`). Corrections are classified against a controlled ~10-pattern vocabulary (`canonical/correction-patterns.json`) instead of auto-minting a new slug per phrasing (which buried real patterns and killed repeat-detection). Unmatched corrections land in `uncategorized` with full text preserved. Entry JSON is piped over stdin — hostile text (quotes, newlines, triple-quotes) can no longer crash the tracker.
- **Schema v2** (`core/schema.json`). Adds the `essence` entry type, `unspecified` enum values, and the `professional_development` behavioral block. Enum enforcement at the writer boundary reads from the schema — your `DATA_DIR/schema.json` copy takes precedence over the install's.
- **Tests** (`tests/`). Concurrent-writer, hostile-tracker-input, and NEXUS-privacy proofs, all bash 3.2-compatible and runnable against a scratch data dir.

## Platforms

| Platform | Install | Storage Options |
|---|---|---|
| Claude Code | `./scripts/install.sh` | Local files, Google Drive, Supabase |
| Claude Desktop | MCP server at `adapters/claude-desktop/` | Local files, Google Drive, Supabase |
| Claude Web App | Project instructions from `adapters/claude-web/` | Google Drive, Supabase |

## Quick Start (Claude Code)

```bash
git clone https://github.com/SpaceAM23/scribe.git ~/.claude/scribe
cd ~/.claude/scribe && ./scripts/install.sh
```

The interactive setup walks you through:
1. **Data directory** — where your journal lives (default `~/Desktop/Scribe/`)
2. **User profile** — name, role, expertise
3. **Storage** — local files, Google Drive, Supabase, or any combination
4. **Behavioral tracking** — opt into psychological pattern observation
5. **Encryption** — optional field-level encryption for sensitive content
6. **Status line** — add Scribe metrics to your Claude Code status bar
7. **Skill scan** — detect and integrate your existing Claude skills
8. **Intake scan** — import chat history from other AI tools to build your profile

## Commands

| Command | Purpose |
|---|---|
| `/scribe-help` | Full menu of commands and reflection prompts |
| `/scribe-status` | Dashboard: stats, guardrails, growth summary |
| `/scribe-list` | Browse and search entries with filters |
| `/scribe-config` | View or update all settings |
| `/scribe-sync` | Push local entries to cloud targets |
| `/scribe-export` | Export as JSON, CSV, or markdown |
| `/scribe-update` | Pull latest core from GitHub |
| `/scribe-import` | Import from Drive, chat exports, or JSON |
| `/scribe-share` | Generate a Scribe-to-Scribe packet |
| `/scribe-inbox` | View and accept received packets |

## Reflection

When you're ready for feedback, ask naturally:

- "How am I doing?" — full development check-in with correction scorecard
- "What patterns do you see?" — repeated corrections, comfort zones, decision reversals
- "Where am I growing?" — evidence-based growth report with cited entries
- "Where am I stuck?" — stagnation signals and plateau detection
- "What should I work on next?" — development priorities based on gaps
- "[Project] deep dive" — growth narrative for a specific project
- "How is Scribe doing?" — Scribe's self-assessment with proposed adjustments

## Scribe-to-Scribe Packets

Share context between collaborators through trusted handshakes:

```
scribe share blackfin --to Shawn
```

A packet carries four layers of relational intelligence:
- **Sender profile** — role, expertise, working style, communication preferences
- **Relationship model** — how you work together, division of labor, shared vocabulary, tension points
- **Project context** — decisions, active work, learnings, learning stories, working agreements
- **Claude guidance** — actionable instructions for the receiver's Claude on how to integrate your context

Behavioral data, growth assessments, and encrypted content never leave your Scribe.

## Correction Escalation

Scribe doesn't just log mistakes — it prevents them from recurring:

| Occurrences | Level | What Happens |
|---|---|---|
| 1-2 | Observation | Logged normally |
| 3+ | Guardrail | Surfaced at session start, monitored in real time |
| 5+ | Critical | Scribe proposes structural intervention for your approval |

## Architecture

```
~/.claude/scribe/              <- Skill (updatable engine)
  core/                        <- Prompts, schema, writer, doctor, brief,
                                  taxonomy, reconcile, correction tracker
  adapters/                    <- Claude Code, Desktop, Web
  scripts/                     <- Install, entry creator, team sync
  templates/                   <- Config, taxonomy, and .env templates
  tests/                       <- Concurrency / hostile-input / privacy proofs

~/Desktop/Scribe/              <- Your data (permanent, yours)
  config.json                  <- Settings, profile, skill registry
  entries/                     <- Individual JSON entry files
  journal.jsonl                <- Append-only index (source of truth)
  index.json                   <- Stats, growth summary (derived; doctor rebuilds)
  seen-hashes.txt              <- Content-hash dedup ledger (derived)
  correction-tracker.json      <- Correction patterns and escalation state
  canonical/                   <- projects.json, correction-patterns.json,
                                  taxonomy-suggestions.jsonl
  briefs/                      <- Per-project session briefs + _portfolio.md
  sync-queue.jsonl             <- Failed Supabase writes awaiting reconcile
  sync-dead-letter.jsonl       <- Permanently-failed sync entries (annotated)
  normalizations.jsonl         <- Every write-time repair, logged
  duplicates.jsonl             <- Refused duplicates (full payload preserved)
  tuning.json                  <- User-approved Scribe adjustments
  inbox/                       <- Received packets
  outbox/                      <- Sent packets
```

The skill is the engine — replaceable, version-controlled. Your journal is your data — portable, durable, yours. `scribe update` only touches the engine, never your data.

## Privacy

- All data stays on your machine by default
- Cloud storage (Drive, Supabase) is opt-in
- Field-level encryption available (AES-256-GCM)
- Behavioral observations are opt-in
- Scribe-to-Scribe packets never include behavioral, growth, or encrypted data
- Edit or delete any entry at any time
- You control what Scribe records, where it's stored, and how it evolves

## Built by

[Rocksteady Consulting](https://rocksteadyconsulting.com) — Apollo Mondesir

## License

MIT
