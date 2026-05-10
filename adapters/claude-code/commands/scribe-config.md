---
name: scribe-config
description: View or update Scribe settings
---

# Scribe Config — View or Update Settings

Display the current Scribe configuration or apply changes requested by the user.

## Step 1: Resolve the data path

Read the pointer file to find the user's data directory:

```bash
cat ~/.claude/scribe/pointer.json
```

Extract the `data_path` value and expand `~` to the user's home directory. If pointer.json does not exist, tell the user: "Scribe data path not found. Run the Scribe installer or create ~/.claude/scribe/pointer.json with a data_path field pointing to your data directory."

## Step 2: Read config.json

Read `<data_path>/config.json`. This contains all user settings.

The config structure has these sections:
- `scribe_version` — installed version
- `schema_version` — schema version number
- `user_id` — unique user identifier
- `user_profile` — name, role, expertise, working style, communication preferences
- `data_path` — where data lives
- `projects` — registered projects (object with project names as keys)
- `storage` — local, google_drive, supabase targets (each with enabled flag and credentials)
- `behavioral_tracking` — boolean, opt-in
- `encryption` — enabled flag, algorithm, key derivation
- `status_line` — enabled flag and which metrics to show
- `transparency` — "detailed" or "concise"
- `scribe_to_scribe` — enabled, auto_accept, share_defaults
- `skill_integrations` — registered skills with paths and purposes

## Step 3: Determine intent

If the user's message only invokes `/scribe-config` with no additional instructions, display the current config in a clean readable format:

```
SCRIBE CONFIGURATION
====================

Version: <scribe_version> (schema v<schema_version>)
User: <user_profile.name> (<user_profile.role>)
Data Path: <data_path>

PROJECTS
  <project_name>: <description or details>

STORAGE
  Local:     <enabled/disabled>
  Drive:     <enabled/disabled> <folder_id if set>
  Supabase:  <enabled/disabled> <url if set>

TRACKING
  Behavioral: <on/off>
  Transparency: <detailed/concise>

STATUS LINE
  Enabled: <yes/no>
  Metrics: <list of metrics>

ENCRYPTION
  Enabled: <yes/no>
  Algorithm: <algorithm if enabled>

SCRIBE-TO-SCRIBE
  Enabled: <yes/no>
  Auto-accept: <yes/no>
  Share defaults: role=<yes/no>, style=<yes/no>, expertise=<yes/no>, comms=<yes/no>

SKILL INTEGRATIONS
  <skill_name>: <path> — <purpose>
```

Do not display sensitive values (anon keys, service role keys, DB connections) — show "[set]" or "[not set]" instead.

## Step 4: Apply changes (if requested)

If the user includes a change request, parse their natural language and modify the specific setting. Common requests:

| User says | Action |
|---|---|
| "turn on behavioral tracking" | Set `behavioral_tracking` to `true` |
| "turn off behavioral tracking" | Set `behavioral_tracking` to `false` |
| "enable status line" | Set `status_line.enabled` to `true` |
| "disable status line" | Set `status_line.enabled` to `false` |
| "add project <name>" | Add a key to `projects` object |
| "remove project <name>" | Remove a key from `projects` object |
| "set transparency to concise" | Set `transparency` to `"concise"` |
| "set transparency to detailed" | Set `transparency` to `"detailed"` |
| "enable supabase" | Set `storage.supabase.enabled` to `true` (prompt for URL/key if not set) |
| "disable supabase" | Set `storage.supabase.enabled` to `false` |
| "enable drive" | Set `storage.google_drive.enabled` to `true` (prompt for folder_id if not set) |
| "disable drive" | Set `storage.google_drive.enabled` to `false` |
| "enable encryption" | Set `encryption.enabled` to `true` |
| "disable encryption" | Set `encryption.enabled` to `false` |
| "enable scribe-to-scribe" | Set `scribe_to_scribe.enabled` to `true` |
| "enable auto-accept" | Set `scribe_to_scribe.auto_accept` to `true` |
| "set name to X" | Set `user_profile.name` to X |
| "set role to X" | Set `user_profile.role` to X |
| "add skill <name> at <path>" | Add entry to `skill_integrations` |

## Step 5: Write changes

When making changes:
1. Read the full current config.json
2. Modify ONLY the specific field(s) requested
3. Write the full config back to config.json using the same formatting (2-space indent JSON)
4. NEVER delete or overwrite unrelated fields — only touch what was requested
5. Show a confirmation of what changed:

```
SCRIBE CONFIG UPDATED
  behavioral_tracking: false -> true
```

If the change requires additional information (e.g., enabling Supabase without a URL), ask the user for the missing values before writing.
