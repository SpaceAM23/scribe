---
name: scribe-import
description: Import journal data from Drive, chat exports, or JSON files
---

# Scribe Import — Import Data from External Sources

Import journal data from external sources into the Scribe journal.

## Step 1: Resolve the data path

Read the pointer file to find the user's data directory:

```bash
cat ~/.claude/scribe/pointer.json
```

Extract the `data_path` value and expand `~` to the user's home directory. If pointer.json does not exist, tell the user: "Scribe data path not found. Run the Scribe installer or create ~/.claude/scribe/pointer.json with a data_path field pointing to your data directory."

## Step 2: Read config

Read `<data_path>/config.json` to get the user's profile (user_id, projects) and storage settings. You will need the user_id for creating entries and the projects list for validation.

## Step 3: Determine source type

Parse the user's message to identify the import source. The user may specify one of:

- `json` — import from a JSON file containing Scribe entry objects
- `chat-export` — scan AI chat history exports to extract decisions, learnings, and patterns
- `drive` — pull entries from a Google Drive folder

If the source type is not clear from the user's message, ask: "What would you like to import? Options: json (Scribe JSON file), chat-export (AI chat history), or drive (Google Drive folder)."

---

### Source: JSON

1. Read the specified JSON file
2. Validate each entry against the Scribe schema. Required fields: `id`, `timestamp`, `session_id`, `user_id`, `project`, `type`, `title`, `summary`
3. Check for duplicate IDs against existing entries in `<data_path>/journal.jsonl`:
   ```bash
   cat <data_path>/journal.jsonl | jq -r '.id' | sort > /tmp/scribe-existing-ids.txt
   ```
4. Skip entries with duplicate IDs
5. For valid, non-duplicate entries, write each one:
   - Append to `<data_path>/journal.jsonl`
   - Write individual file to `<data_path>/entries/<id>.json`
6. Update `<data_path>/index.json` with new counts

Report: "Imported X entries, skipped Y duplicates, Z failed validation."

---

### Source: chat-export

This is the intake scan — used for new users or importing context from other AI tools.

1. Ask the user for the file path(s) to their exported chat history (e.g., ChatGPT exports, Gemini exports, Claude conversation logs, any text/JSON files)
2. Read the provided files
3. Analyze the content using deep reading to identify:
   - **Decisions**: choices made with reasoning ("we chose X because...")
   - **Learnings**: new understanding gained ("I learned that...", "turns out...")
   - **Corrections**: mistakes and fixes ("that broke because...", "the fix was...")
   - **Patterns**: recurring themes in the user's work
   - **Projects**: distinct projects mentioned
   - **Technical context**: stack, tools, conventions used

4. Present each finding with a confidence tag:

```
INTAKE SCAN RESULTS
===================

DECISIONS (found 5)
  [HIGH]   Adopted medallion architecture for data pipelines
           Source: 3 conversations reference this pattern consistently
  [MEDIUM] Mobile-first design for shop floor use
           Source: mentioned in 2 conversations with specific rationale
  [LOW]    Preference for pg_cron over Vercel cron
           Source: single mention

LEARNINGS (found 3)
  [HIGH]   Supabase RLS fails silently when policies are missing
           Source: detailed troubleshooting conversation
  [MEDIUM] Client-side image compression prevents 413 errors
           Source: implementation conversation with context

CORRECTIONS (found 4)
  [HIGH]   Shipping untested code — occurred 3 times across conversations
           Source: multiple error-fix cycles
  [MEDIUM] Running destructive queries without pagination
           Source: one data loss incident with detailed post-mortem

PROJECTS IDENTIFIED
  restaurant, field-ops, nonprofit

PATTERNS
  - Research before building reduces corrections
  - Batch work benefits from cheaper models
```

5. **Verification is mandatory.** Ask the user to review each finding:
   - Confirm: "Which of these should become Scribe entries? You can accept all, reject all, or pick individually."
   - The user must explicitly approve before anything is written
   - Nothing is assumed. Nothing is fabricated.

6. For approved findings, generate proper Scribe entries:
   - Assign new UUIDs
   - Set timestamp to the original conversation date if available, otherwise the current date
   - Set session_id to "intake-scan"
   - Set user_id from config
   - Write via the standard process (journal.jsonl + entries/ + index.json update)

---

### Source: drive

1. Check that `storage.google_drive.enabled` is true in config and that a `folder_id` is set
2. If Google Drive MCP tools are available, list files in the configured folder
3. Read each `.json` file from Drive
4. Parse as Scribe entries and validate against schema
5. Check for duplicate IDs against local journal
6. Import non-duplicate, valid entries using the standard write process
7. If Drive MCP is not available, tell the user: "Drive import requires the Google Drive MCP connection. Please run this command from Claude Desktop or Claude Web App with Drive access configured."

---

## Step 4: Update index

After any successful import, update `<data_path>/index.json` with the new entry counts by type and project. Read the current index, increment the relevant counters, and write it back.

## Step 5: Report

```
SCRIBE IMPORT COMPLETE
======================

Source: <json/chat-export/drive>
Imported: <count> entries
Skipped: <count> (duplicates)
Failed: <count> (validation errors)

New entries by type:
  decision_made    <count>
  learning         <count>
  correction       <count>
  ...

New entries by project:
  <project>        <count>
```
