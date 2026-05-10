# Scribe

A silent AI session journal for Claude. Tracks your decisions, learnings, corrections, and growth patterns — then gives you honest feedback when you ask for it.

Scribe observes your Claude sessions, records what matters, and builds a longitudinal picture of how you work and where you're growing. It never interrupts. It never flatters. It tells you what the data shows.

## What Scribe Does

- **Observes** your Claude sessions silently, recording decisions, learnings, mistakes, and milestones
- **Tracks growth** across skill areas with honest complexity and autonomy assessments
- **Identifies patterns** — repeated corrections, comfort zones, avoidance signals, plateaus
- **Behavioral analysis** (opt-in) — cognitive and motivational patterns grounded in psychological research
- **Reflects on demand** — ask "How am I doing?" and get evidence-based feedback, not flattery

## Platforms

| Platform | Install | Storage Options |
|---|---|---|
| Claude Code | `./install.sh` | Local files, Google Drive, Supabase |
| Claude Desktop | `npm install -g @rocksteady/scribe-mcp` | Local files, Google Drive, Supabase |
| Claude Web App | Copy project instructions from `adapters/claude-web/` | Google Drive, Supabase |

## Quick Start (Claude Code)

```bash
git clone https://github.com/SpaceAM23/scribe.git
cd scribe && ./install.sh
```

The interactive setup walks you through:
1. **Intake scan** — import chat history from other AI tools to build your profile
2. **Storage choice** — local files, Google Drive, Supabase, or any combination
3. **Behavioral tracking** — opt into psychological pattern observation
4. **Encryption** — optional field-level encryption for sensitive content
5. **Status line** — add Scribe metrics to your Claude Code status bar

## Commands

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

## Reflection

When you're ready for feedback, ask naturally:

- "How am I doing?" — full development check-in
- "What patterns do you see?" — repeated corrections, comfort zones, decision reversals
- "Where am I growing?" — evidence-based growth report with cited entries
- "Where am I stuck?" — stagnation signals and plateau detection
- "What should I work on next?" — development priorities based on gaps
- "[Project] deep dive" — growth narrative for a specific project

## Architecture

```
~/.claude/scribe/          <- Skill installation (updatable)
  core files, prompts,
  adapters, scripts

~/Desktop/Scribe/          <- Your data (permanent, untouched by updates)
  entries/, journal.jsonl,
  index.json, config.json
```

The skill is the engine — replaceable, version-controlled. Your journal is your data — portable, durable, yours.

## Privacy

- All data stays on your machine by default
- Cloud storage (Drive, Supabase) is opt-in
- Field-level encryption available for sensitive content
- Behavioral observations are opt-in
- Edit or delete any entry at any time
- You control what Scribe records and where it's stored

## Built by

[Rocksteady Consulting](https://rocksteadyconsulting.com) — Apollo Mondesir

## License

MIT
