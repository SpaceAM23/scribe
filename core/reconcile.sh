#!/usr/bin/env bash
# core/reconcile.sh — Replay sync-queue.jsonl to Supabase and reconcile counts.
#
# Replays each entry in sync-queue.jsonl via INSERT...ON CONFLICT (id) DO NOTHING.
# On success, removes the replayed line from the queue.
# Permanently-failing entries (bad casts, constraint violations, unparseable
# queue lines) and entries that exceed MAX_ATTEMPTS are moved to
# sync-dead-letter.jsonl — annotated, never deleted — so the queue can never
# wedge on a poison message.
# After replay, compares local journal.jsonl line count vs Supabase row count.
# Prints before/after counts and delta.
#
# Signal-safe: temp files (snapshot/tmp/err/swap-guard) are cleaned up on every
# exit path — success, set -e abort, SIGINT, SIGTERM.
#
# Usage:
#   core/reconcile.sh
#
# Requires: SCRIBE_DATA_PATH (or pointer.json, or default ~/Desktop/Scribe),
#           psql, SCRIBE_DB_PASSWORD or PGPASSWORD (see templates/.env.example)

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
  if command -v psql >/dev/null 2>&1; then command -v psql; return; fi
  for p in "/usr/local/bin/psql" "/opt/homebrew/bin/psql" "/opt/homebrew/opt/libpq/bin/psql" "/usr/bin/psql"; do
    if [ -x "$p" ] 2>/dev/null; then echo "$p"; return; fi
  done
  return 1
}

PSQL_BIN=$(find_psql 2>/dev/null || true)
if [ -z "$PSQL_BIN" ]; then
  echo "ERROR: psql not found. Cannot reconcile." >&2
  exit 1
fi

# Load Supabase connection — the product requires config, no hardcoded fallback
SUPABASE_DB_CONN=$(jq -r '.storage.supabase.db_connection // empty' "$CONFIG_FILE" 2>/dev/null || true)
if [ -z "$SUPABASE_DB_CONN" ]; then
  echo "ERROR: configure .storage.supabase.db_connection in config.json" >&2
  exit 1
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

# Sanitize: on connection failure REMOTE_COUNT is "ERROR" — treat as 0 so the
# arithmetic below doesn't abort the script under set -u before replay runs.
case "$REMOTE_COUNT" in ''|*[!0-9]*) REMOTE_COUNT_NUM=0 ;; *) REMOTE_COUNT_NUM=$REMOTE_COUNT ;; esac
DELTA=$((LOCAL_COUNT - REMOTE_COUNT_NUM))
echo "Delta (local - remote): $DELTA"
echo ""

# --- Replay sync queue ---
DEAD_LETTER="$DATA_DIR/sync-dead-letter.jsonl"
MAX_ATTEMPTS=5

# Temp-file hygiene: clean up the snapshot/tmp/err/swap-guard files on EVERY
# exit path (success, set -e abort, signal). Without this trap, an abort
# mid-replay leaks sync-queue.jsonl.snap.*/.tmp.*/.err.* forever. Removing
# TEMP_QUEUE on abort is safe: the live queue is untouched until the final mv,
# and replays are idempotent (INSERT ... ON CONFLICT DO NOTHING).
SNAPSHOT=""
TEMP_QUEUE=""
ERR_TMP=""
SWAP_GUARD=""
cleanup_replay_tmp() {
  [ -n "$SNAPSHOT" ]   && rm -f "$SNAPSHOT"   2>/dev/null
  [ -n "$TEMP_QUEUE" ] && rm -f "$TEMP_QUEUE" 2>/dev/null
  [ -n "$ERR_TMP" ]    && rm -f "$ERR_TMP"    2>/dev/null
  [ -n "$SWAP_GUARD" ] && rm -f "$SWAP_GUARD" 2>/dev/null
  return 0
}
trap cleanup_replay_tmp EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Permanent (non-transient) psql errors — these will never succeed on retry:
# bad uuid/enum casts, constraint violations, malformed payloads, SQL syntax
# breakage from bad escaping. Connection/timeout/SSL errors are NOT matched,
# so genuinely transient failures keep retrying (up to MAX_ATTEMPTS).
is_permanent_error() {
  echo "$1" | grep -qiE 'invalid input syntax for type|invalid input value for enum|violates [a-z-]* ?[a-z]* constraint|violates not-null constraint|malformed array literal|cannot cast|syntax error at or near|null value in column|value too long for type'
}

if [ ! -f "$SYNC_QUEUE" ] || [ ! -s "$SYNC_QUEUE" ]; then
  echo "sync-queue.jsonl is empty — nothing to replay."
else
  # Snapshot the queue so lines appended by a live writer.sh mid-replay are
  # not lost when we swap the rebuilt queue into place.
  SNAPSHOT="$SYNC_QUEUE.snap.$$"
  cp "$SYNC_QUEUE" "$SNAPSHOT"
  QUEUE_COUNT=$(wc -l < "$SNAPSHOT" | tr -d '[:space:]')
  echo "Replaying $QUEUE_COUNT queued entries..."

  SUCCEEDED=0
  FAILED=0
  DEADLETTERED=0
  TEMP_QUEUE="$SYNC_QUEUE.tmp.$$"
  ERR_TMP="$SYNC_QUEUE.err.$$"
  touch "$TEMP_QUEUE"

  while IFS= read -r line; do
    [ -z "$line" ] && continue

    SHORT_ID=$(echo "$line" | jq -r '.id // "unknown"' 2>/dev/null | head -1 | cut -c1-8 || echo "unknown")
    ATTEMPTS=$(echo "$line" | jq -r '._sync_attempts // 0' 2>/dev/null || echo 0)
    case "$ATTEMPTS" in ''|*[!0-9]*) ATTEMPTS=0 ;; esac
    ATTEMPTS=$((ATTEMPTS + 1))

    # Strip queue bookkeeping (_queued_at, _sync_attempts, _last_error, ...)
    # from the payload sent to Supabase.
    # Guard the jq — a single malformed queue line previously aborted the
    # entire replay under set -e, wedging reconcile permanently and leaking
    # tmp/snap files. Unparseable lines are routed to the dead-letter queue
    # (jq -R escaping preserves the raw line verbatim).
    if ! ESCAPED=$(printf '%s\n' "$line" | jq -c \
      'with_entries(select(.key | startswith("_") | not))' 2>/dev/null); then
      NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      DEADLETTERED=$((DEADLETTERED + 1))
      printf '%s\n' "$line" | jq -R -c --arg now "$NOW" \
        '{_dead_lettered_at: $now, _dead_letter_reason: "unparseable-queue-line", _raw: .}' >> "$DEAD_LETTER"
      echo "  DEAD-LETTER (unparseable queue line): $SHORT_ID"
      continue
    fi
    ESCAPED=$(printf '%s\n' "$ESCAPED" | sed "s/'/''/g")

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

    if PGPASSWORD="$DB_PASSWORD" "$PSQL_BIN" "$SUPABASE_DB_CONN" -v ON_ERROR_STOP=1 -c "$SQL" > /dev/null 2>"$ERR_TMP"; then
      SUCCEEDED=$((SUCCEEDED + 1))
      echo "  OK: $SHORT_ID"
    else
      ERR_MSG=$(tr '\n' ' ' < "$ERR_TMP" | cut -c1-500)
      [ -z "$ERR_MSG" ] && ERR_MSG="(psql exited non-zero with no stderr)"
      NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
      UPDATED=$(echo "$line" | jq -c \
        --arg err "$ERR_MSG" --arg now "$NOW" --argjson att "$ATTEMPTS" \
        '. + {_sync_attempts: $att, _last_error: $err, _last_attempt_at: $now}' 2>/dev/null || echo "")
      [ -z "$UPDATED" ] && UPDATED="$line"

      if is_permanent_error "$ERR_MSG"; then
        DEADLETTERED=$((DEADLETTERED + 1))
        echo "$UPDATED" | jq -c --arg now "$NOW" \
          '. + {_dead_lettered_at: $now, _dead_letter_reason: "permanent-error"}' >> "$DEAD_LETTER"
        echo "  DEAD-LETTER (permanent error): $SHORT_ID — $ERR_MSG"
      elif [ "$ATTEMPTS" -gt "$MAX_ATTEMPTS" ]; then
        DEADLETTERED=$((DEADLETTERED + 1))
        echo "$UPDATED" | jq -c --arg now "$NOW" \
          '. + {_dead_lettered_at: $now, _dead_letter_reason: "max-attempts-exceeded"}' >> "$DEAD_LETTER"
        echo "  DEAD-LETTER (attempts $ATTEMPTS > $MAX_ATTEMPTS): $SHORT_ID — $ERR_MSG"
      else
        FAILED=$((FAILED + 1))
        echo "  FAIL (attempt $ATTEMPTS/$MAX_ATTEMPTS): $SHORT_ID — keeping in queue"
        echo "$UPDATED" >> "$TEMP_QUEUE"
      fi
    fi
  done < "$SNAPSHOT"
  rm -f "$ERR_TMP"

  # Merge any lines a live writer appended to the real queue during replay.
  # Hold a hardlink to the live queue's inode across the swap: a writer that
  # opened the queue path before the mv appends to the OLD inode; the hardlink
  # keeps that inode visible so the post-mv re-check can recover lines that
  # landed in the count->mv window.
  SWAP_GUARD="$SYNC_QUEUE.swap-guard.$$"
  rm -f "$SWAP_GUARD"
  if ! ln "$SYNC_QUEUE" "$SWAP_GUARD" 2>/dev/null; then
    cp "$SYNC_QUEUE" "$SWAP_GUARD"   # degraded guard (fs without hardlinks)
  fi
  LIVE_COUNT=$(wc -l < "$SWAP_GUARD" | tr -d '[:space:]')
  if [ "$LIVE_COUNT" -gt "$QUEUE_COUNT" ]; then
    tail -n +"$((QUEUE_COUNT + 1))" "$SWAP_GUARD" >> "$TEMP_QUEUE"
    echo "  (merged $((LIVE_COUNT - QUEUE_COUNT)) entries appended during replay)"
  fi
  rm -f "$SNAPSHOT"; SNAPSHOT=""
  mv "$TEMP_QUEUE" "$SYNC_QUEUE"; TEMP_QUEUE=""
  # Re-check the queue line count right after the mv: re-append any lines a
  # writer landed on the old inode after the count above (would otherwise be
  # silently dropped by the swap).
  POST_COUNT=$(wc -l < "$SWAP_GUARD" | tr -d '[:space:]')
  if [ "$POST_COUNT" -gt "$LIVE_COUNT" ]; then
    tail -n +"$((LIVE_COUNT + 1))" "$SWAP_GUARD" >> "$SYNC_QUEUE"
    echo "  (recovered $((POST_COUNT - LIVE_COUNT)) entries appended during queue swap)"
  fi
  rm -f "$SWAP_GUARD"; SWAP_GUARD=""

  echo ""
  echo "Replay complete: $SUCCEEDED succeeded, $FAILED failed (retained), $DEADLETTERED dead-lettered."
  if [ "$DEADLETTERED" -gt 0 ]; then
    echo "Dead-lettered entries written to: $DEAD_LETTER (manual review required)"
  fi

  # --- Re-count after replay ---
  REMOTE_COUNT_AFTER=$(PGPASSWORD="$DB_PASSWORD" "$PSQL_BIN" "$SUPABASE_DB_CONN" \
    -t -c "SELECT COUNT(*) FROM journal_entries;" 2>/dev/null | tr -d '[:space:]' || echo "ERROR")
  echo ""
  echo "=== After reconcile ==="
  echo "Local:  $LOCAL_COUNT"
  echo "Remote: $REMOTE_COUNT_AFTER"
  case "$REMOTE_COUNT_AFTER" in ''|*[!0-9]*) REMOTE_COUNT_AFTER_NUM=0 ;; *) REMOTE_COUNT_AFTER_NUM=$REMOTE_COUNT_AFTER ;; esac
  DELTA_AFTER=$((LOCAL_COUNT - REMOTE_COUNT_AFTER_NUM))
  echo "Delta:  $DELTA_AFTER"
  if [ "$DELTA_AFTER" -eq 0 ]; then
    echo "STATUS: IN SYNC"
  else
    echo "STATUS: $DELTA_AFTER entries still unsynced (check sync-queue.jsonl)"
  fi
fi
