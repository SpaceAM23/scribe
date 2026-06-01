#!/usr/bin/env bash
# scripts/reconcile.sh — Replay sync-queue.jsonl to Supabase and reconcile counts.
#
# Replays each entry in sync-queue.jsonl via INSERT...ON CONFLICT (id) DO NOTHING.
# On success, removes the replayed line from the queue.
# After replay, compares local journal.jsonl line count vs Supabase row count.
# Prints before/after counts and delta.
#
# Usage:
#   ~/Desktop/Scribe/scripts/reconcile.sh
#
# Requires: SCRIBE_DATA_PATH (or default ~/Desktop/Scribe), psql, SCRIBE_DB_PASSWORD or PGPASSWORD

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Resolve data dir — same priority as writer.sh
resolve_data_path() {
  if [ -n "${SCRIBE_DATA_PATH:-}" ]; then
    echo "$SCRIBE_DATA_PATH"
    return
  fi
  local pointer="$SCRIPT_DIR/../pointer.json"
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
SYNC_QUEUE="$DATA_DIR/sync-queue.jsonl"
JOURNAL="$DATA_DIR/journal.jsonl"
CONFIG_FILE="$DATA_DIR/config.json"
ENV_FILE="$DATA_DIR/.env"

# Load environment
if [ -f "$ENV_FILE" ]; then
  while IFS='=' read -r key value; do
    case "$key" in \#*|"") continue ;; esac
    value="${value%\"}" ; value="${value#\"}"
    value="${value%\'}" ; value="${value#\'}"
    export "$key"="$value"
  done < "$ENV_FILE"
fi

# Find psql
find_psql() {
  if command -v psql &>/dev/null; then command -v psql; return; fi
  for p in "/usr/local/bin/psql" "/opt/homebrew/bin/psql" "/usr/bin/psql"; do
    if [ -x "$p" ] 2>/dev/null; then echo "$p"; return; fi
  done
  return 1
}

PSQL_BIN=$(find_psql 2>/dev/null || true)
if [ -z "$PSQL_BIN" ]; then
  echo "ERROR: psql not found. Cannot reconcile." >&2
  exit 1
fi

# Load Supabase connection
SUPABASE_DB_CONN=$(jq -r '.storage.supabase.db_connection // empty' "$CONFIG_FILE" 2>/dev/null || true)
if [ -z "$SUPABASE_DB_CONN" ]; then
  # No hardcoded fallback — the product requires config
  echo "ERROR: configure .storage.supabase.db_connection in config.json" >&2; exit 1
fi

DB_PASSWORD="${SCRIBE_DB_PASSWORD:-${PGPASSWORD:-}}"
if [ -z "$DB_PASSWORD" ]; then
  echo "ERROR: No database password found (SCRIBE_DB_PASSWORD or PGPASSWORD)." >&2
  exit 1
fi

echo "=== Scribe Reconcile ==="
echo "Data dir: $DATA_DIR"
echo ""

# --- Count local entries ---
LOCAL_COUNT=0
if [ -f "$JOURNAL" ]; then
  LOCAL_COUNT=$(wc -l < "$JOURNAL" | tr -d '[:space:]')
fi
echo "Local journal.jsonl: $LOCAL_COUNT entries"

# --- Count Supabase entries ---
REMOTE_COUNT=$(PGPASSWORD="$DB_PASSWORD" "$PSQL_BIN" "$SUPABASE_DB_CONN" \
  -t -c "SELECT COUNT(*) FROM journal_entries;" 2>/dev/null | tr -d '[:space:]' || echo "ERROR")
echo "Supabase journal_entries: $REMOTE_COUNT entries"

DELTA=$((LOCAL_COUNT - ${REMOTE_COUNT:-0}))
echo "Delta (local - remote): $DELTA"
echo ""

# --- Replay sync queue ---
if [ ! -f "$SYNC_QUEUE" ] || [ ! -s "$SYNC_QUEUE" ]; then
  echo "sync-queue.jsonl is empty — nothing to replay."
else
  QUEUE_COUNT=$(wc -l < "$SYNC_QUEUE" | tr -d '[:space:]')
  echo "Replaying $QUEUE_COUNT queued entries..."

  SUCCEEDED=0
  FAILED=0
  TEMP_QUEUE="$SYNC_QUEUE.tmp.$$"
  touch "$TEMP_QUEUE"

  while IFS= read -r line; do
    [ -z "$line" ] && continue

    ESCAPED=$(echo "$line" | jq -c \
      'del(._queued_at)' | sed "s/'/''/g")

    SQL="INSERT INTO journal_entries (id, timestamp, session_id, user_id, project, type, title, summary, decisions, learnings, corrections, metrics, connections, growth, behavioral)
    SELECT
      (v->>'id')::uuid,
      (v->>'timestamp')::timestamptz,
      v->>'session_id',
      v->>'user_id',
      v->>'project',
      v->>'type',
      v->>'title',
      v->>'summary',
      (v->'decisions')::jsonb,
      (v->'learnings')::jsonb,
      (v->'corrections')::jsonb,
      (v->'metrics')::jsonb,
      (v->'connections')::jsonb,
      (v->'growth')::jsonb,
      (v->'behavioral')::jsonb
    FROM jsonb_array_elements('[${ESCAPED}]'::jsonb) AS v
    ON CONFLICT (id) DO NOTHING;"

    if PGPASSWORD="$DB_PASSWORD" "$PSQL_BIN" "$SUPABASE_DB_CONN" -c "$SQL" > /dev/null 2>&1; then
      SUCCEEDED=$((SUCCEEDED + 1))
      echo "  OK: $(echo "$line" | jq -r '.id // "unknown"' | cut -c1-8)"
    else
      FAILED=$((FAILED + 1))
      echo "  FAIL: $(echo "$line" | jq -r '.id // "unknown"' | cut -c1-8) — keeping in queue"
      echo "$line" >> "$TEMP_QUEUE"
    fi
  done < "$SYNC_QUEUE"

  mv "$TEMP_QUEUE" "$SYNC_QUEUE"

  echo ""
  echo "Replay complete: $SUCCEEDED succeeded, $FAILED failed."

  # --- Re-count after replay ---
  REMOTE_COUNT_AFTER=$(PGPASSWORD="$DB_PASSWORD" "$PSQL_BIN" "$SUPABASE_DB_CONN" \
    -t -c "SELECT COUNT(*) FROM journal_entries;" 2>/dev/null | tr -d '[:space:]' || echo "ERROR")
  echo ""
  echo "=== After reconcile ==="
  echo "Local:  $LOCAL_COUNT"
  echo "Remote: $REMOTE_COUNT_AFTER"
  DELTA_AFTER=$((LOCAL_COUNT - ${REMOTE_COUNT_AFTER:-0}))
  echo "Delta:  $DELTA_AFTER"
  if [ "$DELTA_AFTER" -eq 0 ]; then
    echo "STATUS: IN SYNC"
  else
    echo "STATUS: $DELTA_AFTER entries still unsynced (check sync-queue.jsonl)"
  fi
fi
