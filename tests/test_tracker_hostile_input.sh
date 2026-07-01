#!/usr/bin/env bash
# tests/test_tracker_hostile_input.sh
# Proves hostile correction text cannot crash the writer or corrupt the
# correction tracker. The correction contains:
#   - escaped double quotes  (\" in the JSON -> literal " in the value)
#   - real newlines          (\n in the JSON -> LF in the value)
#   - Python triple-quote sequences ("""...""" and '''...''')
# An inline-heredoc tracker that substitutes the entry into Python source
# crashes (or worse) on exactly this input. The stdin-piped
# core/track-corrections.py must survive it losslessly.
# Uses a scratch SCRIBE_DATA_PATH — never touches a real journal.
# bash 3.2-compatible.

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

# Quoted heredoc: the shell does not touch a single byte of this JSON.
# The correction value (after JSON parsing) contains literal double quotes,
# two real newlines, a """triple quote""" and a '''triple quote''' sequence.
cat > "$SCRATCH/hostile-entry.json" <<'JSON'
{"id":"deadbeef-0000-4000-8000-000000000001","timestamp":"2026-07-01T12:00:00Z","session_id":"hostile-test","project":"scribe","type":"correction","title":"Hostile tracker input test","summary":"Correction text is hostile to naive shell or Python interpolation.","corrections":["Zebra correction with \"escaped double quotes\", a\nreal newline, another\nnewline, a Python \"\"\"triple quote\"\"\" sequence and '''single triple''' too; docstring terminator \"\"\" mid-text."]}
JSON

# ---------------------------------------------------------------------------
# Case 1: writer survives the hostile entry (exit 0, no tracker-failure WARN)
# ---------------------------------------------------------------------------
echo "--- Case 1: writer exits 0 on hostile correction ---"

set +e
"$WRITER" < "$SCRATCH/hostile-entry.json" > "$SCRATCH/writer-stdout.log" 2> "$SCRATCH/writer-stderr.log"
WRITER_RC=$?
set -e

if [ "$WRITER_RC" -ne 0 ]; then
  echo "FAIL Case 1: writer exited $WRITER_RC"
  cat "$SCRATCH/writer-stderr.log"
  exit 1
fi
if grep -q "correction-tracker update failed" "$SCRATCH/writer-stderr.log" 2>/dev/null; then
  echo "FAIL Case 1: writer exited 0 but the tracker update crashed (WARN in stderr)"
  cat "$SCRATCH/writer-stderr.log"
  exit 1
fi
echo "PASS Case 1"

# ---------------------------------------------------------------------------
# Case 2: journal got exactly 1 valid JSON line with the correction intact
# ---------------------------------------------------------------------------
echo "--- Case 2: journal entry written and valid ---"

JOURNAL_LINES=$(wc -l < "$SCRATCH/journal.jsonl" 2>/dev/null || echo 0)
JOURNAL_LINES="${JOURNAL_LINES//[[:space:]]/}"
if [ "$JOURNAL_LINES" -ne 1 ]; then
  echo "FAIL Case 2: journal has $JOURNAL_LINES lines (want 1)"
  exit 1
fi
CORR_IN_JOURNAL=$(jq -r '.corrections[0] // empty' "$SCRATCH/journal.jsonl" 2>/dev/null)
case "$CORR_IN_JOURNAL" in
  *'"""triple quote"""'*) : ;;
  *)
    echo "FAIL Case 2: journal correction text lost the triple-quote sequence"
    exit 1
    ;;
esac
echo "PASS Case 2"

# ---------------------------------------------------------------------------
# Case 3: correction-tracker.json is valid JSON and recorded the occurrence
#         with the hostile text preserved
# ---------------------------------------------------------------------------
echo "--- Case 3: tracker valid and occurrence recorded losslessly ---"

if [ ! -f "$SCRATCH/correction-tracker.json" ]; then
  echo "FAIL Case 3: correction-tracker.json was not created"
  exit 1
fi
if ! jq empty "$SCRATCH/correction-tracker.json" 2>/dev/null; then
  echo "FAIL Case 3: correction-tracker.json is corrupt (invalid JSON)"
  exit 1
fi
OCC_COUNT=$(jq '[.patterns[].occurrences[]] | length' "$SCRATCH/correction-tracker.json")
if [ "$OCC_COUNT" -ne 1 ]; then
  echo "FAIL Case 3: tracker has $OCC_COUNT occurrences (want 1)"
  exit 1
fi
CONTEXT=$(jq -r '[.patterns[].occurrences[].context] | .[0]' "$SCRATCH/correction-tracker.json")
case "$CONTEXT" in
  *'"""triple quote"""'*) : ;;
  *)
    echo "FAIL Case 3: tracker occurrence context lost the triple-quote sequence"
    printf 'context was: %s\n' "$CONTEXT"
    exit 1
    ;;
esac
case "$CONTEXT" in
  *'escaped double quotes'*) : ;;
  *)
    echo "FAIL Case 3: tracker occurrence context lost the quoted segment"
    exit 1
    ;;
esac
echo "PASS Case 3"

# ---------------------------------------------------------------------------
# Case 4: a second (normal) correction still updates the tracker cleanly —
#         the hostile entry left no lingering damage
# ---------------------------------------------------------------------------
echo "--- Case 4: tracker still updatable after hostile input ---"

printf '{"id":"deadbeef-0000-4000-8000-000000000002","timestamp":"2026-07-01T12:30:00Z","session_id":"hostile-test","project":"scribe","type":"correction","title":"Follow-up normal correction","summary":"A plain follow-up correction after the hostile one.","corrections":["Plain zebra follow-up correction with no special characters."]}' \
  | "$WRITER" >/dev/null 2>&1

if ! jq empty "$SCRATCH/correction-tracker.json" 2>/dev/null; then
  echo "FAIL Case 4: tracker corrupt after second write"
  exit 1
fi
OCC_COUNT2=$(jq '[.patterns[].occurrences[]] | length' "$SCRATCH/correction-tracker.json")
if [ "$OCC_COUNT2" -ne 2 ]; then
  echo "FAIL Case 4: tracker has $OCC_COUNT2 occurrences (want 2)"
  exit 1
fi
echo "PASS Case 4"

echo "ALL PASS"
