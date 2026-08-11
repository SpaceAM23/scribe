#!/usr/bin/env bash
# writer.sh — Scribe multi-target journal entry writer (generalized)
# Writes entry to: individual JSON file, JSONL index, Supabase (if configured),
# Google Drive marker (if configured), index.json stats, correction-tracker.json.
#
# Fully config-driven — no hardcoded paths, projects, or credentials.
# Compatible with bash 3.2+ (macOS default).
#
# Write-time hardening:
#   - Writer lock: a bash-3.2-safe mkdir lock serializes concurrent writers
#     around the critical section (dedup check -> journal append -> index ->
#     tracker), with stale-lock recovery via atomic rename-aside
#   - Enum enforcement reads valid values from the install's schema.json
#   - Normalization backstop reads its map from DATA_DIR/normalizations.json
#     (falls back to templates/normalizations.template.json); logs all repairs
#   - Unknown projects/types are normalized (never rejected) and the ORIGINAL
#     value is queued to canonical/taxonomy-suggestions.jsonl for deliberate
#     minting via core/taxonomy.py
#   - Fault-tolerant Supabase sync-queue: failed writes are queued for reconcile
#   - Content-hash dedup: prevents duplicate journal entries; the hash is
#     recorded only AFTER the journal append succeeds (crash-safe direction)
#   - Post-write hook regenerates the project's session brief (core/brief.py)
#
# Usage:
#   echo '{"id":"...","timestamp":"...",...}' | writer.sh
#   writer.sh entry.json

set -euo pipefail

# Preflight: the whole writer is jq-based. Without this the entry is lost with
# a bare "jq: command not found" and no Scribe-branded diagnostic — silent loss
# in any thin-PATH context (cron, launchd, background agents).
if ! command -v jq >/dev/null 2>&1; then
  echo "SCRIBE ERROR [writer/preflight]: jq is required but not found on PATH." >&2
  echo "  Install it (brew install jq) or add it to PATH. Entry NOT written." >&2
  exit 127
fi


# Pin the locale. The content-hash recipe in section 12c uses `cut -c1-200`,
# which truncates 200 BYTES under LC_ALL=C (the cron/launchd default) but
# 200 CHARACTERS under a UTF-8 locale. A byte-truncated hash diverges from
# doctor.py's 200-character slice and from interactive-shell writes, silently
# breaking dedup across execution contexts. Prefer a UTF-8 locale that exists
# on this machine; fall back to C only when no UTF-8 locale is available
# (still deterministic per machine).
if locale -a 2>/dev/null | grep -qix 'en_US.UTF-8'; then
  export LC_ALL=en_US.UTF-8
elif locale -a 2>/dev/null | grep -qix 'C.UTF-8'; then
  export LC_ALL=C.UTF-8
else
  export LC_ALL=C
fi

# =============================================================================
# 0. ERROR HANDLER
# =============================================================================

# Source the error handler for structured error logging
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/error-handler.sh" ]; then
  # DATA_DIR isn't set yet — error-handler will use the default until we override
  source "$SCRIPT_DIR/error-handler.sh"
else
  # Inline fallback error handler
  scribe_log_error() {
    local component="${1:-unknown}"
    local error_type="${2:-unknown}"
    local message="${3:-No message}"
    local context="${4:-}"
    local err_id
    err_id=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "err-$(date +%s)")
    local ts
    ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local os_info
    os_info="$(uname -s) $(uname -r)"
    message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    context=$(echo "$context" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
    echo "{\"error_id\":\"${err_id}\",\"timestamp\":\"${ts}\",\"component\":\"${component}\",\"error_type\":\"${error_type}\",\"message\":\"${message}\",\"context\":\"${context}\",\"system\":\"${os_info}\",\"submitted\":false}" >> "${ERRORS_LOG:-/tmp/scribe-errors.jsonl}" 2>/dev/null
  }
fi

# =============================================================================
# 1. RESOLVE DATA DIRECTORY
# =============================================================================

# Priority: $SCRIBE_DATA_PATH env > pointer.json > default
resolve_data_path() {
  # 1. Environment variable
  if [ -n "${SCRIBE_DATA_PATH:-}" ]; then
    echo "$SCRIBE_DATA_PATH"
    return
  fi

  # 2/3. pointer.json — repo root first (this script lives in core/), then the
  # script dir itself (a skill install may nest core/).
  #
  # A pointer that EXISTS but cannot be read is a hard error, never a fallback.
  # Falling through to the shared default is how two installs on one machine
  # silently converge on one journal — the failure this resolution order exists
  # to prevent. "No pointer" and "broken pointer" are different situations.
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  local pointer
  for pointer in "$script_dir/../pointer.json" "$script_dir/pointer.json"; do
    [ -f "$pointer" ] || continue
    local ptr_path
    if ! ptr_path=$(jq -r '.data_path // empty' "$pointer" 2>/dev/null); then
      echo "SCRIBE ERROR [writer/pointer]: $pointer exists but is not valid JSON." >&2
      echo "  Refusing to fall back to the shared default (~/Desktop/Scribe), which" >&2
      echo "  would silently mix this install's journal with another's." >&2
      echo "  Fix the file or delete it to accept the default. Entry NOT written." >&2
      exit 78
    fi
    if [ -z "$ptr_path" ]; then
      echo "SCRIBE ERROR [writer/pointer]: $pointer has no .data_path value." >&2
      echo "  Refusing to fall back to the shared default. Entry NOT written." >&2
      exit 78
    fi
    case "$ptr_path" in
      "~"*|/*) : ;;
      *) echo "SCRIBE ERROR [writer/pointer]: .data_path is relative (\"$ptr_path\")." >&2
         echo "  Relative paths resolve against the current directory, so the journal" >&2
         echo "  splinters into one copy per working directory. Use an absolute path." >&2
         exit 78 ;;
    esac
    echo "${ptr_path/#\~/$HOME}"
    return
  done

  # 4. Default
  echo "$HOME/Desktop/Scribe"
}

DATA_DIR="$(resolve_data_path)"
export DATA_DIR
ERRORS_LOG="$DATA_DIR/errors.jsonl"

# Validate data directory exists (or create it)
if [ ! -d "$DATA_DIR" ]; then
  echo "WARN: Data directory '$DATA_DIR' does not exist. Creating it." >&2
  mkdir -p "$DATA_DIR"
fi

# =============================================================================
# 2. RESOLVE PATHS AND CONFIG
# =============================================================================

CONFIG_FILE="$DATA_DIR/config.json"
JOURNAL="$DATA_DIR/journal.jsonl"
INDEX="$DATA_DIR/index.json"
ENTRIES_DIR="$DATA_DIR/entries"
ENV_FILE="$DATA_DIR/.env"
CORRECTION_TRACKER="$DATA_DIR/correction-tracker.json"
SESSION_COUNTER="$DATA_DIR/session-counter.json"

# =============================================================================
# 2b. WRITER LOCK (bash 3.2-safe mkdir lock)
#
# Serializes concurrent writers around the critical section (dedup check ->
# journal append -> index.json update -> correction-tracker update). Without
# this, parallel writers lose index.json increments (read-modify-write race),
# can truncate index.json to 0 bytes, race the correction tracker, and slip
# past the seen-hashes dedup check (check-then-append TOCTOU).
#
# mkdir is atomic on POSIX filesystems and works on bash 3.2 (no flock needed).
# Stale locks are recovered: the holder PID is recorded in the lockdir; if the
# holder is dead (kill -9, crash) the lock is stolen. A pid-less lockdir older
# than 60s is also treated as stale.
# =============================================================================

LOCK_DIR_PATH="$DATA_DIR/.writer.lock"
SCRIBE_LOCK_HELD="false"

release_scribe_lock() {
  if [ "$SCRIBE_LOCK_HELD" = "true" ]; then
    # Re-verify ownership before removing. If our lock was stolen (e.g. we
    # were stopped long enough to look stale) the lockdir now belongs to
    # another writer — removing it would let a third writer in.
    local owner
    owner=$(cat "$LOCK_DIR_PATH/pid" 2>/dev/null || true)
    if [ "$owner" = "$$" ]; then
      rm -rf "$LOCK_DIR_PATH" 2>/dev/null || true
    fi
    SCRIBE_LOCK_HELD="false"
  fi
}

# Steal a stale lock by ATOMICALLY renaming the lockdir aside (mv/rename is
# atomic; rm -rf is not). When several writers race to steal, exactly one wins
# the rename; the losers' mv fails and they simply retry mkdir. With rm -rf,
# two stealers could interleave (one removes the OTHER stealer's freshly
# acquired lock) and both end up inside the critical section.
steal_stale_lock() {
  local graveyard
  graveyard="$LOCK_DIR_PATH.stale.$$.$(date +%s 2>/dev/null || echo 0)"
  if mv "$LOCK_DIR_PATH" "$graveyard" 2>/dev/null; then
    rm -rf "$graveyard" 2>/dev/null || true
  fi
}

# Returns 0 with lock held, 1 on timeout (~15s). Never throws under set -e.
acquire_scribe_lock() {
  local tries=0
  local max_tries=75   # 75 x 0.2s = ~15s
  while [ "$tries" -lt "$max_tries" ]; do
    if mkdir "$LOCK_DIR_PATH" 2>/dev/null; then
      SCRIBE_LOCK_HELD="true"
      printf '%s' "$$" > "$LOCK_DIR_PATH/pid" 2>/dev/null || true
      return 0
    fi
    # Stale-lock recovery: recorded holder PID no longer alive -> steal.
    local holder
    holder=$(cat "$LOCK_DIR_PATH/pid" 2>/dev/null || true)
    if [ -n "$holder" ]; then
      if ! kill -0 "$holder" 2>/dev/null; then
        steal_stale_lock
      fi
    else
      # No pid file (holder crashed between mkdir and pid write, or mid-steal).
      # Treat as stale only if the lockdir is old.
      local lock_mtime now_epoch
      lock_mtime=$(stat -f %m "$LOCK_DIR_PATH" 2>/dev/null || stat -c %Y "$LOCK_DIR_PATH" 2>/dev/null || echo "")
      now_epoch=$(date +%s)
      if [ -n "$lock_mtime" ] && [ $((now_epoch - lock_mtime)) -gt 60 ]; then
        steal_stale_lock
      fi
    fi
    tries=$((tries + 1))
    sleep 0.2
  done
  return 1
}

# Release on any exit path (duplicate short-circuit, error under set -e, signal).
trap 'release_scribe_lock' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Core entry types — accepted without config. Custom types also allowed (soft validation).
CORE_TYPES="session_open feature_shipped bug_fixed decision_made learning correction process_created tool_discovered feedback_received milestone reflection essence"

# =============================================================================
# 3. LOAD CONFIG
# =============================================================================

# Config is optional — writer works with sensible defaults if config.json
# doesn't exist yet (e.g. first run before setup completes).

SUPABASE_ENABLED="false"
SUPABASE_DB_CONN=""
DRIVE_ENABLED="false"
DRIVE_FOLDER_ID=""
LOCAL_ENABLED="true"
PROJECTS_CONFIGURED="false"
PROJECT_ALIASES=""
CONFIG_USER_ID=""

if [ -f "$CONFIG_FILE" ]; then
  # Storage targets
  SUPABASE_ENABLED=$(jq -r '.storage.supabase.enabled // false' "$CONFIG_FILE")
  SUPABASE_DB_CONN=$(jq -r '.storage.supabase.db_connection // empty' "$CONFIG_FILE" 2>/dev/null || true)
  DRIVE_ENABLED=$(jq -r '.storage.google_drive.enabled // false' "$CONFIG_FILE")
  DRIVE_FOLDER_ID=$(jq -r '.storage.google_drive.folder_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
  LOCAL_ENABLED=$(jq -r '.storage.local.enabled // true' "$CONFIG_FILE")

  # Owner identity — used as the default user_id when an entry omits it
  CONFIG_USER_ID=$(jq -r '.user_id // empty' "$CONFIG_FILE" 2>/dev/null || true)

  # Projects — check if any are defined
  PROJ_COUNT=$(jq '.projects | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
  if [ "$PROJ_COUNT" -gt 0 ]; then
    PROJECTS_CONFIGURED="true"
  fi

  # Project aliases — read from config if present
  # Format in config: "project_aliases": { "alt-name": "canonical-name", ... }
  PROJECT_ALIASES=$(jq -r '.project_aliases // {} | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE" 2>/dev/null || true)
fi

# =============================================================================
# 4. LOAD ENVIRONMENT (for Supabase password, etc.)
# =============================================================================

if [ -f "$ENV_FILE" ]; then
  # Source .env safely — only export lines matching KEY=VALUE
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    case "$key" in
      \#*|"") continue ;;
    esac
    # Remove surrounding quotes from value
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    export "$key"="$value"
  done < "$ENV_FILE"
fi

# =============================================================================
# 5. FIND PSQL (for Supabase writes)
# =============================================================================

find_psql() {
  # 1. Check PATH
  if command -v psql >/dev/null 2>&1; then
    command -v psql
    return
  fi

  # 2. Common macOS locations
  local candidates
  candidates="/usr/local/bin/psql /opt/homebrew/bin/psql"

  # 3. Homebrew libpq (multiple versions) — evaluated inline for bash 3.2 compat
  local libpq_dir
  for libpq_dir in /usr/local/Cellar/libpq/*/bin/psql /opt/homebrew/Cellar/libpq/*/bin/psql; do
    if [ -x "$libpq_dir" ] 2>/dev/null; then
      candidates="$libpq_dir $candidates"
    fi
  done

  # 4. Linux common locations
  candidates="$candidates /usr/bin/psql"
  for libpq_dir in /usr/lib/postgresql/*/bin/psql; do
    if [ -x "$libpq_dir" ] 2>/dev/null; then
      candidates="$candidates $libpq_dir"
    fi
  done

  local candidate
  for candidate in $candidates; do
    if [ -x "$candidate" ] 2>/dev/null; then
      echo "$candidate"
      return
    fi
  done

  # Not found
  return 1
}

PSQL_BIN=""
if [ "$SUPABASE_ENABLED" = "true" ]; then
  PSQL_BIN=$(find_psql 2>/dev/null || true)
  if [ -z "$PSQL_BIN" ]; then
    echo "WARN: Supabase enabled but psql not found. Supabase writes will be skipped." >&2
  fi
fi

# =============================================================================
# 6. READ INPUT
# =============================================================================

if [ $# -ge 1 ] && [ -f "$1" ]; then
  ENTRY=$(cat "$1")
elif [ ! -t 0 ]; then
  ENTRY=$(cat -)
else
  echo "ERROR: No input provided." >&2
  echo "Usage: $0 <entry.json>  OR  echo '{...}' | $0" >&2
  exit 1
fi

# =============================================================================
# 7. VALIDATE JSON
# =============================================================================

if ! echo "$ENTRY" | jq empty 2>/dev/null; then
  echo "ERROR: Input is not valid JSON." >&2
  exit 1
fi

# =============================================================================
# 8. VALIDATE REQUIRED FIELDS (user_id optional — defaults to config owner)
# =============================================================================

REQUIRED_FIELDS="id timestamp session_id project type title summary"
for field in $REQUIRED_FIELDS; do
  val=$(echo "$ENTRY" | jq -r --arg f "$field" '.[$f] // empty')
  if [ -z "$val" ]; then
    echo "ERROR: Missing required field: $field" >&2
    exit 1
  fi
done

# =============================================================================
# 9. EXTRACT KEY VALUES
# =============================================================================

ID=$(echo "$ENTRY" | jq -r '.id' | tr '[:upper:]' '[:lower:]')   # normalize id case at the single door — Postgres uuid is lowercase; uppercase caller ids cause local<->DB divergence
ENTRY=$(echo "$ENTRY" | jq --arg id "$ID" '.id = $id')           # propagate lowercase so entry file + journal index + DB all agree
SHORT_ID=$(echo "$ID" | cut -c1-8)
TIMESTAMP=$(echo "$ENTRY" | jq -r '.timestamp')

# REPAIR invalid id/timestamp at the single door — never persist a literal
# "$(uuidgen ...)", "$(date ...)", "<uuid>", "<now>", or any non-uuid / non-ISO value.
# Root cause: callers built entry JSON inside single quotes, so shell substitutions never expanded.
if ! printf '%s' "$ID" | grep -qiE '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
  _BAD_ID="$ID"
  ID=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "gen-$(date +%s)-$$")
  ENTRY=$(echo "$ENTRY" | jq --arg id "$ID" '.id = $id')
  SHORT_ID=$(echo "$ID" | cut -c1-8)
  printf '{"ts":"%s","field":"id","from":%s,"to":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$_BAD_ID" | jq -R .)" "$ID" >> "$DATA_DIR/normalizations.jsonl" 2>/dev/null || true
  echo "NOTE: invalid id '$_BAD_ID' repaired to '$ID' at the writer door." >&2
fi
if printf '%s' "$TIMESTAMP" | grep -q '[$]' || ! printf '%s' "$TIMESTAMP" | grep -qE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T'; then
  _BAD_TS="$TIMESTAMP"
  _DP=$(printf '%s' "$TIMESTAMP" | grep -oE '^[0-9]{4}-[0-9]{2}-[0-9]{2}' || true)
  if [ -n "$_DP" ]; then TIMESTAMP="${_DP}T12:00:00Z"; else TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ); fi
  ENTRY=$(echo "$ENTRY" | jq --arg t "$TIMESTAMP" '.timestamp = $t')
  printf '{"ts":"%s","field":"timestamp","from":%s,"to":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$_BAD_TS" | jq -R .)" "$TIMESTAMP" >> "$DATA_DIR/normalizations.jsonl" 2>/dev/null || true
  echo "NOTE: invalid timestamp '$_BAD_TS' repaired to '$TIMESTAMP' at the writer door." >&2
fi
PROJECT=$(echo "$ENTRY" | jq -r '.project')
TYPE=$(echo "$ENTRY" | jq -r '.type')
TITLE=$(echo "$ENTRY" | jq -r '.title')
SESSION_ID=$(echo "$ENTRY" | jq -r '.session_id')

# user_id: entry value > config.json owner > "unknown". Never reject an entry
# for a missing user_id (no-data-loss); inject the resolved value so the entry
# file, journal index, and DB all agree.
USER_ID=$(echo "$ENTRY" | jq -r '.user_id // empty')
if [ -z "$USER_ID" ]; then
  USER_ID="${CONFIG_USER_ID:-unknown}"
  ENTRY=$(echo "$ENTRY" | jq --arg u "$USER_ID" '.user_id = $u')
fi

# =============================================================================
# 10. RESOLVE PROJECT ALIASES (canonical/projects.json first, then config fallback)
# =============================================================================

CANONICAL_PROJECTS_FILE="$DATA_DIR/canonical/projects.json"

# Try canonical/projects.json first (the authoritative source)
if [ -f "$CANONICAL_PROJECTS_FILE" ]; then
  # Resolve alias using canonical/projects.json aliases map
  RESOLVED_PROJECT=$(jq -r --arg p "$PROJECT" '.aliases[$p] // empty' "$CANONICAL_PROJECTS_FILE" 2>/dev/null || true)
  if [ -n "$RESOLVED_PROJECT" ] && [ "$RESOLVED_PROJECT" != "$PROJECT" ]; then
    PROJECT="$RESOLVED_PROJECT"
    ENTRY=$(echo "$ENTRY" | jq --arg p "$PROJECT" '.project = $p')
  fi
elif [ -n "$PROJECT_ALIASES" ]; then
  # Fallback: config-driven alias list (legacy path for installs without canonical/)
  RESOLVED_PROJECT="$PROJECT"
  while IFS= read -r alias_line; do
    [ -z "$alias_line" ] && continue
    alias_key="${alias_line%%=*}"
    alias_val="${alias_line#*=}"
    if [ "$PROJECT" = "$alias_key" ]; then
      RESOLVED_PROJECT="$alias_val"
      break
    fi
  done <<< "$PROJECT_ALIASES"

  if [ "$RESOLVED_PROJECT" != "$PROJECT" ]; then
    PROJECT="$RESOLVED_PROJECT"
    ENTRY=$(echo "$ENTRY" | jq --arg p "$PROJECT" '.project = $p')
  fi
fi

# =============================================================================
# 10b. TAXONOMY SUGGESTION QUEUE
#
# When an unknown project or type gets normalized away (sections 11 and 12b),
# the ORIGINAL submitted value is also queued to
# canonical/taxonomy-suggestions.jsonl so a category can be deliberately
# minted later (core/taxonomy.py; surfaced in briefs/_portfolio.md).
# Without this, knowledge gets misfiled into meta/milestone with no trace
# that a category was wanted. Non-fatal: a failed append never blocks the
# entry write. Values are escaped with jq -Rs (same style as log_norm).
# =============================================================================

TAXONOMY_SUGGESTIONS="$DATA_DIR/canonical/taxonomy-suggestions.jsonl"

# Usage: queue_taxonomy_suggestion <project|type> <submitted_value>
queue_taxonomy_suggestion() {
  local sug_kind="$1"
  local sug_value="$2"
  {
    mkdir -p "$DATA_DIR/canonical"
    printf '{"ts":"%s","kind":"%s","value":%s,"entry_id":"%s","title":%s}\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      "$sug_kind" \
      "$(printf '%s' "$sug_value" | jq -Rs .)" \
      "$ID" \
      "$(printf '%s' "$TITLE" | jq -Rs .)" >> "$TAXONOMY_SUGGESTIONS"
  } 2>/dev/null || true
}

# =============================================================================
# 11. VALIDATE PROJECT (canonical first, then config-driven; never reject — normalize)
# =============================================================================

# Never drop an entry due to unknown project.
# If canonical/projects.json exists AND lists at least one project, validate
# against it. An EMPTY projects[] list means "open mode": any project name is
# accepted (the state a fresh install ships in). Unknown -> normalize to
# "meta", log, and queue a taxonomy suggestion; keep the entry.
if [ -f "$CANONICAL_PROJECTS_FILE" ]; then
  CANONICAL_PROJ_COUNT=$(jq -r '.projects | length' "$CANONICAL_PROJECTS_FILE" 2>/dev/null || echo "0")
  case "$CANONICAL_PROJ_COUNT" in ''|*[!0-9]*) CANONICAL_PROJ_COUNT=0 ;; esac
  if [ "$CANONICAL_PROJ_COUNT" -gt 0 ]; then
    PROJ_IN_CANONICAL=$(jq -r --arg p "$PROJECT" '[.projects[] | select(. == $p)] | length > 0' "$CANONICAL_PROJECTS_FILE" 2>/dev/null || echo "false")
    if [ "$PROJ_IN_CANONICAL" != "true" ]; then
      ORIGINAL_PROJECT="$PROJECT"
      PROJECT="meta"
      ENTRY=$(echo "$ENTRY" | jq --arg p "$PROJECT" '.project = $p')
      _NORM_LOG_PROJ="$DATA_DIR/normalizations.jsonl"
      _NORM_NOW_PROJ=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      # jq -Rs escapes arbitrary caller values (quotes, backslashes, newlines) —
      # raw printf interpolation produced unparseable normalizations.jsonl lines
      # (same escaping the id/timestamp repair paths use).
      printf '{"ts":"%s","field":"project","from":%s,"to":"meta","entry_id":"%s"}\n' \
        "$_NORM_NOW_PROJ" "$(printf '%s' "$ORIGINAL_PROJECT" | jq -Rs .)" "$ID" >> "$_NORM_LOG_PROJ"
      # 10b: queue the original value so the category can be minted deliberately
      queue_taxonomy_suggestion "project" "$ORIGINAL_PROJECT"
      echo "NOTE: Unknown project '$ORIGINAL_PROJECT' normalized to 'meta'. Logged to normalizations.jsonl + taxonomy-suggestions.jsonl." >&2
    fi
  fi
elif [ "$PROJECTS_CONFIGURED" = "true" ]; then
  # Legacy: config.json defines projects as an object/map
  PROJ_VALID=$(jq -r --arg p "$PROJECT" '.projects | has($p)' "$CONFIG_FILE" 2>/dev/null || echo "false")
  if [ "$PROJ_VALID" != "true" ]; then
    ORIGINAL_PROJECT="$PROJECT"
    PROJECT="meta"
    ENTRY=$(echo "$ENTRY" | jq --arg p "$PROJECT" '.project = $p')
    queue_taxonomy_suggestion "project" "$ORIGINAL_PROJECT"
    echo "NOTE: Unknown project '$ORIGINAL_PROJECT' normalized to 'meta' (config-driven)." >&2
  fi
fi
# If neither canonical nor config defines projects, accept any project name

# =============================================================================
# 12. VALIDATE TYPE (soft: warn on custom types, don't reject)
# =============================================================================

TYPE_IS_CORE=false
for t in $CORE_TYPES; do
  if [ "$TYPE" = "$t" ]; then TYPE_IS_CORE=true; break; fi
done
if [ "$TYPE_IS_CORE" = false ]; then
  echo "NOTE: Custom entry type '$TYPE' (not in core set)." >&2
fi

# =============================================================================
# 12b. ENUM ENFORCEMENT — normalize invalid enum values at the writer boundary
#
# Reads valid values FROM schema.json (user's DATA_DIR copy takes precedence,
# then the install's core/schema.json — never a hardcoded copy).
# Consults normalizations.json for deterministic repair (user's copy at
# DATA_DIR/normalizations.json; falls back to the install's
# templates/normalizations.template.json).
# On invalid value: map via normalizations, else set "unspecified".
# Keeps the entry (no data loss). Logs every normalization to normalizations.jsonl.
# A valid entry passes through UNCHANGED.
# Bash 3.2-compatible: no declare -A; normalization lookup uses jq.
# =============================================================================

# Resolve schema.json: user's DATA_DIR copy first, then install's core copy
SCHEMA_FILE="$DATA_DIR/schema.json"
if [ ! -f "$SCHEMA_FILE" ]; then
  INSTALL_SCHEMA="$SCRIPT_DIR/schema.json"
  if [ -f "$INSTALL_SCHEMA" ]; then
    SCHEMA_FILE="$INSTALL_SCHEMA"
  else
    SCHEMA_FILE=""
  fi
fi

# Resolve normalizations map: DATA_DIR/canonical copy first, then legacy
# DATA_DIR copy, then the install template
NORM_MAP_FILE="$DATA_DIR/canonical/normalizations.json"
if [ ! -f "$NORM_MAP_FILE" ]; then
  NORM_MAP_FILE="$DATA_DIR/normalizations.json"
fi
if [ ! -f "$NORM_MAP_FILE" ]; then
  INSTALL_NORM="$SCRIPT_DIR/../templates/normalizations.template.json"
  if [ -f "$INSTALL_NORM" ]; then
    NORM_MAP_FILE="$INSTALL_NORM"
  else
    NORM_MAP_FILE=""
  fi
fi

NORM_LOG="$DATA_DIR/normalizations.jsonl"
NORM_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Helper: look up a value in the normalizations map for a given field key.
# Prints the mapped canonical value, or empty string if not found.
# Usage: norm_lookup <field_key> <value>
# field_key matches the top-level key in normalizations.json (e.g. "complexity")
norm_lookup() {
  local field_key="$1"
  local val="$2"
  if [ -n "$NORM_MAP_FILE" ] && [ -f "$NORM_MAP_FILE" ]; then
    jq -r --arg fk "$field_key" --arg v "$val" \
      '.[$fk][$v] // empty' "$NORM_MAP_FILE" 2>/dev/null || true
  fi
}

# Helper: check if a value is in a schema enum array for a given jq path.
# Prints "true" or "false". Passes through when schema is unavailable.
# Usage: enum_valid <jq_path_to_enum_array> <value>
enum_valid() {
  local jq_path="$1"
  local val="$2"
  if [ -z "$SCHEMA_FILE" ] || [ ! -f "$SCHEMA_FILE" ]; then
    echo "true"   # can't validate without schema — pass through
    return
  fi
  jq -r --arg v "$val" "${jq_path} | if type == \"array\" then map(select(. == \$v)) | length > 0 else true end" "$SCHEMA_FILE" 2>/dev/null || echo "true"
}

# Helper: append a normalization log entry.
# Usage: log_norm <field> <from_val> <to_val>
# from/to are caller-controlled values — jq -Rs escapes quotes/backslashes/
# newlines so a value like `very "hard"` cannot produce an unparseable
# normalizations.jsonl line (raw printf interpolation did exactly that).
log_norm() {
  local field="$1"
  local from_val="$2"
  local to_val="$3"
  printf '{"ts":"%s","field":"%s","from":%s,"to":%s,"entry_id":"%s"}\n' \
    "$NORM_NOW" "$field" \
    "$(printf '%s' "$from_val" | jq -Rs .)" \
    "$(printf '%s' "$to_val" | jq -Rs .)" \
    "$ID" >> "$NORM_LOG"
  echo "NOTE: Normalized $field: '$from_val' -> '$to_val' (logged to normalizations.jsonl)." >&2
}

# Helper: enforce one enum field in the entry.
# Usage: enforce_enum <entry_jq_path> <schema_jq_path> <norm_key> <log_field_name>
enforce_enum() {
  local entry_path="$1"
  local schema_path="$2"
  local norm_key="$3"
  local log_field="$4"

  # Only act if the field is present and non-null
  if echo "$ENTRY" | jq -e "${entry_path} != null" >/dev/null 2>&1; then
    local curr_val
    curr_val=$(echo "$ENTRY" | jq -r "${entry_path}")
    local is_valid
    is_valid=$(enum_valid "$schema_path" "$curr_val")
    if [ "$is_valid" != "true" ]; then
      local mapped
      mapped=$(norm_lookup "$norm_key" "$curr_val")
      if [ -z "$mapped" ]; then
        mapped="unspecified"
      fi
      ENTRY=$(echo "$ENTRY" | jq --arg v "$mapped" "${entry_path} = \$v")
      log_norm "$log_field" "$curr_val" "$mapped"
    fi
  fi
}

# Enforce all enum fields defined in the schema
enforce_enum '.growth.complexity'         '.properties.growth.properties.complexity.enum'         'complexity'     'growth.complexity'
enforce_enum '.growth.autonomy'           '.properties.growth.properties.autonomy.enum'           'autonomy'       'growth.autonomy'
enforce_enum '.behavioral.drive_state'    '.properties.behavioral.properties.drive_state.enum'    'drive_state'    'behavioral.drive_state'
enforce_enum '.behavioral.energy'         '.properties.behavioral.properties.energy.enum'         'energy'         'behavioral.energy'
enforce_enum '.behavioral.cognitive_load' '.properties.behavioral.properties.cognitive_load.enum' 'cognitive_load' 'behavioral.cognitive_load'

# --- Enforce type against the schema enum (hard-normalize, never reject) ---
# The DB type CHECK rejects non-enum types, so a custom type silently fails
# the Supabase insert and queues forever. Hard-normalize to a valid core type
# (map common variants; fall back to "milestone") so the entry persists, and
# queue the ORIGINAL value as a taxonomy suggestion. No data loss of the entry.
CURR_TYPE=$(echo "$ENTRY" | jq -r '.type')
TYPE_IN_SCHEMA=$(enum_valid '.properties.type.enum' "$CURR_TYPE")
if [ "$TYPE_IN_SCHEMA" != "true" ]; then
  _BAD_TYPE="$CURR_TYPE"
  case "$CURR_TYPE" in
    decision|decided|decision-made) CURR_TYPE="decision_made" ;;
    feature|feature_built|feature_complete|shipped|built) CURR_TYPE="feature_shipped" ;;
    bug|bugfix|fix|fixed|bug-fixed) CURR_TYPE="bug_fixed" ;;
    learned|learnt|lesson|insight|learnings) CURR_TYPE="learning" ;;
    process|process-created|workflow) CURR_TYPE="process_created" ;;
    tool|tool-discovered) CURR_TYPE="tool_discovered" ;;
    feedback|feedback-received) CURR_TYPE="feedback_received" ;;
    session|session-open|open|start) CURR_TYPE="session_open" ;;
    reflect|reflections) CURR_TYPE="reflection" ;;
    *) CURR_TYPE="milestone" ;;
  esac
  ENTRY=$(echo "$ENTRY" | jq --arg t "$CURR_TYPE" '.type = $t')
  printf '{"ts":"%s","field":"type","from":%s,"to":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$_BAD_TYPE" | jq -R .)" "$CURR_TYPE" >> "$NORM_LOG" 2>/dev/null || true
  # 10b: queue the original value so the category can be minted deliberately
  queue_taxonomy_suggestion "type" "$_BAD_TYPE"
  echo "NOTE: invalid type '$_BAD_TYPE' normalized to '$CURR_TYPE' (DB enum) at the writer door." >&2
fi

# Re-read TYPE from (possibly modified) ENTRY
TYPE=$(echo "$ENTRY" | jq -r '.type')

# =============================================================================
# 12c. CONTENT-HASH DEDUP
#
# Computes a stable hash from: project + type + title + date(10) + summary[0:200]
# Checks against seen-hashes.txt. On collision: skip write, log to duplicates.jsonl.
# Flagging is auto-safe; the full entry payload is preserved in the log.
# Bash 3.2-compatible: uses shasum (macOS) falling back to sha256sum (Linux).
# =============================================================================

SEEN_HASHES="$DATA_DIR/seen-hashes.txt"
DUPLICATES_LOG="$DATA_DIR/duplicates.jsonl"

# --- BEGIN CRITICAL SECTION (dedup check -> journal append -> index -> tracker) ---
# On lock timeout we proceed UNLOCKED rather than dropping the entry: a rare
# index race is recoverable (doctor/reconcile); a dropped journal entry is not.
if ! acquire_scribe_lock; then
  echo "WARN: writer lock not acquired after ~15s — proceeding without lock to avoid data loss." >&2
  if type scribe_log_error >/dev/null 2>&1; then
    scribe_log_error "writer" "lock" "Lock acquisition timed out (~15s) — proceeded unlocked" "entry_id=$SHORT_ID, lock=$LOCK_DIR_PATH"
  fi
fi

# Build hash input: project|type|title|date|summary_prefix
ENTRY_DATE=$(echo "$TIMESTAMP" | cut -c1-10)
SUMMARY_PREFIX=$(echo "$ENTRY" | jq -r '.summary // empty' | cut -c1-200)
HASH_INPUT="${PROJECT}|${TYPE}|${TITLE}|${ENTRY_DATE}|${SUMMARY_PREFIX}"

# Compute hash — shasum on macOS, sha256sum on Linux
if command -v shasum >/dev/null 2>&1; then
  CONTENT_HASH=$(printf '%s' "$HASH_INPUT" | shasum -a 256 | cut -c1-64)
elif command -v sha256sum >/dev/null 2>&1; then
  CONTENT_HASH=$(printf '%s' "$HASH_INPUT" | sha256sum | cut -c1-64)
else
  # Fallback: no hash tool available; skip dedup rather than blocking
  CONTENT_HASH=""
fi

IS_DUPLICATE=false
HASH_RECORDED=false
if [ -n "$CONTENT_HASH" ]; then
  touch "$SEEN_HASHES"
  if grep -qF "$CONTENT_HASH" "$SEEN_HASHES" 2>/dev/null; then
    IS_DUPLICATE=true
    # Log the duplicate with the FULL entry JSON (flag only — no data loss).
    # Metadata alone preserved a refused entry's summary/learnings/corrections
    # NOWHERE; .entry keeps the whole payload recoverable. The line is built
    # by jq (not raw printf interpolation), so quote-bearing titles cannot
    # produce unparseable duplicates.jsonl lines.
    _DUP_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '%s' "$ENTRY" | jq -c \
      --arg ts "$_DUP_NOW" --arg hash "$CONTENT_HASH" --arg date "$ENTRY_DATE" \
      '{ts: $ts, hash: $hash, entry_id: .id, project: .project, type: .type,
        title: .title, date: $date, entry: .}' >> "$DUPLICATES_LOG"
    echo "NOTE: Duplicate entry detected (content-hash match). Logged to duplicates.jsonl — not written to journal." >&2
  fi
  # NOTE: the hash is NOT recorded here. It is appended to seen-hashes.txt
  # only AFTER the journal append succeeds (see record_content_hash below).
  # Recording it before the append poisoned seen-hashes.txt when a crash
  # landed between the two: the retry of a never-persisted entry was refused
  # as DUPLICATE — unrecoverable data loss.
fi

# Record the content hash so future duplicates are caught. Called after the
# entry has actually been persisted (still inside the writer lock, so the
# check-then-record window stays serialized against other writers). The
# crash-safe failure direction: a crash before this runs allows a duplicate
# journal line on a retry (detectable; doctor can repair) instead of silently
# losing an entry.
record_content_hash() {
  if [ -n "$CONTENT_HASH" ] && [ "$HASH_RECORDED" != "true" ]; then
    echo "$CONTENT_HASH" >> "$SEEN_HASHES"
    HASH_RECORDED=true
  fi
}

# If duplicate, skip all write targets and exit cleanly
if [ "$IS_DUPLICATE" = "true" ]; then
  echo ""
  echo "SCRIBE: DUPLICATE — \"$TITLE\" [$PROJECT] -> skipped (see duplicates.jsonl)"
  exit 0
fi

# =============================================================================
# 13. TARGET: LOCAL FILES
# =============================================================================

TARGETS_WRITTEN=""

if [ "$LOCAL_ENABLED" = "true" ]; then
  # 13a. Write individual entry file (pretty-printed)
  mkdir -p "$ENTRIES_DIR"
  echo "$ENTRY" | jq '.' > "$ENTRIES_DIR/${SHORT_ID}.json"

  # 13b. Append indexed entry to journal.jsonl
  touch "$JOURNAL"
  echo "$ENTRY" | jq -c \
    --arg file "entries/${SHORT_ID}.json" \
    '{
      id: .id,
      timestamp: .timestamp,
      project: .project,
      type: .type,
      title: .title,
      file: $file,
      user_id: (.user_id // null),
      summary: (.summary // null),
      decisions: (if (.decisions // []) | length > 0 then .decisions else null end),
      learnings: (if (.learnings // []) | length > 0 then .learnings else null end),
      corrections: (if (.corrections // []) | length > 0 then .corrections else null end),
      metrics: (.metrics // null),
      growth: (.growth // null),
      connections: (if (.connections // {}) | to_entries | length > 0 then .connections else null end),
      behavioral: (if (.behavioral // {}) | to_entries | length > 0 then .behavioral else null end)
    } | with_entries(select(.value != null))' \
    >> "$JOURNAL"

  # Only now — after the journal append — is the content hash committed to
  # seen-hashes.txt.
  record_content_hash

  TARGETS_WRITTEN="file+index"
fi

# =============================================================================
# 14. TARGET: SUPABASE
# =============================================================================
#
# Fault-tolerant: on failure the entry is queued to sync-queue.jsonl so that
# reconcile.sh can replay it and close the local<->remote gap. The local write
# (step 13) already succeeded, so no data is lost.
# =============================================================================

SUPABASE_OK=false
if [ "$SUPABASE_ENABLED" = "true" ] && [ -n "$PSQL_BIN" ] && [ -n "$SUPABASE_DB_CONN" ]; then
  # Password comes from .env — expected as SCRIBE_DB_PASSWORD or PGPASSWORD
  # (see templates/.env.example)
  DB_PASSWORD="${SCRIBE_DB_PASSWORD:-${PGPASSWORD:-}}"

  if [ -z "$DB_PASSWORD" ]; then
    echo "WARN: Supabase enabled but no database password found in .env (SCRIBE_DB_PASSWORD or PGPASSWORD)." >&2
  else
    ESCAPED=$(echo "$ENTRY" | jq -c \
      --arg uid "$USER_ID" \
      '{
        id: .id,
        timestamp: .timestamp,
        session_id: .session_id,
        user_id: $uid,
        project: .project,
        type: .type,
        title: .title,
        summary: .summary,
        decisions: (.decisions // []),
        learnings: (.learnings // []),
        corrections: (.corrections // []),
        metrics: (.metrics // {}),
        connections: (.connections // {}),
        growth: (.growth // {}),
        behavioral: (.behavioral // {})
      }' | sed "s/'/''/g")

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

    # PGCONNECT_TIMEOUT bounds how long the writer lock is held if Supabase is unreachable.
    if PGPASSWORD="$DB_PASSWORD" PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}" "$PSQL_BIN" "$SUPABASE_DB_CONN" -c "$SQL" > /dev/null 2>&1; then
      SUPABASE_OK=true
      TARGETS_WRITTEN="${TARGETS_WRITTEN:+$TARGETS_WRITTEN+}supabase"
    else
      echo "WARN: Supabase insert failed — entry queued to sync-queue.jsonl for reconcile." >&2
      if type scribe_log_error >/dev/null 2>&1; then
        scribe_log_error "writer" "io" "Supabase insert failed — queued" "entry_id=$SHORT_ID, project=$PROJECT, type=$TYPE"
      fi
      # Enqueue for retry — reconcile.sh will replay this queue and close the
      # local<->remote gap. _queued_at records when the failure occurred.
      SYNC_QUEUE="$DATA_DIR/sync-queue.jsonl"
      echo "$ENTRY" | jq -c \
        --arg uid "$USER_ID" \
        --arg queued_at "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" \
        '{
          id: .id,
          timestamp: .timestamp,
          session_id: .session_id,
          user_id: $uid,
          project: .project,
          type: .type,
          title: .title,
          summary: .summary,
          decisions: (.decisions // []),
          learnings: (.learnings // []),
          corrections: (.corrections // []),
          metrics: (.metrics // {}),
          connections: (.connections // {}),
          growth: (.growth // {}),
          behavioral: (.behavioral // {}),
          _queued_at: $queued_at
        }' >> "$SYNC_QUEUE"
      TARGETS_WRITTEN="${TARGETS_WRITTEN:+$TARGETS_WRITTEN+}queued"
    fi
  fi
fi

# =============================================================================
# 15. TARGET: GOOGLE DRIVE (marker file)
# =============================================================================

DRIVE_PENDING=false
if [ "$DRIVE_ENABLED" = "true" ]; then
  # Google Drive sync requires MCP or API auth — not available from bash.
  # Write a marker file so the adapter layer knows to sync this entry.
  mkdir -p "$ENTRIES_DIR"
  cat > "$ENTRIES_DIR/${SHORT_ID}.drive-pending" <<MARKER
{
  "entry_id": "$ID",
  "short_id": "$SHORT_ID",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "folder_id": "$DRIVE_FOLDER_ID",
  "status": "pending",
  "note": "Drive sync deferred — requires MCP adapter or API auth"
}
MARKER
  DRIVE_PENDING=true
  TARGETS_WRITTEN="${TARGETS_WRITTEN:+$TARGETS_WRITTEN+}drive-pending"
fi

# =============================================================================
# 16. UPDATE INDEX.JSON
# =============================================================================

# Initialize index.json if it doesn't exist — or self-heal if a previous
# (pre-lock) race left it empty/corrupt. Corrupt content is quarantined, never deleted.
if [ -f "$INDEX" ] && { [ ! -s "$INDEX" ] || ! jq empty "$INDEX" >/dev/null 2>&1; }; then
  _CORRUPT_COPY="$INDEX.corrupt-$(date -u +%Y%m%dT%H%M%SZ).$$"
  mv "$INDEX" "$_CORRUPT_COPY" 2>/dev/null || true
  echo "WARN: index.json was empty/corrupt — quarantined to $(basename "$_CORRUPT_COPY") and reinitialized." >&2
  if type scribe_log_error >/dev/null 2>&1; then
    scribe_log_error "writer" "io" "index.json empty/corrupt — quarantined and reinitialized" "entry_id=$SHORT_ID, quarantine=$(basename "$_CORRUPT_COPY")"
  fi
fi
if [ ! -f "$INDEX" ]; then
  cat > "$INDEX" <<'INIT_INDEX'
{
  "total_entries": 0,
  "projects": {},
  "tag_cloud": {},
  "growth_summary": {
    "total_features": 0,
    "total_bugs_fixed": 0,
    "total_learnings": 0,
    "total_corrections": 0,
    "skill_distribution": {}
  },
  "last_updated": null
}
INIT_INDEX
fi

NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
SESSION_DATE=$(echo "$TIMESTAMP" | cut -c1-10)

UPDATED_INDEX=$(jq \
  --arg proj "$PROJECT" \
  --arg sess_date "$SESSION_DATE" \
  --arg now "$NOW" \
  '
    .total_entries += 1
    | .projects[$proj].entries = ((.projects[$proj].entries // 0) + 1)
    | .projects[$proj].last_session = $sess_date
    | .last_updated = $now
  ' "$INDEX")

# Update tag cloud
HAS_TAGS=$(echo "$ENTRY" | jq 'has("connections") and (.connections | has("tags")) and (.connections.tags | length > 0)')
if [ "$HAS_TAGS" = "true" ]; then
  TAGS=$(echo "$ENTRY" | jq -r '.connections.tags[]')
  while IFS= read -r tag; do
    [ -z "$tag" ] && continue
    UPDATED_INDEX=$(echo "$UPDATED_INDEX" | jq --arg t "$tag" '
      .tag_cloud[$t] = ((.tag_cloud[$t] // 0) + 1)
    ')
  done <<< "$TAGS"
fi

# Update growth summary counters
case "$TYPE" in
  feature_shipped) UPDATED_INDEX=$(echo "$UPDATED_INDEX" | jq '.growth_summary.total_features += 1') ;;
  bug_fixed)       UPDATED_INDEX=$(echo "$UPDATED_INDEX" | jq '.growth_summary.total_bugs_fixed += 1') ;;
  learning)        UPDATED_INDEX=$(echo "$UPDATED_INDEX" | jq '.growth_summary.total_learnings += 1') ;;
esac

# Count corrections in this entry and add to total (counts per-correction, not
# per-type — an entry of any type can carry corrections[])
CORRECTION_COUNT=$(echo "$ENTRY" | jq '(.corrections // []) | length')
if [ "$CORRECTION_COUNT" -gt 0 ] 2>/dev/null; then
  UPDATED_INDEX=$(echo "$UPDATED_INDEX" | jq --argjson n "$CORRECTION_COUNT" '.growth_summary.total_corrections = ((.growth_summary.total_corrections // 0) + $n)')
fi

# Update skill distribution
HAS_SKILL=$(echo "$ENTRY" | jq 'has("growth") and (.growth | has("skill_area")) and (.growth.skill_area | length > 0)')
if [ "$HAS_SKILL" = "true" ]; then
  SKILL_AREA=$(echo "$ENTRY" | jq -r '.growth.skill_area')
  UPDATED_INDEX=$(echo "$UPDATED_INDEX" | jq --arg s "$SKILL_AREA" '
    .growth_summary.skill_distribution[$s] = ((.growth_summary.skill_distribution[$s] // 0) + 1)
  ')
fi

# Atomic write: tmp file + rename. Never truncate index.json in place — a
# concurrent reader (or a crash mid-write) must always see a complete file.
_INDEX_TMP="${INDEX}.tmp.$$"
if printf '%s\n' "$UPDATED_INDEX" | jq '.' > "$_INDEX_TMP" 2>/dev/null && [ -s "$_INDEX_TMP" ]; then
  mv -f "$_INDEX_TMP" "$INDEX"
else
  rm -f "$_INDEX_TMP" 2>/dev/null || true
  echo "WARN: index.json update produced invalid JSON — index left unchanged for this entry." >&2
  if type scribe_log_error >/dev/null 2>&1; then
    scribe_log_error "writer" "io" "index.json update failed validation — skipped" "entry_id=$SHORT_ID"
  fi
fi

# =============================================================================
# 17. UPDATE CORRECTION TRACKER (core/track-corrections.py)
#
# The entry JSON is piped over STDIN — never substituted into Python source.
# (The old inline approach crashed on entries containing escaped quotes,
# silently discarding correction data after the journal write, and was a
# latent code-exec vector.)
#
# Tracker failure is NON-FATAL: the journal write already succeeded, so we
# log the error and continue — the tracker can be rebuilt from the journal.
# =============================================================================

HAS_CORRECTIONS=$(echo "$ENTRY" | jq '(.corrections // []) | length > 0')
if [ "$HAS_CORRECTIONS" = "true" ]; then
  # Initialize tracker if it doesn't exist
  if [ ! -f "$CORRECTION_TRACKER" ]; then
    echo '{"schema_version":1,"patterns":{},"last_updated":""}' > "$CORRECTION_TRACKER"
  fi

  TRACKER_SCRIPT="$SCRIPT_DIR/track-corrections.py"
  if [ -f "$TRACKER_SCRIPT" ]; then
    if ! printf '%s' "$ENTRY" | python3 "$TRACKER_SCRIPT" "$CORRECTION_TRACKER"; then
      echo "WARN: correction-tracker update failed — journal entry is safe; tracker skipped." >&2
      if type scribe_log_error >/dev/null 2>&1; then
        scribe_log_error "writer" "runtime" "track-corrections.py failed — tracker not updated" "entry_id=$SHORT_ID"
      fi
    fi
  else
    echo "WARN: $TRACKER_SCRIPT not found — correction tracker not updated." >&2
    if type scribe_log_error >/dev/null 2>&1; then
      scribe_log_error "writer" "config" "track-corrections.py missing — tracker not updated" "entry_id=$SHORT_ID"
    fi
  fi
fi

# Fallback for installs with local storage disabled: by this point the entry
# has been persisted to Supabase or the sync queue, so the hash is safe to
# record. No-op when 13b already recorded it (HASH_RECORDED guard).
record_content_hash

# --- END CRITICAL SECTION ---
release_scribe_lock

# =============================================================================
# 18. GENERATE RECEIPT
# =============================================================================

# Read session count for receipt verbosity
SESSION_COUNT=0
if [ -f "$SESSION_COUNTER" ]; then
  SESSION_COUNT=$(jq -r '.total_sessions // 0' "$SESSION_COUNTER" 2>/dev/null || echo "0")
fi

echo ""
if [ "$SESSION_COUNT" -lt 5 ]; then
  # Detailed receipt for new users (first 5 sessions)
  echo "SCRIBE RECEIPT"
  echo "  Entry:   $TITLE"
  echo "  Type:    $TYPE"
  echo "  Project: $PROJECT"
  echo "  ID:      $SHORT_ID"
  echo "  Targets: $TARGETS_WRITTEN"

  # Tracking purpose based on type
  case "$TYPE" in
    session_open)       echo "  Purpose: Marks session boundaries for pattern analysis over time" ;;
    feature_shipped)    echo "  Purpose: Tracks what you build — feeds growth reports and skill distribution" ;;
    bug_fixed)          echo "  Purpose: Tracks fixes — patterns here reveal recurring problem areas" ;;
    decision_made)      echo "  Purpose: Records your reasoning — future you (and teammates) can see why you chose this path" ;;
    learning)           echo "  Purpose: Captures new understanding — Scribe uses these for growth narratives" ;;
    correction)         echo "  Purpose: Tracks mistakes honestly — escalation system watches for repeats and intervenes" ;;
    process_created)    echo "  Purpose: Documents workflows you've built — helps identify process evolution" ;;
    tool_discovered)    echo "  Purpose: Logs new tools/techniques — feeds your expanding toolkit narrative" ;;
    feedback_received)  echo "  Purpose: Records external input — correlates feedback with behavioral changes over time" ;;
    milestone)          echo "  Purpose: Marks significant achievements — anchors your growth timeline" ;;
    reflection)         echo "  Purpose: Session summary — the Reader uses these for longitudinal analysis" ;;
    essence)            echo "  Purpose: The soul — who you/the work/the team truly are, in your own words. Read first, never flattened." ;;
    *)                  echo "  Purpose: Custom entry type — tracked in your journal for future reference" ;;
  esac

  if [ "$DRIVE_PENDING" = true ]; then
    echo "  Note:    Google Drive sync pending — will complete via MCP adapter"
  fi
else
  # Concise receipt for experienced users
  echo "SCRIBE: $TYPE — \"$TITLE\" [$PROJECT] -> $TARGETS_WRITTEN"
  if [ "$DRIVE_PENDING" = true ]; then
    echo "  (Drive sync pending)"
  fi
fi

# =============================================================================
# 19. POST-WRITE HOOK: SESSION BRIEF (non-fatal; no-op until core/brief.py exists)
# =============================================================================

# Pass --data-dir so pointer.json installs brief the SAME journal this write
# went to. brief.py's own default resolution ($SCRIBE_DATA_PATH, else the
# default data dir) could otherwise generate briefs from the wrong journal.
if [ -f "$SCRIPT_DIR/brief.py" ]; then
  python3 "$SCRIPT_DIR/brief.py" --project "$PROJECT" --data-dir "$DATA_DIR" >/dev/null 2>&1 || true
fi

# =============================================================================
# 20. POST-WRITE HOOK: DOCTOR INTEGRITY CHECK (non-fatal; no-op until core/doctor.py exists)
#
# Runs when Scribe runs, so derived state can never rot silently. --check
# mutates NOTHING (Scribe proposes, never self-changes): it verifies entry ids,
# seen-hashes.txt, and index.json against the journal. Silent when clean; on
# drift it surfaces a one-line nudge. Repairs stay a deliberate human --fix.
# Runs after the writer lock is released and the receipt is printed, so it
# never blocks the write or delays the receipt.
# =============================================================================
if [ -f "$SCRIPT_DIR/doctor.py" ]; then
  if ! python3 "$SCRIPT_DIR/doctor.py" --check --data-dir "$DATA_DIR" >/dev/null 2>&1; then
    echo "SCRIBE DOCTOR: derived-state drift detected — repair with: python3 \"$SCRIPT_DIR/doctor.py\" --fix" >&2
    if type scribe_log_error &>/dev/null; then
      scribe_log_error "writer" "integrity" "doctor --check found drift after write" "entry_id=$SHORT_ID"
    fi
  fi
fi

exit 0
