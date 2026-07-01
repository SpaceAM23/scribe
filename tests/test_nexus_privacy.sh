#!/usr/bin/env bash
# tests/test_nexus_privacy.sh — NEXUS privacy proof (team/Librarian backends)
# Proves: the anon key cannot read nexus_nodes (401 or empty array).
#
# Fully parameterized — nothing about a specific Supabase project is hardcoded:
#   * project ref:  $SCRIBE_SUPABASE_PROJECT_REF, else parsed from the
#                   config.json .storage.supabase.url of the resolved data dir
#   * management:   $SUPABASE_ACCESS_TOKEN   (Supabase Management API token)
#   * anon key:     $SCRIBE_SUPABASE_ANON_KEY, else config.json anon_key
# All can live in DATA_DIR/.env. Missing configuration -> SKIP (exit 0), so
# the suite stays green for installs without a NEXUS backend.
#
# Uses scratch context only — no writes to real journal/index/tracker.
# Compatible: bash 3.2 / macOS (no head -n -1, no declare -A)

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

# Resolve data dir — same priority as writer.sh
resolve_data_path() {
  if [ -n "${SCRIBE_DATA_PATH:-}" ]; then
    echo "$SCRIBE_DATA_PATH"
    return
  fi
  local pointer="$REPO_DIR/pointer.json"
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
ENV_FILE="$DATA_DIR/.env"
CONFIG_FILE="$DATA_DIR/config.json"

# Load env — set +e while sourcing: bash 3.2 aborts inside a sourced file on
# malformed non-assignment lines even under '|| true'
if [ -f "$ENV_FILE" ]; then
  set -a; set +e; . "$ENV_FILE" 2>/dev/null; set -e; set +a
fi

# Resolve the project ref
REF="${SCRIBE_SUPABASE_PROJECT_REF:-}"
if [ -z "$REF" ] && [ -f "$CONFIG_FILE" ]; then
  SUPA_URL=$(jq -r '.storage.supabase.url // empty' "$CONFIG_FILE" 2>/dev/null || true)
  if [ -n "$SUPA_URL" ]; then
    REF=$(printf '%s' "$SUPA_URL" | sed -E 's#^https?://([^.]+)\.supabase\.co.*$#\1#')
    [ "$REF" = "$SUPA_URL" ] && REF=""
  fi
fi

# Resolve the anon key
ANON_KEY="${SCRIBE_SUPABASE_ANON_KEY:-}"
if [ -z "$ANON_KEY" ] && [ -f "$CONFIG_FILE" ]; then
  ANON_KEY=$(jq -r '.storage.supabase.anon_key // empty' "$CONFIG_FILE" 2>/dev/null || true)
fi

# Validate required config — SKIP cleanly when this install has no NEXUS backend
if [ -z "$REF" ]; then
  echo "SKIP: no Supabase project ref (set SCRIBE_SUPABASE_PROJECT_REF or config.json .storage.supabase.url)"
  exit 0
fi
if [ -z "${SUPABASE_ACCESS_TOKEN:-}" ]; then
  echo "SKIP: SUPABASE_ACCESS_TOKEN not set"
  exit 0
fi
if [ -z "$ANON_KEY" ]; then
  echo "SKIP: no anon key (set SCRIBE_SUPABASE_ANON_KEY or config.json .storage.supabase.anon_key)"
  exit 0
fi

BASE_URL="https://${REF}.supabase.co"
API_URL="https://api.supabase.com/v1/projects/${REF}/database/query"

# macOS-compatible response helpers (no head -n -1 on BSD)
strip_last_line() { awk 'NR>1{print prev} {prev=$0}'; }
get_last_line()   { awk 'END{print}'; }

PASS_COUNT=0
FAIL_COUNT=0

pass() { echo "  PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); }
fail() { echo "  FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); }

echo "==> test_nexus_privacy.sh"
echo "    Project: $REF"
echo ""

# ---------------------------------------------------------------------------
# Test 1: Tables exist (schema applied)
# ---------------------------------------------------------------------------
echo "--- Test 1: nexus_* tables exist ---"
TABLE_SQL="SELECT COUNT(*) AS n FROM information_schema.tables WHERE table_schema = 'public' AND table_name LIKE 'nexus_%';"
full_resp=$(curl -s -w "\n%{http_code}" \
  -X POST "$API_URL" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary "$(jq -n --arg q "$TABLE_SQL" '{"query":$q}')")
body=$(printf '%s\n' "$full_resp" | strip_last_line)
http_code=$(printf '%s\n' "$full_resp" | get_last_line)
if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
  tcount=$(printf '%s\n' "$body" | jq -r '.[0].n' 2>/dev/null || echo 0)
  if [ "$tcount" -ge 5 ]; then
    pass "nexus_* tables exist (found $tcount)"
  else
    fail "nexus_* tables missing (found $tcount, expected >= 5) — apply templates/nexus-schema.template.sql first"
  fi
else
  fail "table check API call failed (HTTP $http_code): $body"
fi

# ---------------------------------------------------------------------------
# Test 2: Management API (service context) can read nexus_nodes
# ---------------------------------------------------------------------------
echo ""
echo "--- Test 2: service context can read nexus_nodes ---"
READ_SQL="SELECT id FROM nexus_nodes LIMIT 1;"
full_resp=$(curl -s -w "\n%{http_code}" \
  -X POST "$API_URL" \
  -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" \
  -H "Content-Type: application/json" \
  --data-binary "$(jq -n --arg q "$READ_SQL" '{"query":$q}')")
body=$(printf '%s\n' "$full_resp" | strip_last_line)
http_code=$(printf '%s\n' "$full_resp" | get_last_line)
if [ "$http_code" -ge 200 ] && [ "$http_code" -lt 300 ]; then
  pass "service context can query nexus_nodes (HTTP $http_code)"
else
  fail "service context read failed (HTTP $http_code): $body"
fi

# ---------------------------------------------------------------------------
# Test 3: Anon key CANNOT read nexus_nodes
# Must get HTTP 401 OR HTTP 200 with body == []
# ---------------------------------------------------------------------------
echo ""
echo "--- Test 3: anon key denied on nexus_nodes ---"
anon_status=$(curl -s -o /dev/null -w "%{http_code}" \
  "${BASE_URL}/rest/v1/nexus_nodes?select=id" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}")

anon_body=$(curl -s \
  "${BASE_URL}/rest/v1/nexus_nodes?select=id" \
  -H "apikey: ${ANON_KEY}" \
  -H "Authorization: Bearer ${ANON_KEY}")

echo "    anon HTTP status: $anon_status"

if [ "$anon_status" = "401" ]; then
  pass "anon denied with HTTP 401"
elif [ "$anon_status" = "200" ] && [ "$anon_body" = "[]" ]; then
  pass "anon gets HTTP 200 but empty array [] — RLS blocks all rows"
elif [ "$anon_status" = "200" ]; then
  fail "PRIVACY BREACH: anon read nexus_nodes and got non-empty data"
elif [ "$anon_status" = "404" ]; then
  # 404 means table doesn't exist in PostgREST schema cache — not a privacy
  # breach per se, but the schema must be applied first. Flag as fail so
  # apply must run before this passes.
  fail "nexus_nodes not found in schema cache (HTTP 404) — apply the NEXUS schema first"
else
  fail "unexpected anon response HTTP $anon_status body: $anon_body"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "==> Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [ "$FAIL_COUNT" -gt 0 ]; then
  exit 1
fi
echo "==> test_nexus_privacy.sh PASSED"
