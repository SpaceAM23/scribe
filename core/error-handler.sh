#!/usr/bin/env bash
# error-handler.sh — Scribe error capture utility
# Logs errors to errors.jsonl in the user's data directory with full incident context.
# Source this file from other scripts: source "$(dirname "$0")/error-handler.sh"
#
# Usage:
#   scribe_log_error "writer" "io" "Failed to write entry file" "entry_id=abc123, target=local"
#   scribe_log_error "observer" "runtime" "Correction tracker parse failed" "file was empty"

# Requires DATA_DIR to be set by the calling script
ERRORS_LOG="${DATA_DIR:-$HOME/Desktop/Scribe}/errors.jsonl"

scribe_log_error() {
  local component="${1:-unknown}"
  local error_type="${2:-unknown}"
  local message="${3:-No message provided}"
  local context="${4:-}"
  local stack="${5:-}"

  local error_id
  error_id=$(uuidgen 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "err-$(date +%s)")

  local timestamp
  timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

  local scribe_version="unknown"
  local version_file
  version_file="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/VERSION"
  if [ -f "$version_file" ]; then
    scribe_version=$(cat "$version_file" | tr -d '[:space:]')
  fi

  local platform="claude-code"
  local os_info
  os_info=$(uname -s 2>/dev/null || echo "unknown")
  local os_version
  os_version=$(uname -r 2>/dev/null || echo "unknown")
  local bash_version_str="${BASH_VERSION:-unknown}"
  local jq_version
  jq_version=$(jq --version 2>/dev/null || echo "not installed")

  local config_exists="false"
  local config_file="${DATA_DIR:-$HOME/Desktop/Scribe}/config.json"
  if [ -f "$config_file" ]; then
    config_exists="true"
  fi

  local entry_count="unknown"
  local index_file="${DATA_DIR:-$HOME/Desktop/Scribe}/index.json"
  if [ -f "$index_file" ]; then
    entry_count=$(jq -r '.total_entries // "unknown"' "$index_file" 2>/dev/null || echo "unknown")
  fi

  # Escape strings for JSON
  message=$(echo "$message" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
  context=$(echo "$context" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')
  stack=$(echo "$stack" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n' ' ')

  local error_json
  error_json=$(cat <<EJSON
{"error_id":"${error_id}","timestamp":"${timestamp}","scribe_version":"${scribe_version}","component":"${component}","error_type":"${error_type}","message":"${message}","context":"${context}","stack":"${stack}","platform":"${platform}","system":{"os":"${os_info}","os_version":"${os_version}","bash":"${bash_version_str}","jq":"${jq_version}","config_exists":${config_exists},"total_entries":${entry_count}},"submitted":false}
EJSON
)

  # Ensure the errors log directory exists
  mkdir -p "$(dirname "$ERRORS_LOG")"

  # Append to errors log
  echo "$error_json" >> "$ERRORS_LOG" 2>/dev/null

  # Also write to stderr so the user sees it
  echo "SCRIBE ERROR [$component/$error_type]: $message" >&2
}
