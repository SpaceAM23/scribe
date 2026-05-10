#!/usr/bin/env bash
# writer.sh — Scribe multi-target journal entry writer (generalized)
# Writes entry to: individual JSON file, JSONL index, Supabase (if configured),
# Google Drive marker (if configured), index.json stats, correction-tracker.json.
#
# Fully config-driven — no hardcoded paths, projects, or credentials.
# Compatible with bash 3.2+ (macOS default).
#
# Usage:
#   echo '{"id":"...","timestamp":"...",...}' | writer.sh
#   writer.sh entry.json

set -euo pipefail

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
  if command -v psql &>/dev/null; then
    command -v psql
    return
  fi

  # 2. Common macOS locations
  local candidates=(
    "/usr/local/bin/psql"
    "/opt/homebrew/bin/psql"
  )

  # 3. Homebrew libpq (multiple versions)
  local libpq_dir
  for libpq_dir in /usr/local/Cellar/libpq/*/bin/psql /opt/homebrew/Cellar/libpq/*/bin/psql; do
    if [ -x "$libpq_dir" ] 2>/dev/null; then
      candidates=("$libpq_dir" "${candidates[@]}")
    fi
  done

  # 4. Linux common locations
  candidates+=(
    "/usr/bin/psql"
    "/usr/lib/postgresql/*/bin/psql"
  )

  for candidate in "${candidates[@]}"; do
    # Handle glob patterns that didn't expand
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

ID=$(echo "$ENTRY" | jq -r '.id')
SHORT_ID=$(echo "$ID" | cut -c1-8)
TIMESTAMP=$(echo "$ENTRY" | jq -r '.timestamp')
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
  echo "NOTE: Custom entry type '$TYPE' (not in core set)." >&2
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
      echo "WARN: Supabase insert failed — entry saved to other targets." >&2
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
