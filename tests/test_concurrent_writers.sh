#!/usr/bin/env bash
# tests/test_concurrent_writers.sh
# Proves the writer lock serializes parallel writers.
# Launches 10 concurrent core/writer.sh runs with distinct entries and asserts:
#   1. every writer process exits 0
#   2. journal.jsonl line count == 10 (no lost or doubled appends)
#   3. index.json total_entries == journal line count (no lost read-modify-write)
#   4. all entry ids in the journal are unique
#   5. index.json and every journal line are valid JSON (no torn writes)
# Uses a scratch SCRIBE_DATA_PATH — never touches a real journal.
# bash 3.2-compatible: no 'wait -n', no associative arrays, no ${var,,}.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/scribe-test-XXXXXX")"
export SCRIBE_DATA_PATH="$SCRATCH"
trap 'rm -rf "$SCRATCH"' EXIT

# Seed the scratch data dir the way an install would: schema + canonical dir
cp "$REPO_DIR/core/schema.json" "$SCRATCH/"
mkdir -p "$SCRATCH/canonical"
printf '{"projects":["scribe","meta"],"aliases":{}}\n' > "$SCRATCH/canonical/projects.json"
cp "$REPO_DIR/templates/correction-patterns.template.json" "$SCRATCH/canonical/correction-patterns.json"

WRITER="$REPO_DIR/core/writer.sh"
N=10

# ---------------------------------------------------------------------------
# Case 1: launch N writers in parallel, wait for all, require all exit 0
# ---------------------------------------------------------------------------
echo "--- Case 1: $N parallel writers all exit 0 ---"

PIDS=""
i=1
while [ "$i" -le "$N" ]; do
  hex=$(printf '%02d' "$i")
  # Distinct id + title + summary per writer so content-hash dedup never
  # collapses them; ids are valid lowercase v4-shaped uuids.
  ENTRY=$(printf '{"id":"cafe00%s-0000-4000-8000-0000000000%s","timestamp":"2026-07-01T10:%s:00Z","session_id":"conc-test","project":"scribe","type":"milestone","title":"Concurrent writer test %s","summary":"Parallel writer run number %s with unique content for hashing."}' \
    "$hex" "$hex" "$hex" "$i" "$i")
  printf '%s' "$ENTRY" | "$WRITER" >/dev/null 2>>"$SCRATCH/writer-stderr.log" &
  PIDS="$PIDS $!"
  i=$((i + 1))
done

FAILED=0
for pid in $PIDS; do
  if ! wait "$pid"; then
    FAILED=$((FAILED + 1))
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo "FAIL Case 1: $FAILED of $N writer processes exited non-zero"
  echo "--- writer stderr ---"
  cat "$SCRATCH/writer-stderr.log" 2>/dev/null || true
  exit 1
fi
echo "PASS Case 1"

# ---------------------------------------------------------------------------
# Case 2: journal line count == N and every line is valid JSON
# ---------------------------------------------------------------------------
echo "--- Case 2: journal has exactly $N valid JSON lines ---"

JOURNAL_LINES=$(wc -l < "$SCRATCH/journal.jsonl" 2>/dev/null || echo 0)
JOURNAL_LINES="${JOURNAL_LINES//[[:space:]]/}"
if [ "$JOURNAL_LINES" -ne "$N" ]; then
  echo "FAIL Case 2: journal has $JOURNAL_LINES lines (want $N)"
  exit 1
fi
PARSED_LINES=$(jq -s 'length' "$SCRATCH/journal.jsonl" 2>/dev/null || echo "parse-error")
if [ "$PARSED_LINES" != "$N" ]; then
  echo "FAIL Case 2: journal parsed to $PARSED_LINES entries (want $N) — torn/invalid line"
  exit 1
fi
echo "PASS Case 2"

# ---------------------------------------------------------------------------
# Case 3: index.json is valid JSON and total_entries == journal line count
# ---------------------------------------------------------------------------
echo "--- Case 3: index.json total_entries == journal line count ---"

if ! jq empty "$SCRATCH/index.json" 2>/dev/null; then
  echo "FAIL Case 3: index.json is missing or invalid JSON"
  exit 1
fi
INDEX_TOTAL=$(jq -r '.total_entries' "$SCRATCH/index.json")
if [ "$INDEX_TOTAL" != "$JOURNAL_LINES" ]; then
  echo "FAIL Case 3: index.json total_entries=$INDEX_TOTAL, journal lines=$JOURNAL_LINES (lost increment race)"
  exit 1
fi
echo "PASS Case 3 (total_entries=$INDEX_TOTAL)"

# ---------------------------------------------------------------------------
# Case 4: all entry ids unique
# ---------------------------------------------------------------------------
echo "--- Case 4: all $N entry ids unique ---"

UNIQUE_IDS=$(jq -r '.id' "$SCRATCH/journal.jsonl" | sort -u | wc -l)
UNIQUE_IDS="${UNIQUE_IDS//[[:space:]]/}"
if [ "$UNIQUE_IDS" -ne "$JOURNAL_LINES" ]; then
  echo "FAIL Case 4: $UNIQUE_IDS unique ids for $JOURNAL_LINES journal lines"
  jq -r '.id' "$SCRATCH/journal.jsonl" | sort | uniq -d
  exit 1
fi
echo "PASS Case 4"

echo "ALL PASS"
