---
name: scribe-export
description: Export journal entries as JSON, CSV, or markdown
---

# Scribe Export — Export Journal Data

Export journal entries to a file in the user's chosen format.

## Step 1: Resolve the data path

Read the pointer file to find the user's data directory:

```bash
cat ~/.claude/scribe/pointer.json
```

Extract the `data_path` value and expand `~` to the user's home directory. If pointer.json does not exist, tell the user: "Scribe data path not found. Run the Scribe installer or create ~/.claude/scribe/pointer.json with a data_path field pointing to your data directory."

## Step 2: Parse arguments

Parse the user's message for these options:

- **Format**: `json` (default), `csv`, or `markdown` / `md`
- **Filters** (all optional):
  - `--project <name>` — filter by project
  - `--type <type>` — filter by entry type
  - `--since <date>` — filter entries on or after this date (YYYY-MM-DD)
- **Output path**: if the user specifies a path, use it. Otherwise, write to the current working directory with a default name: `scribe-export-<date>.<ext>`

## Step 3: Query and filter entries

Read entries from `<data_path>/journal.jsonl` and apply any filters using jq (same approach as /scribe-list). Collect all matching entries into a sorted array (newest first).

If no entries match, tell the user: "No entries match the specified filters. Nothing to export."

## Step 4: Generate the export

### JSON format

Write the entries as a JSON array of full entry objects:

```bash
cat <data_path>/journal.jsonl | jq -s '<filter_expression> | sort_by(.timestamp) | reverse' > <output_path>
```

File extension: `.json`

### CSV format

Flatten each entry to these columns: `id`, `timestamp`, `project`, `type`, `title`, `summary`, `tags`

- `tags` should be a semicolon-separated string from `connections.tags[]`
- Escape commas and newlines in summary fields
- Include a header row

Write using jq to generate CSV:

```bash
cat <data_path>/journal.jsonl | jq -rs '<filter> | sort_by(.timestamp) | reverse | ["id","timestamp","project","type","title","summary","tags"], (.[] | [.id, .timestamp, .project, .type, .title, (.summary | gsub("\n";" ") | gsub(",";";")), ((.connections.tags // []) | join(";"))]) | @csv' > <output_path>
```

File extension: `.csv`

### Markdown format

Generate a formatted document with each entry as a section:

```markdown
# Scribe Journal Export
Generated: <date>
Entries: <count>
Filters: <filters applied or "none">

---

## <title>
**Date**: <timestamp> | **Project**: <project> | **Type**: <type>
**ID**: <full_id>

<summary>

**Decisions**:
- <decision 1>
- <decision 2>

**Learnings**:
- <learning 1>

**Corrections**:
- <correction 1>

**Tags**: <tag1>, <tag2>

---
```

Only include Decisions/Learnings/Corrections sections if the entry has them. File extension: `.md`

## Step 5: Write the file

Write the output to the resolved path. Use the Write tool for markdown and JSON, or bash for CSV.

Default output filenames:
- `scribe-export-2026-05-10.json`
- `scribe-export-2026-05-10.csv`
- `scribe-export-2026-05-10.md`

## Step 6: Report

Tell the user:

```
SCRIBE EXPORT COMPLETE
  Format: <format>
  Entries: <count> exported
  Filters: <filters or "none">
  Output: <absolute_path>
```
