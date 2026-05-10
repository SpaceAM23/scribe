#!/usr/bin/env bash
# new-entry.sh — Interactive entry creator for Scribe journal
# Pre-fills id (UUID) and timestamp, prompts for all fields,
# previews the JSON, then pipes through writer.sh.
#
# Config-driven: reads projects, user_id from config.json.
# Compatible with bash 3.2+ (macOS default).
#
# Usage:
#   ./new-entry.sh

set -euo pipefail

# =============================================================================
# 1. RESOLVE DATA DIRECTORY (same logic as writer.sh)
# =============================================================================

resolve_data_path() {
  # 1. Environment variable
  if [ -n "${SCRIBE_DATA_PATH:-}" ]; then
    echo "$SCRIBE_DATA_PATH"
    return
  fi

  # 2. pointer.json relative to this script (../pointer.json from scripts/)
  local script_dir
  script_dir="$(cd "$(dirname "$0")" && pwd)"
  local pointer="$script_dir/../pointer.json"
  if [ -f "$pointer" ]; then
    local ptr_path
    ptr_path=$(jq -r '.data_path // empty' "$pointer" 2>/dev/null || true)
    if [ -n "$ptr_path" ]; then
      echo "${ptr_path/#\~/$HOME}"
      return
    fi
  fi

  # 3. pointer.json in the script directory itself
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

if [ ! -d "$DATA_DIR" ]; then
  echo "WARN: Data directory '$DATA_DIR' does not exist. Creating it." >&2
  mkdir -p "$DATA_DIR"
fi

# =============================================================================
# 2. RESOLVE WRITER AND CONFIG
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WRITER="$SCRIPT_DIR/../core/writer.sh"

if [ ! -x "$WRITER" ]; then
  echo "ERROR: Writer not found or not executable at $WRITER" >&2
  exit 1
fi

CONFIG_FILE="$DATA_DIR/config.json"

# =============================================================================
# 3. LOAD CONFIG
# =============================================================================

USER_ID=""
PROJECTS_CONFIGURED="false"
PROJECT_LIST=""

if [ -f "$CONFIG_FILE" ]; then
  USER_ID=$(jq -r '.user_id // empty' "$CONFIG_FILE" 2>/dev/null || true)

  PROJ_COUNT=$(jq '.projects | length' "$CONFIG_FILE" 2>/dev/null || echo "0")
  if [ "$PROJ_COUNT" -gt 0 ]; then
    PROJECTS_CONFIGURED="true"
    PROJECT_LIST=$(jq -r '.projects | keys | join(" | ")' "$CONFIG_FILE" 2>/dev/null || true)
  fi
fi

# =============================================================================
# 4. PRE-FILL AUTOMATIC FIELDS
# =============================================================================

ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo ""
echo "=========================================="
echo "  SCRIBE — New Journal Entry"
echo "=========================================="
echo ""
echo "  ID:        $ID"
echo "  Timestamp: $TIMESTAMP"
if [ -n "$USER_ID" ]; then
  echo "  User:      $USER_ID"
fi
echo ""

# =============================================================================
# 5. REQUIRED FIELDS
# =============================================================================

# --- Session ID ---
echo "------------------------------------------"
echo "  SESSION"
echo "------------------------------------------"
read -rp "  Session ID (conversation/session label): " SESSION_ID
if [ -z "$SESSION_ID" ]; then
  echo "  ERROR: session_id is required." >&2
  exit 1
fi

# --- User ID (if not in config) ---
if [ -z "$USER_ID" ]; then
  echo ""
  read -rp "  User ID: " USER_ID
  if [ -z "$USER_ID" ]; then
    echo "  ERROR: user_id is required." >&2
    exit 1
  fi
fi

# --- Project ---
echo ""
echo "------------------------------------------"
echo "  PROJECT"
echo "------------------------------------------"
if [ "$PROJECTS_CONFIGURED" = "true" ]; then
  echo "  Configured: $PROJECT_LIST"
else
  echo "  (No projects configured — enter any name)"
fi
read -rp "  Project: " PROJECT
if [ -z "$PROJECT" ]; then
  echo "  ERROR: project is required." >&2
  exit 1
fi

# Validate against configured projects if applicable
if [ "$PROJECTS_CONFIGURED" = "true" ]; then
  PROJ_VALID=$(jq -r --arg p "$PROJECT" '.projects | has($p)' "$CONFIG_FILE" 2>/dev/null || echo "false")
  if [ "$PROJ_VALID" != "true" ]; then
    echo "  WARN: '$PROJECT' is not in configured projects ($PROJECT_LIST)." >&2
    read -rp "  Continue anyway? [y/N] " PROJ_CONFIRM
    PROJ_CONFIRM=${PROJ_CONFIRM:-N}
    if [[ ! "$PROJ_CONFIRM" =~ ^[Yy]$ ]]; then
      echo "  Cancelled." >&2
      exit 1
    fi
  fi
fi

# --- Type ---
echo ""
echo "------------------------------------------"
echo "  TYPE"
echo "------------------------------------------"
echo "  session_open       feature_shipped    bug_fixed"
echo "  decision_made      learning           correction"
echo "  process_created    tool_discovered    feedback_received"
echo "  milestone          reflection"
read -rp "  Type: " TYPE
if [ -z "$TYPE" ]; then
  echo "  ERROR: type is required." >&2
  exit 1
fi

# Validate type against core set (warn on custom)
CORE_TYPES="session_open feature_shipped bug_fixed decision_made learning correction process_created tool_discovered feedback_received milestone reflection"
TYPE_IS_CORE=false
for t in $CORE_TYPES; do
  if [ "$TYPE" = "$t" ]; then TYPE_IS_CORE=true; break; fi
done
if [ "$TYPE_IS_CORE" = false ]; then
  echo "  NOTE: '$TYPE' is a custom type (not in core set)."
fi

# --- Title ---
echo ""
echo "------------------------------------------"
echo "  CONTENT"
echo "------------------------------------------"
read -rp "  Title (short headline, max 120 chars): " TITLE
if [ -z "$TITLE" ]; then
  echo "  ERROR: title is required." >&2
  exit 1
fi

# --- Summary ---
echo ""
read -rp "  Summary (1+ sentences): " SUMMARY
if [ -z "$SUMMARY" ]; then
  echo "  ERROR: summary is required." >&2
  exit 1
fi

# =============================================================================
# 6. OPTIONAL FIELDS
# =============================================================================

echo ""
echo "------------------------------------------"
echo "  OPTIONAL FIELDS"
echo "------------------------------------------"
echo "  Press Enter to skip any field."
echo ""

# --- Tags ---
read -rp "  Tags (comma-separated): " TAGS_RAW

# --- Skill area ---
echo ""
echo "  Skill areas: architecture | frontend | backend | data | ops | design | leadership"
read -rp "  Skill area (or custom): " SKILL_AREA

# --- Complexity ---
COMPLEXITY=""
if [ -n "$SKILL_AREA" ]; then
  echo ""
  echo "  Complexity: routine | moderate | challenging | breakthrough"
  read -rp "  Complexity: " COMPLEXITY
fi

# --- Autonomy ---
AUTONOMY=""
if [ -n "$SKILL_AREA" ]; then
  echo ""
  echo "  Autonomy: guided | collaborative | independent"
  read -rp "  Autonomy: " AUTONOMY
fi

# --- Decisions (multi-line) ---
echo ""
echo "  Decisions (one per line, blank line to finish):"
DECISIONS=""
while true; do
  read -rp "    > " DECISION_LINE
  if [ -z "$DECISION_LINE" ]; then
    break
  fi
  if [ -z "$DECISIONS" ]; then
    DECISIONS="$DECISION_LINE"
  else
    DECISIONS="$DECISIONS
$DECISION_LINE"
  fi
done

# --- Learnings (multi-line) ---
echo ""
echo "  Learnings (one per line, blank line to finish):"
LEARNINGS=""
while true; do
  read -rp "    > " LEARNING_LINE
  if [ -z "$LEARNING_LINE" ]; then
    break
  fi
  if [ -z "$LEARNINGS" ]; then
    LEARNINGS="$LEARNING_LINE"
  else
    LEARNINGS="$LEARNINGS
$LEARNING_LINE"
  fi
done

# --- Corrections (multi-line) ---
echo ""
echo "  Corrections (one per line, blank line to finish):"
CORRECTIONS=""
while true; do
  read -rp "    > " CORRECTION_LINE
  if [ -z "$CORRECTION_LINE" ]; then
    break
  fi
  if [ -z "$CORRECTIONS" ]; then
    CORRECTIONS="$CORRECTION_LINE"
  else
    CORRECTIONS="$CORRECTIONS
$CORRECTION_LINE"
  fi
done

# =============================================================================
# 7. BUILD JSON
# =============================================================================

# Start with required fields
ENTRY=$(jq -n \
  --arg id "$ID" \
  --arg ts "$TIMESTAMP" \
  --arg sid "$SESSION_ID" \
  --arg uid "$USER_ID" \
  --arg proj "$PROJECT" \
  --arg type "$TYPE" \
  --arg title "$TITLE" \
  --arg summary "$SUMMARY" \
  '{
    id: $id,
    timestamp: $ts,
    session_id: $sid,
    user_id: $uid,
    project: $proj,
    type: $type,
    title: $title,
    summary: $summary
  }')

# Add decisions if provided
if [ -n "$DECISIONS" ]; then
  DECISIONS_JSON=$(echo "$DECISIONS" | jq -R . | jq -s .)
  ENTRY=$(echo "$ENTRY" | jq --argjson d "$DECISIONS_JSON" '.decisions = $d')
fi

# Add learnings if provided
if [ -n "$LEARNINGS" ]; then
  LEARNINGS_JSON=$(echo "$LEARNINGS" | jq -R . | jq -s .)
  ENTRY=$(echo "$ENTRY" | jq --argjson l "$LEARNINGS_JSON" '.learnings = $l')
fi

# Add corrections if provided
if [ -n "$CORRECTIONS" ]; then
  CORRECTIONS_JSON=$(echo "$CORRECTIONS" | jq -R . | jq -s .)
  ENTRY=$(echo "$ENTRY" | jq --argjson c "$CORRECTIONS_JSON" '.corrections = $c')
fi

# Add tags if provided
if [ -n "${TAGS_RAW:-}" ]; then
  TAGS_JSON=$(echo "$TAGS_RAW" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | jq -R . | jq -s .)
  ENTRY=$(echo "$ENTRY" | jq --argjson tags "$TAGS_JSON" '.connections = { tags: $tags }')
fi

# Add growth fields if skill_area provided
if [ -n "${SKILL_AREA:-}" ]; then
  GROWTH_OBJ=$(jq -n --arg s "$SKILL_AREA" '{ skill_area: $s }')

  if [ -n "${COMPLEXITY:-}" ]; then
    GROWTH_OBJ=$(echo "$GROWTH_OBJ" | jq --arg c "$COMPLEXITY" '. + { complexity: $c }')
  fi

  if [ -n "${AUTONOMY:-}" ]; then
    GROWTH_OBJ=$(echo "$GROWTH_OBJ" | jq --arg a "$AUTONOMY" '. + { autonomy: $a }')
  fi

  ENTRY=$(echo "$ENTRY" | jq --argjson g "$GROWTH_OBJ" '.growth = $g')
fi

# =============================================================================
# 8. PREVIEW AND CONFIRM
# =============================================================================

echo ""
echo "=========================================="
echo "  PREVIEW"
echo "=========================================="
echo ""
echo "$ENTRY" | jq '.'
echo ""
echo "=========================================="

read -rp "  Write this entry? [Y/n] " CONFIRM
CONFIRM=${CONFIRM:-Y}

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
  echo "$ENTRY" | "$WRITER"
else
  # Save draft on cancellation
  DRAFT_FILE="/tmp/scribe-draft-$(date +%s).json"
  echo "$ENTRY" | jq '.' > "$DRAFT_FILE"
  echo ""
  echo "  Cancelled. Draft saved to $DRAFT_FILE"
  echo "  To submit later:  cat $DRAFT_FILE | $WRITER"
fi
