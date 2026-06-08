#!/usr/bin/env bash
# writer.sh — Scribe multi-target journal entry writer (generalized)
# Writes entry to: individual JSON file, JSONL index, Supabase (if configured),
# Google Drive marker (if configured), index.json stats, correction-tracker.json.
#
# Fully config-driven — no hardcoded paths, projects, or credentials.
# Compatible with bash 3.2+ (macOS default).
#
# Write-time hardening:
#   - Enum enforcement reads valid values from the install's schema.json
#   - Normalization backstop reads its map from DATA_DIR/normalizations.json
#     (falls back to templates/normalizations.template.json); logs all repairs
#   - Fault-tolerant Supabase sync-queue: failed writes are queued for reconcile
#   - Content-hash dedup: prevents duplicate journal entries
#
# Usage:
#   echo '{"id":"...","timestamp":"...",...}' | writer.sh
#   writer.sh entry.json

set -euo pipefail

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

  # 2. pointer.json in the same directory as this script
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  local pointer="$script_dir/../pointer.json"
  if [ -f "$pointer" ]; then
    local ptr_path
    ptr_path=$(jq -r '.data_path // empty' "$pointer" 2>/dev/null || true)
    if [ -n "$ptr_path" ]; then
      # Expand ~ to $HOME
      echo "${ptr_path/#\~/$HOME}"
      return
    fi
  fi

  # 3. Check parent of script dir (skill install may nest core/)
  local alt_pointer="$script_dir/pointer.json"
  if [ -f "$alt_pointer" ]; then
    local alt_path
    alt_path=$(jq -r '.data_path // empty' "$alt_pointer" 2>/dev/null || true)
    if [ -n "$alt_path" ]; then
      echo "${alt_path/#\~/$HOME}"
      return
    fi
  fi

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

# Core entry types — accepted without config. Custom types also allowed.
CORE_TYPES="session_open feature_shipped bug_fixed decision_made learning correction process_created tool_discovered feedback_received milestone reflection"

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

if [ -f "$CONFIG_FILE" ]; then
  # Storage targets
  SUPABASE_ENABLED=$(jq -r '.storage.supabase.enabled // false' "$CONFIG_FILE")
  SUPABASE_DB_CONN=$(jq -r '.storage.supabase.db_connection // empty' "$CONFIG_FILE" 2>/dev/null || true)
  DRIVE_ENABLED=$(jq -r '.storage.google_drive.enabled // false' "$CONFIG_FILE")
  DRIVE_FOLDER_ID=$(jq -r '.storage.google_drive.folder_id // empty' "$CONFIG_FILE" 2>/dev/null || true)
  LOCAL_ENABLED=$(jq -r '.storage.local.enabled // true' "$CONFIG_FILE")

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
# 8. VALIDATE REQUIRED FIELDS
# =============================================================================

REQUIRED_FIELDS="id timestamp session_id user_id project type title summary"
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
ENTRY=$(echo "$ENTRY" | jq --arg id "$ID" '.id = $id')           # propagate lowercase to entry file + journal index + DB
SHORT_ID=$(echo "$ID" | cut -c1-8)
TIMESTAMP=$(echo "$ENTRY" | jq -r '.timestamp')

# S2 (2026-06-08): REPAIR invalid id/timestamp at the single door — never persist a literal
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
USER_ID=$(echo "$ENTRY" | jq -r '.user_id')

# =============================================================================
# 10. RESOLVE PROJECT ALIASES
# =============================================================================

if [ -n "$PROJECT_ALIASES" ]; then
  RESOLVED_PROJECT="$PROJECT"
  # Iterate alias=canonical pairs
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
# 11. VALIDATE PROJECT
# =============================================================================

if [ "$PROJECTS_CONFIGURED" = "true" ]; then
  PROJ_VALID=$(jq -r --arg p "$PROJECT" '.projects | has($p)' "$CONFIG_FILE" 2>/dev/null || echo "false")
  if [ "$PROJ_VALID" != "true" ]; then
    # List valid projects for the error message
    VALID_LIST=$(jq -r '.projects | keys | join(", ")' "$CONFIG_FILE" 2>/dev/null || echo "(none)")
    echo "ERROR: Unknown project '$PROJECT'. Configured projects: $VALID_LIST" >&2
    exit 1
  fi
fi
# If no projects are configured, accept any project name (new user)

# =============================================================================
# 12. VALIDATE TYPE (warn on non-core, but accept custom types)
# =============================================================================

TYPE_IS_CORE=false
for t in $CORE_TYPES; do
  if [ "$TYPE" = "$t" ]; then TYPE_IS_CORE=true; break; fi
done
if [ "$TYPE_IS_CORE" = false ]; then
  # S2 (2026-06-08): the DB type CHECK rejects non-core types — a custom type silently fails the
  # DB insert and queues forever. Hard-normalize to a valid core type (map common variants;
  # fall back to "milestone") so the entry persists. No data loss of the entry.
  _BAD_TYPE="$TYPE"
  case "$TYPE" in
    decision|decided|decision-made) TYPE="decision_made" ;;
    feature|feature_built|feature_complete|shipped|built) TYPE="feature_shipped" ;;
    bug|bugfix|fix|fixed|bug-fixed) TYPE="bug_fixed" ;;
    learned|learnt|lesson|insight|learnings) TYPE="learning" ;;
    process|process-created|workflow) TYPE="process_created" ;;
    tool|tool-discovered) TYPE="tool_discovered" ;;
    feedback|feedback-received) TYPE="feedback_received" ;;
    session|session-open|open|start) TYPE="session_open" ;;
    reflect|reflections) TYPE="reflection" ;;
    *) TYPE="milestone" ;;
  esac
  ENTRY=$(echo "$ENTRY" | jq --arg t "$TYPE" '.type = $t')
  printf '{"ts":"%s","field":"type","from":%s,"to":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$(printf '%s' "$_BAD_TYPE" | jq -R .)" "$TYPE" >> "$DATA_DIR/normalizations.jsonl" 2>/dev/null || true
  echo "NOTE: invalid type '$_BAD_TYPE' normalized to '$TYPE' (DB enum) at the writer door." >&2
fi

# =============================================================================
# 12b. ENUM ENFORCEMENT — normalize invalid enum values at the writer boundary
#
# Reads valid values FROM schema.json (install's core/schema.json, with
# DATA_DIR/schema.json taking precedence if the user placed one there).
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
  # Fall back to the schema shipped with this install
  INSTALL_SCHEMA="$SCRIPT_DIR/schema.json"
  if [ -f "$INSTALL_SCHEMA" ]; then
    SCHEMA_FILE="$INSTALL_SCHEMA"
  else
    SCHEMA_FILE=""
  fi
fi

# Resolve normalizations map: user's DATA_DIR copy first, then install template
NORM_MAP_FILE="$DATA_DIR/normalizations.json"
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
log_norm() {
  local field="$1"
  local from_val="$2"
  local to_val="$3"
  printf '{"ts":"%s","field":"%s","from":"%s","to":"%s","entry_id":"%s"}\n' \
    "$NORM_NOW" "$field" "$from_val" "$to_val" "$ID" >> "$NORM_LOG"
  echo "NOTE: Normalized $field: '$from_val' -> '$to_val' (logged to normalizations.jsonl)." >&2
}

# Helper: enforce one enum field in the entry.
# Usage: enforce_enum <entry_jq_path> <schema_jq_path> <norm_key> <log_field_name>
# entry_jq_path: jq expression to test and read the field (e.g. '.growth.complexity')
# schema_jq_path: jq path to the enum array in schema (e.g. '.properties.growth.properties.complexity.enum')
# norm_key: key in normalizations map (e.g. "complexity")
# log_field_name: human-readable name for normalization log (e.g. "growth.complexity")
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

# Re-read TYPE from (possibly modified) ENTRY
TYPE=$(echo "$ENTRY" | jq -r '.type')

# =============================================================================
# 12c. CONTENT-HASH DEDUP
#
# Computes a stable hash from: project + type + title + date(10) + summary[0:200]
# Checks against seen-hashes.txt. On collision: skip write, log to duplicates.jsonl.
# A valid (new) entry passes through and its hash is recorded.
# Bash 3.2-compatible: uses shasum (macOS) falling back to sha256sum (Linux).
# =============================================================================

SEEN_HASHES="$DATA_DIR/seen-hashes.txt"
DUPLICATES_LOG="$DATA_DIR/duplicates.jsonl"

# Build hash input: project|type|title|date|summary_prefix
ENTRY_DATE=$(echo "$TIMESTAMP" | cut -c1-10)
SUMMARY_PREFIX=$(echo "$ENTRY" | jq -r '.summary // empty' | cut -c1-200)
HASH_INPUT="${PROJECT}|${TYPE}|${TITLE}|${ENTRY_DATE}|${SUMMARY_PREFIX}"

# Compute hash — shasum on macOS, sha256sum on Linux
CONTENT_HASH=""
if command -v shasum >/dev/null 2>&1; then
  CONTENT_HASH=$(printf '%s' "$HASH_INPUT" | shasum -a 256 | cut -c1-64)
elif command -v sha256sum >/dev/null 2>&1; then
  CONTENT_HASH=$(printf '%s' "$HASH_INPUT" | sha256sum | cut -c1-64)
fi
# If no hash tool is available, CONTENT_HASH stays empty and dedup is skipped

IS_DUPLICATE=false
if [ -n "$CONTENT_HASH" ]; then
  touch "$SEEN_HASHES"
  if grep -qF "$CONTENT_HASH" "$SEEN_HASHES" 2>/dev/null; then
    IS_DUPLICATE=true
    # Log the duplicate (flag only — no data loss, no hard delete)
    _DUP_NOW=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    printf '{"ts":"%s","hash":"%s","entry_id":"%s","project":"%s","type":"%s","title":"%s","date":"%s"}\n' \
      "$_DUP_NOW" "$CONTENT_HASH" "$ID" "$PROJECT" "$TYPE" "$TITLE" "$ENTRY_DATE" >> "$DUPLICATES_LOG"
    echo "NOTE: Duplicate entry detected (content-hash match). Logged to duplicates.jsonl — not written to journal." >&2
  else
    # Record the hash so future duplicates are caught
    echo "$CONTENT_HASH" >> "$SEEN_HASHES"
  fi
fi

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
      user_id: .user_id,
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
  DB_PASSWORD="${SCRIBE_DB_PASSWORD:-${PGPASSWORD:-}}"

  if [ -z "$DB_PASSWORD" ]; then
    echo "WARN: Supabase enabled but no database password found in .env (SCRIBE_DB_PASSWORD or PGPASSWORD)." >&2
  else
    ESCAPED=$(echo "$ENTRY" | jq -c '{
      id: .id,
      timestamp: .timestamp,
      session_id: .session_id,
      user_id: .user_id,
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

    if PGPASSWORD="$DB_PASSWORD" "$PSQL_BIN" "$SUPABASE_DB_CONN" -c "$SQL" > /dev/null 2>&1; then
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
      _QUEUED_AT=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
      echo "$ENTRY" | jq -c \
        --arg queued_at "$_QUEUED_AT" \
        '{
          id: .id,
          timestamp: .timestamp,
          session_id: .session_id,
          user_id: .user_id,
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

# Initialize index.json if it doesn't exist
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
  correction)      UPDATED_INDEX=$(echo "$UPDATED_INDEX" | jq '.growth_summary.total_corrections = ((.growth_summary.total_corrections // 0) + 1)') ;;
esac

# Update skill distribution
HAS_SKILL=$(echo "$ENTRY" | jq 'has("growth") and (.growth | has("skill_area")) and (.growth.skill_area | length > 0)')
if [ "$HAS_SKILL" = "true" ]; then
  SKILL_AREA=$(echo "$ENTRY" | jq -r '.growth.skill_area')
  UPDATED_INDEX=$(echo "$UPDATED_INDEX" | jq --arg s "$SKILL_AREA" '
    .growth_summary.skill_distribution[$s] = ((.growth_summary.skill_distribution[$s] // 0) + 1)
  ')
fi

echo "$UPDATED_INDEX" | jq '.' > "$INDEX"

# =============================================================================
# 17. UPDATE CORRECTION TRACKER
# =============================================================================

HAS_CORRECTIONS=$(echo "$ENTRY" | jq '(.corrections // []) | length > 0')
if [ "$HAS_CORRECTIONS" = "true" ]; then
  # Initialize tracker if it doesn't exist
  if [ ! -f "$CORRECTION_TRACKER" ]; then
    echo '{"patterns":{}}' | jq '.' > "$CORRECTION_TRACKER"
  fi

  CORRECTIONS=$(echo "$ENTRY" | jq -r '.corrections[]')
  ENTRY_DATE=$(echo "$TIMESTAMP" | cut -c1-10)

  while IFS= read -r correction; do
    [ -z "$correction" ] && continue

    # Normalize correction text for matching (lowercase, trim whitespace)
    CORRECTION_LOWER=$(echo "$correction" | tr '[:upper:]' '[:lower:]')

    # Check each existing pattern for a substring match
    MATCHED_KEY=""
    PATTERN_KEYS=$(jq -r '.patterns | keys[]' "$CORRECTION_TRACKER" 2>/dev/null || true)

    while IFS= read -r pkey; do
      [ -z "$pkey" ] && continue
      PATTERN_DESC=$(jq -r --arg k "$pkey" '.patterns[$k].description // ""' "$CORRECTION_TRACKER" | tr '[:upper:]' '[:lower:]')
      # Check if the correction contains the pattern description or vice versa
      case "$CORRECTION_LOWER" in
        *"$PATTERN_DESC"*) MATCHED_KEY="$pkey"; break ;;
      esac
      case "$PATTERN_DESC" in
        *"$CORRECTION_LOWER"*) MATCHED_KEY="$pkey"; break ;;
      esac
    done <<< "$PATTERN_KEYS"

    if [ -n "$MATCHED_KEY" ]; then
      # Add occurrence to existing pattern
      UPDATED_TRACKER=$(jq \
        --arg k "$MATCHED_KEY" \
        --arg eid "$SHORT_ID" \
        --arg edate "$ENTRY_DATE" \
        --arg ctx "$correction" \
        --arg now "$NOW" \
        '
          .patterns[$k].occurrences += [{"entry_id": $eid, "date": $edate, "context": $ctx}]
          | .patterns[$k].last_updated = $now
          | .patterns[$k] as $p
          | if ($p.occurrences | length) >= 5 and $p.level != "critical" then
              .patterns[$k].level = "critical"
              | .patterns[$k].escalated_at = $now
            elif ($p.occurrences | length) >= 3 and $p.level == "observation" then
              .patterns[$k].level = "guardrail"
              | .patterns[$k].escalated_at = $now
            else .
            end
        ' "$CORRECTION_TRACKER")
      echo "$UPDATED_TRACKER" | jq '.' > "$CORRECTION_TRACKER"
    else
      # Create new pattern — generate a slug from the first few words
      SLUG=$(echo "$correction" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g' | awk '{for(i=1;i<=4&&i<=NF;i++) printf "%s-", $i; print ""}' | sed 's/-$//' | cut -c1-40)

      # Ensure slug is unique
      EXISTING=$(jq -r --arg s "$SLUG" '.patterns | has($s)' "$CORRECTION_TRACKER" 2>/dev/null || echo "false")
      if [ "$EXISTING" = "true" ]; then
        SLUG="${SLUG}-${SHORT_ID}"
      fi

      UPDATED_TRACKER=$(jq \
        --arg k "$SLUG" \
        --arg desc "$correction" \
        --arg eid "$SHORT_ID" \
        --arg edate "$ENTRY_DATE" \
        --arg now "$NOW" \
        '
          .patterns[$k] = {
            "description": $desc,
            "occurrences": [{"entry_id": $eid, "date": $edate, "context": $desc}],
            "level": "observation",
            "escalated_at": null,
            "resolved": false,
            "last_updated": $now
          }
        ' "$CORRECTION_TRACKER")
      echo "$UPDATED_TRACKER" | jq '.' > "$CORRECTION_TRACKER"
    fi
  done <<< "$CORRECTIONS"
fi

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

exit 0
