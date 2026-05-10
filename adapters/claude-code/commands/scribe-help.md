---
name: scribe-help
description: Show all Scribe commands, reflection prompts, and how Scribe works
---

# Scribe Help

Display the full Scribe reference for the user. Print the following content exactly, formatted cleanly for the terminal.

---

## What Scribe Is

Scribe is a silent AI session journal. It observes your sessions, records decisions, learnings, corrections, and growth patterns, and provides honest feedback on demand. It never interrupts. Never flatters. Tells you what the data shows.

Scribe is **longitudinal** — it builds a picture over weeks and months, identifies patterns across sessions, and gives evidence-based reflection when asked.

## Slash Commands

Print this table:

```
COMMAND               PURPOSE
-------               -------
/scribe-help          This reference — all commands and prompts
/scribe-status        Quick stats dashboard (entries, guardrails, growth)
/scribe-list          Browse and search entries (--project, --type, --since, --search)
/scribe-config        View or update settings (behavioral tracking, status line, etc.)
/scribe-sync          Push local entries to cloud targets (Supabase, Drive)
/scribe-export        Export journal as JSON, CSV, or markdown
/scribe-update        Pull latest Scribe from GitHub
/scribe-import        Import from Drive, chat exports, or JSON files
/scribe-share         Generate a Scribe-to-Scribe packet for a collaborator
/scribe-inbox         Manage received Scribe-to-Scribe packets
```

## CLI Commands

These are used inline during conversation (not slash commands):

```
COMMAND                                PURPOSE
-------                                -------
scribe edit <id>                       Modify an entry across all storage targets
scribe delete <id>                     Remove an entry (backed up in revisions/ for 30 days)
scribe list --project X --type Y       Browse with filters
scribe share <project> --to <name>     Generate a Scribe-to-Scribe packet
scribe inbox                           List received packets
scribe read-packet <file>              View a packet's contents
scribe accept-packet <file>            Integrate packet context into active session
scribe preview-packet                  Review a packet before sending
```

## Reflection Prompts

Scribe's Reader activates when you ask naturally. Try any of these:

```
PROMPT                          WHAT YOU GET
------                          ------------
"How am I doing?"               Full development check-in with evidence
"What patterns do you see?"     Repeated corrections, comfort zones, decision reversals
"Where am I growing?"           Evidence-based growth report with cited entries
"Where am I stuck?"             Stagnation signals and plateau detection
"What should I work on next?"   Development priorities based on gaps
"[Project] deep dive"           Growth narrative for a specific project
```

Scribe only reflects when asked — it never offers unsolicited check-ins.

## What Scribe Tracks

- **Decisions** — choices made, alternatives considered, reasoning
- **Learnings** — genuinely new understanding (not routine knowledge)
- **Corrections** — mistakes named directly with cause and fix (no softening)
- **Features & Bugs** — what shipped, what broke, metrics
- **Growth** — skill areas, complexity, autonomy level
- **Behavioral** (opt-in) — drive state, energy, cognitive load, patterns

## Settings

Use `/scribe-config` to view or change any setting:
- Toggle behavioral tracking on/off
- Enable/disable the status line
- Add or remove projects
- Configure storage targets (local, Drive, Supabase)
- Set transparency level (detailed or concise)
- Configure Scribe-to-Scribe sharing defaults

## Behavioral Tracking

Behavioral tracking is **opt-in**. When enabled, Scribe observes cognitive patterns, energy levels, avoidance signals, and work modes. When disabled, Scribe still records decisions, learnings, and corrections — it just skips the behavioral field.

Toggle it anytime: tell `/scribe-config` to "turn on behavioral tracking" or "turn off behavioral tracking."

## Scribe-to-Scribe Packets

Packets are trusted handshakes between Scribe users on shared projects. A packet carries your role, decisions, learnings, working agreements, and learning stories — but **never** behavioral data, growth assessments, or encrypted content.

- `/scribe-share` — generate a packet for a collaborator
- `/scribe-inbox` — view and accept received packets

When you accept a packet, your Claude understands who the sender is, how they think, what they've decided and why, and how you two should interact.
