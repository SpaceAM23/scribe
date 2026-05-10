---
name: scribe-sync
description: Push local journal entries to enabled cloud targets (Supabase, Drive)
---

# Scribe Sync — Push Entries to Cloud Targets

Synchronize local journal entries with enabled cloud storage targets.

## Step 1: Resolve the data path

Read the pointer file to find the user's data directory:

```bash
cat ~/.claude/scribe/pointer.json
```

Extract the `data_path` value and expand `~` to the user's home directory. If pointer.json does not exist, tell the user: "Scribe data path not found. Run the Scribe installer or create ~/.claude/scribe/pointer.json with a data_path field pointing to your data directory."

## Step 2: Read config and check targets

Read `<data_path>/config.json` and check which storage targets are enabled:

- `storage.local.enabled` — local files (always primary, not a sync target)
- `storage.google_drive.enabled` — Google Drive sync
- `storage.supabase.enabled` — Supabase sync

If no cloud targets are enabled, tell the user: "No cloud targets enabled. Use /scribe-config to enable Supabase or Google Drive."

## Step 3: Count local entries

Count the total entries in the local journal:

```bash
wc -l < <data_path>/journal.jsonl
```

Also list the individual entry files:

```bash
ls <data_path>/entries/*.json 2>/dev/null | wc -l
```

## Step 4: Supabase sync (if enabled)

If `storage.supabase.enabled` is true:

1. Read the Supabase URL and anon key from config (or from environment variables if not in config)
2. Check if a `scribe_entries` table exists by querying Supabase
3. Read all local entries from `<data_path>/entries/` directory
4. For each entry, check if it already exists in Supabase by ID:
   ```bash
   curl -s -H "apikey: <anon_key>" -H "Authorization: Bearer <anon_key>" \
     "<supabase_url>/rest/v1/scribe_entries?id=eq.<entry_id>&select=id" | jq length
   ```
5. For entries not yet in Supabase, POST them:
   ```bash
   curl -s -X POST -H "apikey: <anon_key>" -H "Authorization: Bearer <anon_key>" \
     -H "Content-Type: application/json" -H "Prefer: return=minimal" \
     "<supabase_url>/rest/v1/scribe_entries" -d '<entry_json>'
   ```
6. Track how many were synced vs. already present

**Important**: Process entries in batches if there are many. Never send more than 50 in a single request. Paginate reads.

## Step 5: Google Drive sync (if enabled)

If `storage.google_drive.enabled` is true:

1. Check for `.drive-pending` marker files in `<data_path>/entries/`:
   ```bash
   ls <data_path>/entries/*.drive-pending 2>/dev/null
   ```
2. Drive sync requires the Google Drive MCP connection. If MCP tools are available, use them to upload pending entries to the configured Drive folder.
3. If MCP tools are not available, report the count of pending entries and tell the user: "Drive sync requires the Google Drive MCP connection. X entries are pending upload. Use Claude Desktop or Claude Web App with Drive MCP to complete the sync."

## Step 6: Report results

Display a summary:

```
SCRIBE SYNC COMPLETE
====================

Local entries: <total>

Supabase:
  Synced: <newly_pushed> entries
  Already in sync: <existing> entries
  Status: UP TO DATE (or PARTIAL — see errors below)

Google Drive:
  Pending: <count> entries
  Status: <synced/pending/not enabled>
```

If any errors occurred during sync, list them at the bottom with the entry ID and error message. Never silently swallow errors.
