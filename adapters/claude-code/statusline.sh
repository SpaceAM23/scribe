#!/usr/bin/env bash
# statusline.sh — Scribe status line segment for Claude Code
# Outputs: SCRIBE: N SESSION / M TOTAL | LRN X | COR X | DEC X | FEAT X | BUG X
#
# Usage: Add to your ~/.claude/statusline-command.sh or call directly.
# Reads from the user's Scribe data directory.

set -euo pipefail

# Resolve data path
resolve_data_path() {
  if [ -n "${SCRIBE_DATA_PATH:-}" ]; then
    echo "$SCRIBE_DATA_PATH"
    return
  fi

  local pointer="$HOME/.claude/scribe/pointer.json"
  if [ -f "$pointer" ]; then
    local ptr_path
    ptr_path=$(jq -r '.data_path // empty' "$pointer" 2>/dev/null || true)
    if [ -n "$ptr_path" ]; then
      echo "${ptr_path/#\~/$HOME}"
      return
    fi
  fi

  echo "$HOME/Desktop/Scribe"
}

DATA_DIR="$(resolve_data_path)"
INDEX="$DATA_DIR/index.json"
JOURNAL="$DATA_DIR/journal.jsonl"
SESSION_COUNTER="$DATA_DIR/session-counter.json"

# Check if Scribe data exists
if [ ! -f "$INDEX" ]; then
  echo "SCRIBE: NOT CONFIGURED"
  exit 0
fi

# Total entries from index
TOTAL=$(jq -r '.total_entries // 0' "$INDEX" 2>/dev/null || echo "0")

# Session entries — count entries from current session
# The session counter tracks the current session_id
SESSION_COUNT=0
if [ -f "$SESSION_COUNTER" ]; then
  CURRENT_SESSION=$(jq -r '.current_session_id // empty' "$SESSION_COUNTER" 2>/dev/null || true)
  if [ -n "$CURRENT_SESSION" ] && [ -f "$JOURNAL" ]; then
    SESSION_COUNT=$(grep -c "\"session_id\":\"$CURRENT_SESSION\"" "$JOURNAL" 2>/dev/null) || SESSION_COUNT=0
  fi
fi

# Growth summary counts from index
LRN=$(jq -r '.growth_summary.total_learnings // 0' "$INDEX" 2>/dev/null || echo "0")
FEAT=$(jq -r '.growth_summary.total_features // 0' "$INDEX" 2>/dev/null || echo "0")
BUG=$(jq -r '.growth_summary.total_bugs_fixed // 0' "$INDEX" 2>/dev/null || echo "0")
COR=$(jq -r '.growth_summary.total_corrections // 0' "$INDEX" 2>/dev/null || echo "0")

# Decision count — not in growth_summary by default, count from journal
DEC=0
if [ -f "$JOURNAL" ]; then
  DEC=$(grep -c '"type":"decision_made"' "$JOURNAL" 2>/dev/null) || DEC=0
fi

echo "SCRIBE: $SESSION_COUNT SESSION / $TOTAL TOTAL | LRN $LRN | COR $COR | DEC $DEC | FEAT $FEAT | BUG $BUG"
