---
name: scribe-status
description: Quick stats dashboard showing entries, guardrails, and growth summary
---

# Scribe Status Dashboard

Display a quick stats view of the user's Scribe journal. Follow these steps exactly.

## Step 1: Resolve the data path

Read the pointer file to find the user's data directory:

```bash
cat ~/.claude/scribe/pointer.json
```

Extract the `data_path` value. This is where all user data lives (e.g., `~/Desktop/Scribe`). Expand `~` to the user's home directory for all subsequent file reads. If pointer.json does not exist, tell the user: "Scribe data path not found. Run the Scribe installer or create ~/.claude/scribe/pointer.json with a data_path field pointing to your data directory."

## Step 2: Read data files

Read these three files from the data path. If any file is missing, note it but continue with what exists.

1. **index.json** — contains aggregate stats (total entries, entries by type, entries by project, growth summary, tag cloud)
2. **session-counter.json** — contains the current session number and session entry count
3. **correction-tracker.json** — contains active correction patterns and their escalation levels

## Step 3: Read recent entries

Read the last 5 lines of `journal.jsonl` from the data path:

```bash
tail -5 <data_path>/journal.jsonl
```

Parse each line as JSON to get the 5 most recent entries.

## Step 4: Display the dashboard

Format the output as a clean, scannable dashboard. Use this structure:

```
SCRIBE STATUS
=============

Session: #<session_number>
Entries this session: <count>
Total entries: <total>

ENTRIES BY TYPE
  decision_made    <count>
  learning         <count>
  correction       <count>
  feature_shipped  <count>
  bug_fixed        <count>
  reflection       <count>
  session_open     <count>
  (other types)    <count>

ENTRIES BY PROJECT
  <project_name>   <count>
  <project_name>   <count>

ACTIVE GUARDRAILS (<count>)
  [<LEVEL>] <description> -- <occurrences> occurrences
  [<LEVEL>] <description> -- <occurrences> occurrences
  (or "None active" if no guardrails)

GROWTH SUMMARY
  Skill areas: <list of skill areas with counts>
  Complexity: routine <n> | moderate <n> | challenging <n> | breakthrough <n>
  Autonomy: guided <n> | collaborative <n> | independent <n>

RECENT ENTRIES
  <id_8chars>  <date>  <project>  <type>  <title>
  <id_8chars>  <date>  <project>  <type>  <title>
  <id_8chars>  <date>  <project>  <type>  <title>
  <id_8chars>  <date>  <project>  <type>  <title>
  <id_8chars>  <date>  <project>  <type>  <title>
```

Rules:
- Show all entry types, including zeros
- Show first 8 characters of entry IDs
- Format dates as YYYY-MM-DD
- For guardrails, show the escalation level in brackets: [OBSERVATION], [GUARDRAIL], or [CRITICAL]
- If a data file is missing, show "-- not found --" for that section
- If journal.jsonl is empty or missing, show "No entries yet"
- Keep it compact — this is a glance view, not a deep dive
