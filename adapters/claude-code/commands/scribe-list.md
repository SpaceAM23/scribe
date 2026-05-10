---
name: scribe-list
description: Browse and search journal entries with optional filters
---

# Scribe List — Browse and Search Entries

List journal entries with optional filters. Parse the user's arguments for filter options.

## Step 1: Resolve the data path

Read the pointer file to find the user's data directory:

```bash
cat ~/.claude/scribe/pointer.json
```

Extract the `data_path` value and expand `~` to the user's home directory. If pointer.json does not exist, tell the user: "Scribe data path not found. Run the Scribe installer or create ~/.claude/scribe/pointer.json with a data_path field pointing to your data directory."

## Step 2: Parse filter arguments

The user may provide filters after the command. Parse these from the user's message:

- `--project <name>` — filter by project name (case-insensitive match)
- `--type <type>` — filter by entry type (e.g., correction, decision_made, learning)
- `--since <date>` — filter entries on or after this date (YYYY-MM-DD)
- `--search <term>` — full-text search across title and summary
- `--limit <n>` — max entries to show (default: 20)

If the user provides no filters, show the 20 most recent entries.

## Step 3: Query the journal

Read and filter `journal.jsonl` from the data path using jq. Build the jq filter based on the user's arguments.

**No filters (default — last 20):**
```bash
tail -100 <data_path>/journal.jsonl | jq -s 'sort_by(.timestamp) | reverse | .[:20]'
```

**With filters, build a jq select expression.** Examples:

Project filter:
```bash
cat <data_path>/journal.jsonl | jq -s '[.[] | select(.project == "<project>")] | sort_by(.timestamp) | reverse | .[:20]'
```

Type filter:
```bash
cat <data_path>/journal.jsonl | jq -s '[.[] | select(.type == "<type>")] | sort_by(.timestamp) | reverse | .[:20]'
```

Since filter:
```bash
cat <data_path>/journal.jsonl | jq -s '[.[] | select(.timestamp >= "<date>")] | sort_by(.timestamp) | reverse | .[:20]'
```

Search filter:
```bash
cat <data_path>/journal.jsonl | jq -s '[.[] | select((.title | ascii_downcase | contains("<term>")) or (.summary | ascii_downcase | contains("<term>")))] | sort_by(.timestamp) | reverse | .[:20]'
```

Combine multiple filters with `and` in the select expression. Apply the user's `--limit` value if provided, otherwise cap at 20.

## Step 4: Count total matches

Before applying the limit, get the total count of matching entries so you can report it.

## Step 5: Display results

Format as a table:

```
SCRIBE ENTRIES (<total_matching> matching, showing <displayed>)

ID          DATE        PROJECT      TYPE             TITLE
--------    ----------  -----------  ---------------  ----------------------------------
a1b2c3d4    2026-05-08  blackfin     decision_made    Adopted medallion architecture
e5f6g7h8    2026-05-09  blackfin     correction       Missed RLS policy on vendor table
i9j0k1l2    2026-05-10  naturejab    feature_shipped  Shipped asset gallery component
```

Rules:
- Show first 8 characters of the entry ID
- Format dates as YYYY-MM-DD
- Sort by date descending (newest first)
- If no entries match, say "No entries found matching your filters."
- If journal.jsonl does not exist or is empty, say "No entries yet. Scribe will begin recording during your next session."
- Truncate titles longer than 50 characters with "..."
- Show the total matching count and how many are displayed
