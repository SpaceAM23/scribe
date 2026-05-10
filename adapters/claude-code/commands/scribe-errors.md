---
name: scribe-errors
description: View, review, and submit Scribe error reports to GitHub
---

You are handling the `/scribe-errors` command for Scribe.

## Data Path Resolution

Read `~/.claude/scribe/pointer.json` to get `data_path`. Expand `~` to `$HOME`. The errors log is at `$DATA_PATH/errors.jsonl`.

## Sub-Commands

The user may specify a sub-command or just type `/scribe-errors` for a summary.

### Default (no sub-command): Error Summary

Read `$DATA_PATH/errors.jsonl`. If it doesn't exist or is empty, report "No errors recorded."

Display a summary:

```
SCRIBE ERROR LOG
================
Total errors: N (M unsubmitted)

COMPONENT        COUNT   LAST SEEN
writer           3       2026-05-10
observer         1       2026-05-09
mcp-server       0       —

RECENT ERRORS (last 5):
  [2026-05-10 15:03] writer/io — Failed to write entry file (entry_id: abc123)
  [2026-05-10 14:58] writer/validation — Missing required field: user_id
  ...
```

### `review`: Detailed Error View

Display each unsubmitted error with full incident details:

```
ERROR #1 — abc12345
  Time:      2026-05-10T15:03:00Z
  Component: writer
  Type:      io
  Message:   Failed to write entry file
  Context:   entry_id=abc123, target=local, disk_space=low
  System:    Darwin 23.6.0, bash 3.2.57, jq 1.7, 171 entries
  Version:   0.1.0
  Platform:  claude-code
  Submitted: no

ERROR #2 — def67890
  ...
```

### `submit`: Submit Errors to GitHub

This creates a GitHub issue on `SpaceAM23/scribe` with all unsubmitted errors.

**Before submitting, sanitize the data:**
1. Remove any user names, project names, or entry content from the error messages
2. Replace project names with `[project]`
3. Replace user names with `[user]`
4. Replace file paths with relative paths (strip home directory)
5. Keep: component, error type, message structure, system conditions, version, platform, timestamps

**Build the GitHub issue:**

```bash
gh issue create \
  --repo SpaceAM23/scribe \
  --title "[ERROR REPORT] N errors from Scribe v0.1.0 on [platform]" \
  --label "scribe-error-report,bug" \
  --body "$(cat <<'BODY'
## Scribe Error Report

**Version**: 0.1.0
**Platform**: claude-code
**OS**: Darwin 23.6.0
**Submitted**: 2026-05-10T16:00:00Z

## System Conditions
- Bash: 3.2.57
- jq: 1.7
- Total entries at time of report: 171
- Config exists: yes

## Errors (N total)

### Error 1 — writer/io
- **Time**: 2026-05-10T15:03:00Z
- **Message**: Failed to write entry file
- **Context**: target=local
- **Stack**: [if available]

### Error 2 — writer/validation
...

## Reproduction Context
[User can optionally add what they were doing]

---
*Automated report from Scribe error telemetry*
BODY
)"
```

After submitting:
1. Mark all submitted errors as `"submitted": true` in errors.jsonl (rewrite the file with updated flags)
2. Display: "Submitted N errors as GitHub issue #[number]. Apollo will review."
3. Show the issue URL

### `clear`: Clear Resolved Errors

Remove errors that have been submitted from the log. Keep unsubmitted ones.

```bash
# Filter to only unsubmitted errors
jq -c 'select(.submitted == false)' "$DATA_PATH/errors.jsonl" > "$DATA_PATH/errors.jsonl.tmp"
mv "$DATA_PATH/errors.jsonl.tmp" "$DATA_PATH/errors.jsonl"
```

Report: "Cleared N submitted errors. M unsubmitted remain."

## Important Rules

- **Never suppress errors.** If Scribe encounters an error, it MUST be logged. Silent failures are the enemy.
- **Sanitize before submitting.** User data (names, projects, entry content) must be stripped. Only structural/technical data goes to GitHub.
- **The user decides when to submit.** Error capture is automatic. Submission is manual and opt-in.
- **Include system conditions.** OS, bash version, jq version, entry count, config state — these are critical for debugging.
