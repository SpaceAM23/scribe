#!/usr/bin/env bash
# ============================================================================
# Scribe — Install Script
# Silent AI Session Journal by Rocksteady Consulting
#
# Usage: cd ~/.claude/scribe && ./scripts/install.sh
#        (or run from wherever you cloned the repo)
#
# Requirements: bash 3.2+, jq, uuidgen
# Idempotent: safe to re-run at any time
# ============================================================================

set -euo pipefail

# Non-interactive guard: with `set -e`, a `read` that hits EOF (curl | bash, CI,
# a wrapper script) kills the installer at the first prompt with no message.
if [[ ! -t 0 ]]; then
  echo "Scribe installer needs an interactive terminal (it asks where your data" >&2
  echo "directory should live). Run it directly:  bash scripts/install.sh" >&2
  echo "Piping from curl or running headless is not supported yet." >&2
  exit 1
fi


# ---------------------------------------------------------------------------
# Color support (with fallback for terminals that don't support it)
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput &>/dev/null && [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
    BOLD=$(tput bold)
    DIM=$(tput dim)
    RESET=$(tput sgr0)
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    WHITE=$(tput setaf 7)
else
    BOLD=""
    DIM=""
    RESET=""
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    WHITE=""
fi

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { printf "  %s%s%s\n" "${CYAN}" "$1" "${RESET}"; }
success() { printf "  %s[OK]%s %s\n" "${GREEN}" "${RESET}" "$1"; }
warn()    { printf "  %s[!!]%s %s\n" "${YELLOW}" "${RESET}" "$1"; }
error()   { printf "  %s[ERROR]%s %s\n" "${RED}" "${RESET}" "$1"; }
header()  { printf "\n%s%s=== %s ===%s\n\n" "${BOLD}" "${BLUE}" "$1" "${RESET}"; }
dim()     { printf "  %s%s%s\n" "${DIM}" "$1" "${RESET}"; }

# Prompt with default value. Usage: ask "Question" "default"
# Result is in $REPLY
ask() {
    local prompt="$1"
    local default="${2:-}"
    if [[ -n "$default" ]]; then
        printf "  %s [%s]: " "$prompt" "$default"
    else
        printf "  %s: " "$prompt"
    fi
    read -r REPLY
    REPLY="${REPLY:-$default}"
}

# Yes/no prompt. Usage: ask_yn "Question" "y" (default yes) or "n"
# Returns 0 for yes, 1 for no
ask_yn() {
    local prompt="$1"
    local default="${2:-y}"
    local hint
    if [[ "$default" == "y" ]]; then
        hint="Y/n"
    else
        hint="y/N"
    fi
    printf "  %s [%s]: " "$prompt" "$hint"
    read -r REPLY
    REPLY="${REPLY:-$default}"
    case "$REPLY" in
        [Yy]|[Yy][Ee][Ss]) return 0 ;;
        *) return 1 ;;
    esac
}

# Resolve ~ in paths (bash 3.2 compatible)
expand_path() {
    local p="$1"
    if [[ "$p" == "~/"* ]]; then
        p="${HOME}/${p#\~/}"
    elif [[ "$p" == "~" ]]; then
        p="${HOME}"
    fi
    # Force absolute. A relative data_path written into pointer.json resolves
    # against each process's cwd, so the journal splinters into one copy per
    # directory the writer happens to run from.
    if [[ "$p" != /* ]]; then
        p="$(pwd)/$p"
    fi
    echo "$p"
}

# Determine where install.sh lives (the repo root)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SCRIBE_VERSION=$(cat "${REPO_ROOT}/VERSION" 2>/dev/null || echo "0.1.0")

# ============================================================================
# STEP 1: Welcome Banner
# ============================================================================
printf "\n"
printf "  %s%s" "${BOLD}" "${CYAN}"
printf "  ╔══════════════════════════════════════╗\n"
printf "  ║          SCRIBE - Setup              ║\n"
printf "  ║   Silent AI Session Journal          ║\n"
printf "  ║   by Rocksteady Consulting           ║\n"
printf "  ╚══════════════════════════════════════╝\n"
printf "  %s\n" "${RESET}"
printf "  Version %s\n" "${SCRIBE_VERSION}"
printf "  Repo: %s\n\n" "${REPO_ROOT}"

# ============================================================================
# STEP 2: Check Prerequisites
# ============================================================================
header "Step 1/14  Prerequisites"

PREREQ_FAIL=0

# Check jq
if command -v jq &>/dev/null; then
    success "jq found ($(jq --version 2>&1 || echo 'unknown version'))"
else
    error "jq is not installed (required)"
    info "Install with:  brew install jq  (macOS)"
    info "               sudo apt-get install jq  (Debian/Ubuntu)"
    PREREQ_FAIL=1
fi

# Check uuidgen
if command -v uuidgen &>/dev/null; then
    success "uuidgen found"
else
    error "uuidgen is not available (required)"
    info "On macOS this should be built-in. On Linux, install uuid-runtime."
    PREREQ_FAIL=1
fi

# Check bash version
BASH_MAJOR="${BASH_VERSINFO[0]:-0}"
BASH_MINOR="${BASH_VERSINFO[1]:-0}"
if [[ "$BASH_MAJOR" -gt 3 ]] || { [[ "$BASH_MAJOR" -eq 3 ]] && [[ "$BASH_MINOR" -ge 2 ]]; }; then
    success "bash ${BASH_VERSION} (3.2+ required)"
else
    warn "bash ${BASH_VERSION} detected. Scribe requires 3.2+. Some features may not work."
fi

if [[ "$PREREQ_FAIL" -eq 1 ]]; then
    printf "\n"
    error "Missing required tools. Install them and re-run this script."
    exit 1
fi

# ============================================================================
# STEP 3: Choose Data Directory
# ============================================================================
header "Step 2/14  Data Directory"

info "Scribe stores your journal entries, config, and index in a"
info "dedicated data directory. This is YOUR data -- updates to"
info "the Scribe skill never touch it."
printf "\n"

DEFAULT_DATA_DIR="${HOME}/Desktop/Scribe"
ask "Data directory path" "~/Desktop/Scribe"
DATA_DIR_RAW="${REPLY}"
DATA_DIR="$(expand_path "${DATA_DIR_RAW}")"

# Create directory structure
mkdir -p "${DATA_DIR}/entries"
mkdir -p "${DATA_DIR}/inbox"
mkdir -p "${DATA_DIR}/outbox"
mkdir -p "${DATA_DIR}/revisions"
mkdir -p "${DATA_DIR}/briefs"
mkdir -p "${DATA_DIR}/canonical"

success "Data directory: ${DATA_DIR}"

# Create subdirectories
for subdir in entries inbox outbox revisions briefs canonical; do
    if [[ -d "${DATA_DIR}/${subdir}" ]]; then
        dim "  ${subdir}/ exists"
    else
        dim "  ${subdir}/ created"
    fi
done

# Seed the canonical taxonomy files (never overwrite an existing copy)
if [[ -f "${DATA_DIR}/canonical/correction-patterns.json" ]]; then
    dim "  canonical/correction-patterns.json exists (preserved)"
elif [[ -f "${REPO_ROOT}/templates/correction-patterns.template.json" ]]; then
    cp "${REPO_ROOT}/templates/correction-patterns.template.json" "${DATA_DIR}/canonical/correction-patterns.json"
    success "canonical/correction-patterns.json seeded (correction vocabulary)"
fi
if [[ -f "${DATA_DIR}/canonical/projects.json" ]]; then
    dim "  canonical/projects.json exists (preserved)"
elif [[ -f "${REPO_ROOT}/templates/projects.template.json" ]]; then
    # Ships EMPTY = open mode (any project name accepted). Mint projects later:
    #   python3 core/taxonomy.py add-project <name>
    jq 'del(._comment, ._example)' "${REPO_ROOT}/templates/projects.template.json" \
        > "${DATA_DIR}/canonical/projects.json"
    success "canonical/projects.json seeded (open mode — mint projects with core/taxonomy.py)"
fi

# Write pointer.json in the repo root
POINTER_FILE="${REPO_ROOT}/pointer.json"
cat > "${POINTER_FILE}" <<PJSON
{
  "data_path": "${DATA_DIR_RAW}",
  "created": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
PJSON
success "pointer.json written to ${POINTER_FILE}"

# ============================================================================
# STEP 4: Generate User ID
# ============================================================================
header "Step 3/14  User Identity"

# Check if config already exists with a user_id
EXISTING_CONFIG="${DATA_DIR}/config.json"
if [[ -f "${EXISTING_CONFIG}" ]]; then
    EXISTING_USER_ID=$(jq -r '.user_id // empty' "${EXISTING_CONFIG}" 2>/dev/null || true)
    if [[ -n "${EXISTING_USER_ID}" ]]; then
        info "Existing user ID found: ${EXISTING_USER_ID}"
        if ask_yn "Keep existing user ID?" "y"; then
            USER_ID="${EXISTING_USER_ID}"
        else
            USER_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
        fi
    else
        USER_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
    fi
else
    USER_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
fi

success "User ID: ${USER_ID}"

# ============================================================================
# STEP 5: User Profile
# ============================================================================
header "Step 4/14  User Profile"

info "Tell Scribe a bit about yourself. This helps it understand"
info "the context of your work and tailor observations."
printf "\n"

ask "Your name (required)" ""
while [[ -z "${REPLY}" ]]; do
    warn "Name is required."
    ask "Your name" ""
done
USER_NAME="${REPLY}"

ask "Your role (optional, e.g. Developer, Designer, Manager)" ""
USER_ROLE="${REPLY}"

ask "Primary expertise areas (optional, comma-separated)" ""
USER_EXPERTISE_RAW="${REPLY}"

# Convert comma-separated string to JSON array
if [[ -n "${USER_EXPERTISE_RAW}" ]]; then
    # Split on commas, trim whitespace, build JSON array
    USER_EXPERTISE_JSON="["
    FIRST=1
    OLD_IFS="$IFS"
    IFS=","
    for item in ${USER_EXPERTISE_RAW}; do
        # Trim leading/trailing whitespace (bash 3.2 compatible)
        item=$(echo "$item" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        if [[ -n "$item" ]]; then
            if [[ "$FIRST" -eq 1 ]]; then
                FIRST=0
            else
                USER_EXPERTISE_JSON="${USER_EXPERTISE_JSON}, "
            fi
            USER_EXPERTISE_JSON="${USER_EXPERTISE_JSON}\"${item}\""
        fi
    done
    IFS="$OLD_IFS"
    USER_EXPERTISE_JSON="${USER_EXPERTISE_JSON}]"
else
    USER_EXPERTISE_JSON="[]"
fi

success "Profile: ${USER_NAME}"
[[ -n "${USER_ROLE}" ]] && dim "  Role: ${USER_ROLE}"
[[ "${USER_EXPERTISE_JSON}" != "[]" ]] && dim "  Expertise: ${USER_EXPERTISE_JSON}"

# ============================================================================
# STEP 6: Storage Configuration
# ============================================================================
header "Step 5/14  Storage Targets"

info "Scribe can write entries to multiple storage targets."
info "Local files are the primary source of truth."
printf "\n"

# Local is always on
STORAGE_LOCAL=true
success "Local files: enabled (primary, always on)"
printf "\n"

# Google Drive
info "Google Drive: stores entries in a Drive folder via Claude's"
info "Drive MCP connection. Useful for cross-device access or as"
info "backup. Requires the Google Drive MCP server in Claude."
if ask_yn "Enable Google Drive storage?" "n"; then
    STORAGE_GDRIVE=true
    ask "Google Drive folder ID (or leave blank to configure later)" ""
    GDRIVE_FOLDER_ID="${REPLY}"
    success "Google Drive: enabled"
else
    STORAGE_GDRIVE=false
    GDRIVE_FOLDER_ID=""
    dim "  Google Drive: skipped"
fi
printf "\n"

# Supabase
info "Supabase: stores entries in a PostgreSQL database. Enables"
info "querying, dashboards, and team features. You can use an"
info "existing project or create a new one at supabase.com."
if ask_yn "Enable Supabase storage?" "n"; then
    STORAGE_SUPABASE=true
    printf "\n"
    ask "Supabase project URL (e.g. https://xyz.supabase.co)" ""
    SUPABASE_URL="${REPLY}"
    ask "Supabase anon key" ""
    SUPABASE_ANON_KEY="${REPLY}"
    printf "\n"
    info "You will need a journal_entries table. Create it with:"
    dim "  CREATE TABLE journal_entries ("
    dim "    id UUID PRIMARY KEY,"
    dim "    timestamp TIMESTAMPTZ NOT NULL,"
    dim "    session_id TEXT,"
    dim "    user_id TEXT NOT NULL,"
    dim "    project TEXT,"
    dim "    type TEXT NOT NULL,"
    dim "    title TEXT NOT NULL,"
    dim "    summary TEXT,"
    dim "    decisions JSONB DEFAULT '[]',"
    dim "    learnings JSONB DEFAULT '[]',"
    dim "    corrections JSONB DEFAULT '[]',"
    dim "    metrics JSONB DEFAULT '{}',"
    dim "    connections JSONB DEFAULT '{}',"
    dim "    growth JSONB DEFAULT '{}',"
    dim "    behavioral JSONB DEFAULT '{}',"
    dim "    created_at TIMESTAMPTZ DEFAULT now()"
    dim "  );"
    printf "\n"
    info "(Full schema with RLS: adapters/claude-web/supabase-setup.sql)"
    printf "\n"
    info "For direct database writes, put your DB password in ${DATA_DIR}/.env:"
    dim "  SCRIBE_DB_PASSWORD=...   (see templates/.env.example)"
    printf "\n"
    success "Supabase: enabled"
else
    STORAGE_SUPABASE=false
    SUPABASE_URL=""
    SUPABASE_ANON_KEY=""
    dim "  Supabase: skipped"
fi

# ============================================================================
# STEP 7: Behavioral Tracking
# ============================================================================
header "Step 6/14  Behavioral Tracking"

info "Behavioral tracking observes cognitive, motivational, and"
info "work patterns during your sessions -- things like energy"
info "levels, decision-making styles, avoidance signals, and flow"
info "states. This data stays private and is never shared in"
info "Scribe-to-Scribe packets."
printf "\n"
info "You can enable or disable this anytime with /scribe-config."
printf "\n"

if ask_yn "Enable behavioral pattern tracking?" "n"; then
    BEHAVIORAL_TRACKING=true
    success "Behavioral tracking: enabled"
else
    BEHAVIORAL_TRACKING=false
    dim "  Behavioral tracking: off (can enable later)"
fi

# ============================================================================
# STEP 8: Encryption
# ============================================================================
header "Step 7/14  Encryption"

info "Scribe can encrypt the content of your entries (summaries,"
info "decisions, learnings, corrections) while keeping metadata"
info "(timestamps, types, project names) readable. This preserves"
info "status line counters and search by type/project."
printf "\n"
info "Encryption uses AES-256-GCM with PBKDF2 key derivation."
info "Note: full encryption is Phase 2 -- this configures the flag."
printf "\n"

ENCRYPTION_ENABLED=false
RECOVERY_KEY=""

if ask_yn "Enable field-level encryption?" "n"; then
    ENCRYPTION_ENABLED=true
    # Generate a 32-character hex recovery key
    if command -v openssl &>/dev/null; then
        RECOVERY_KEY=$(openssl rand -hex 16)
    else
        # Fallback: use /dev/urandom
        RECOVERY_KEY=$(cat /dev/urandom | LC_ALL=C tr -dc 'a-f0-9' | head -c 32)
    fi

    printf "\n"
    printf "  %s%s" "${BOLD}" "${RED}"
    printf "  ╔══════════════════════════════════════════════╗\n"
    printf "  ║         SAVE YOUR RECOVERY KEY              ║\n"
    printf "  ╠══════════════════════════════════════════════╣\n"
    printf "  ║                                              ║\n"
    printf "  ║  %s  ║\n" "${RECOVERY_KEY}              "
    printf "  ║                                              ║\n"
    printf "  ║  Store this somewhere safe. You will need    ║\n"
    printf "  ║  it to recover encrypted entries if your     ║\n"
    printf "  ║  config is lost.                             ║\n"
    printf "  ╚══════════════════════════════════════════════╝\n"
    printf "  %s\n" "${RESET}"

    printf "  Press Enter after you have saved the key..."
    read -r
    success "Encryption: enabled"
else
    dim "  Encryption: off"
fi

# ============================================================================
# STEP 9: Status Line
# ============================================================================
header "Step 8/14  Status Line"

info "Scribe can display session metrics in your Claude Code"
info "status line:"
printf "\n"
dim "  SCRIBE: 3 SESSION / 171 TOTAL | LRN 1 | COR 0 | DEC 2 | FEAT 0 | BUG 0"
printf "\n"

if ask_yn "Enable Scribe status line metrics?" "y"; then
    STATUS_LINE=true
    success "Status line: enabled"
    printf "\n"
    info "To integrate, add this line to your statusline-command.sh:"
    dim "  ~/.claude/scribe/adapters/claude-code/statusline.sh"
else
    STATUS_LINE=false
    dim "  Status line: off"
fi

# ============================================================================
# STEP 10: Skill Scan
# ============================================================================
header "Step 9/14  Skill Scan"

info "Scribe is a meta-skill -- it can observe how you use your"
info "other Claude skills and correlate usage with outcomes."
printf "\n"

SKILL_INTEGRATIONS="{}"
SKILLS_TRACKED=0

# Scan ~/.claude/skills/
SKILLS_DIR="${HOME}/.claude/skills"
COMMANDS_DIR="${HOME}/.claude/commands"

declare -a SKILL_NAMES
declare -a SKILL_PATHS
declare -a SKILL_PURPOSES
SKILL_INDEX=0

if [[ -d "${SKILLS_DIR}" ]]; then
    for skill_path in "${SKILLS_DIR}"/*/; do
        if [[ -d "$skill_path" ]]; then
            skill_name=$(basename "$skill_path")
            # Skip scribe itself
            if [[ "$skill_name" == "scribe" ]]; then
                continue
            fi
            info "Found skill: ${skill_name}"
            dim "  Path: ${skill_path}"
            if ask_yn "Track usage of ${skill_name}?" "y"; then
                ask "One-line description of what ${skill_name} does" ""
                SKILL_NAMES[$SKILL_INDEX]="$skill_name"
                SKILL_PATHS[$SKILL_INDEX]="$skill_path"
                SKILL_PURPOSES[$SKILL_INDEX]="$REPLY"
                SKILL_INDEX=$((SKILL_INDEX + 1))
                SKILLS_TRACKED=$((SKILLS_TRACKED + 1))
            fi
            printf "\n"
        fi
    done
fi

if [[ -d "${COMMANDS_DIR}" ]]; then
    for cmd_path in "${COMMANDS_DIR}"/*/; do
        if [[ -d "$cmd_path" ]]; then
            cmd_name=$(basename "$cmd_path")
            info "Found command: ${cmd_name}"
            dim "  Path: ${cmd_path}"
            if ask_yn "Track usage of ${cmd_name}?" "y"; then
                ask "One-line description of what ${cmd_name} does" ""
                SKILL_NAMES[$SKILL_INDEX]="$cmd_name"
                SKILL_PATHS[$SKILL_INDEX]="$cmd_path"
                SKILL_PURPOSES[$SKILL_INDEX]="$REPLY"
                SKILL_INDEX=$((SKILL_INDEX + 1))
                SKILLS_TRACKED=$((SKILLS_TRACKED + 1))
            fi
            printf "\n"
        fi
    done
fi

# Also check for single-file commands
if [[ -d "${COMMANDS_DIR}" ]]; then
    for cmd_file in "${COMMANDS_DIR}"/*.md; do
        if [[ -f "$cmd_file" ]]; then
            cmd_name=$(basename "$cmd_file" .md)
            info "Found command file: ${cmd_name}"
            dim "  Path: ${cmd_file}"
            if ask_yn "Track usage of ${cmd_name}?" "y"; then
                ask "One-line description of what ${cmd_name} does" ""
                SKILL_NAMES[$SKILL_INDEX]="$cmd_name"
                SKILL_PATHS[$SKILL_INDEX]="$cmd_file"
                SKILL_PURPOSES[$SKILL_INDEX]="$REPLY"
                SKILL_INDEX=$((SKILL_INDEX + 1))
                SKILLS_TRACKED=$((SKILLS_TRACKED + 1))
            fi
            printf "\n"
        fi
    done
fi

if [[ "$SKILLS_TRACKED" -eq 0 ]]; then
    dim "  No skills found or none selected for tracking."
fi

# Build skill_integrations JSON
SKILL_INTEGRATIONS="{"
FIRST_SKILL=1
for ((i=0; i<SKILL_INDEX; i++)); do
    if [[ "$FIRST_SKILL" -eq 1 ]]; then
        FIRST_SKILL=0
    else
        SKILL_INTEGRATIONS="${SKILL_INTEGRATIONS},"
    fi
    # Escape any double quotes in the purpose string
    escaped_purpose=$(echo "${SKILL_PURPOSES[$i]}" | sed 's/"/\\"/g')
    escaped_path=$(echo "${SKILL_PATHS[$i]}" | sed 's/"/\\"/g')
    SKILL_INTEGRATIONS="${SKILL_INTEGRATIONS}
    \"${SKILL_NAMES[$i]}\": {
      \"path\": \"${escaped_path}\",
      \"purpose\": \"${escaped_purpose}\",
      \"observation_link\": \"\"
    }"
done
SKILL_INTEGRATIONS="${SKILL_INTEGRATIONS}
  }"

success "${SKILLS_TRACKED} skill(s) configured for tracking"

# ============================================================================
# STEP 11: Install Skill Files (Symlink)
# ============================================================================
header "Step 10/14  Skill Installation"

CLAUDE_SCRIBE_DIR="${HOME}/.claude/scribe"

if [[ "${REPO_ROOT}" == "${CLAUDE_SCRIBE_DIR}" ]]; then
    success "Repo is already at ~/.claude/scribe/ -- no symlink needed"
else
    info "The Scribe skill expects to live at ~/.claude/scribe/"
    info "Your repo is at: ${REPO_ROOT}"
    printf "\n"

    if [[ -L "${CLAUDE_SCRIBE_DIR}" ]]; then
        EXISTING_TARGET=$(readlink "${CLAUDE_SCRIBE_DIR}")
        if [[ "${EXISTING_TARGET}" == "${REPO_ROOT}" ]]; then
            success "Symlink already exists and points to this repo"
        else
            warn "Symlink exists but points to: ${EXISTING_TARGET}"
            if ask_yn "Update symlink to point to this repo?" "y"; then
                rm "${CLAUDE_SCRIBE_DIR}"
                ln -s "${REPO_ROOT}" "${CLAUDE_SCRIBE_DIR}"
                success "Symlink updated: ~/.claude/scribe -> ${REPO_ROOT}"
            else
                warn "Keeping existing symlink. Scribe may not work correctly."
            fi
        fi
    elif [[ -d "${CLAUDE_SCRIBE_DIR}" ]]; then
        warn "~/.claude/scribe/ exists as a directory (not a symlink)"
        info "This may be a previous installation."
        if ask_yn "Replace with symlink to this repo?" "n"; then
            BACKUP_DIR="${HOME}/.claude/scribe.backup.$(date +%s)"
            mv "${CLAUDE_SCRIBE_DIR}" "${BACKUP_DIR}"
            ln -s "${REPO_ROOT}" "${CLAUDE_SCRIBE_DIR}"
            success "Backed up old dir to ${BACKUP_DIR}"
            success "Symlink created: ~/.claude/scribe -> ${REPO_ROOT}"
        else
            warn "Keeping existing directory. You may need to update paths manually."
        fi
    else
        # Ensure parent directory exists
        mkdir -p "${HOME}/.claude"
        ln -s "${REPO_ROOT}" "${CLAUDE_SCRIBE_DIR}"
        success "Symlink created: ~/.claude/scribe -> ${REPO_ROOT}"
    fi
fi

# ============================================================================
# STEP 11b: Install the slash commands
# ----------------------------------------------------------------------------
# Without this the installer finishes by telling the user to type /scribe-help,
# which does not exist — the single most likely reason an install is judged
# broken. The command files ship in adapters/claude-code/commands/ and were
# never copied anywhere Claude Code looks.
# ============================================================================
CMD_SRC="${REPO_ROOT}/adapters/claude-code/commands"
CMD_DEST="${HOME}/.claude/commands"
if [[ -d "${CMD_SRC}" ]]; then
    mkdir -p "${CMD_DEST}"
    CMD_COUNT=0
    for cmd_file in "${CMD_SRC}"/*.md; do
        [[ -e "${cmd_file}" ]] || continue
        cp "${cmd_file}" "${CMD_DEST}/"
        CMD_COUNT=$((CMD_COUNT + 1))
    done
    if [[ ${CMD_COUNT} -gt 0 ]]; then
        success "${CMD_COUNT} slash command(s) installed to ~/.claude/commands/"
    else
        warn "No command files found in ${CMD_SRC}"
    fi
else
    warn "Command source missing: ${CMD_SRC} — /scribe-* commands will not be available"
fi

# ============================================================================
# STEP 12: Configure CLAUDE.md
# ============================================================================
header "Step 11/14  CLAUDE.md Integration"

CLAUDE_MD="${HOME}/.claude/CLAUDE.md"
TEMPLATE_FILE="${REPO_ROOT}/adapters/claude-code/claude-md-template.md"
SCRIBE_MARKER="Scribe — Session Journal (Active)"

CLAUDE_MD_ACTION="skipped"

if [[ -f "${TEMPLATE_FILE}" ]]; then
    if [[ -f "${CLAUDE_MD}" ]]; then
        # Check if Scribe directives are already present
        if grep -q "${SCRIBE_MARKER}" "${CLAUDE_MD}" 2>/dev/null; then
            success "Scribe directives already present in CLAUDE.md"
            CLAUDE_MD_ACTION="already-present"
        else
            info "Your ~/.claude/CLAUDE.md exists but does not contain"
            info "Scribe directives."
            printf "\n"
            if ask_yn "Append Scribe directives to your CLAUDE.md?" "y"; then
                printf "\n" >> "${CLAUDE_MD}"
                # Read template, skip the first 5 lines (the header/instructions)
                # which tell the user what to do -- just append the actual directives
                TEMPLATE_CONTENT=$(sed -n '5,$p' "${TEMPLATE_FILE}")
                printf "%s\n" "${TEMPLATE_CONTENT}" >> "${CLAUDE_MD}"
                success "Scribe directives appended to ~/.claude/CLAUDE.md"
                CLAUDE_MD_ACTION="appended"
            else
                dim "  Skipped. You can add them later by copying from:"
                dim "  ${TEMPLATE_FILE}"
                CLAUDE_MD_ACTION="skipped"
            fi
        fi
    else
        info "No ~/.claude/CLAUDE.md found."
        if ask_yn "Create one with Scribe directives?" "y"; then
            mkdir -p "${HOME}/.claude"
            # Use the template content starting from the directives
            TEMPLATE_CONTENT=$(sed -n '5,$p' "${TEMPLATE_FILE}")
            printf "# CLAUDE.md\n\n%s\n" "${TEMPLATE_CONTENT}" > "${CLAUDE_MD}"
            success "Created ~/.claude/CLAUDE.md with Scribe directives"
            CLAUDE_MD_ACTION="created"
        else
            dim "  Skipped."
            CLAUDE_MD_ACTION="skipped"
        fi
    fi
else
    warn "CLAUDE.md template not found at ${TEMPLATE_FILE}"
    warn "Skipping CLAUDE.md integration."
fi

# ============================================================================
# STEP 13: Write Config and Initialize Files
# ============================================================================
header "Step 12/14  Writing Configuration"

# Build the GDRIVE folder_id value for JSON
if [[ -n "${GDRIVE_FOLDER_ID}" ]]; then
    GDRIVE_FOLDER_JSON="\"${GDRIVE_FOLDER_ID}\""
else
    GDRIVE_FOLDER_JSON="null"
fi

# Build Supabase values for JSON
if [[ -n "${SUPABASE_URL}" ]]; then
    SUPABASE_URL_JSON="\"${SUPABASE_URL}\""
else
    SUPABASE_URL_JSON="null"
fi
if [[ -n "${SUPABASE_ANON_KEY}" ]]; then
    SUPABASE_ANON_JSON="\"${SUPABASE_ANON_KEY}\""
else
    SUPABASE_ANON_JSON="null"
fi

# Escape user name and role for JSON
USER_NAME_ESC=$(echo "${USER_NAME}" | sed 's/"/\\"/g')
USER_ROLE_ESC=$(echo "${USER_ROLE}" | sed 's/"/\\"/g')

# Write config.json
cat > "${DATA_DIR}/config.json" <<CEOF
{
  "scribe_version": "${SCRIBE_VERSION}",
  "schema_version": 1,
  "user_id": "${USER_ID}",
  "user_profile": {
    "name": "${USER_NAME_ESC}",
    "role": "${USER_ROLE_ESC}",
    "expertise": ${USER_EXPERTISE_JSON},
    "working_style": "",
    "communication_preferences": {
      "detail_level": "",
      "decision_style": "",
      "feedback_style": "",
      "preferred_format": ""
    }
  },
  "data_path": "${DATA_DIR_RAW}",
  "projects": {},
  "storage": {
    "local": {
      "enabled": true
    },
    "google_drive": {
      "enabled": ${STORAGE_GDRIVE},
      "folder_id": ${GDRIVE_FOLDER_JSON}
    },
    "supabase": {
      "enabled": ${STORAGE_SUPABASE},
      "url": ${SUPABASE_URL_JSON},
      "anon_key": ${SUPABASE_ANON_JSON},
      "db_connection": null
    }
  },
  "behavioral_tracking": ${BEHAVIORAL_TRACKING},
  "encryption": {
    "enabled": ${ENCRYPTION_ENABLED},
    "algorithm": "AES-256-GCM",
    "key_derivation": "PBKDF2"
  },
  "status_line": {
    "enabled": ${STATUS_LINE},
    "metrics": ["session_count", "total_count", "lrn", "cor", "dec", "feat", "bug"]
  },
  "transparency": "detailed",
  "scribe_to_scribe": {
    "enabled": true,
    "auto_accept": false,
    "share_defaults": {
      "include_role": true,
      "include_working_style": true,
      "include_expertise": true,
      "include_communication_prefs": true
    }
  },
  "skill_integrations": ${SKILL_INTEGRATIONS}
}
CEOF
success "config.json written"

# Initialize session-counter.json (only if it doesn't exist)
SESSION_COUNTER="${DATA_DIR}/session-counter.json"
if [[ ! -f "${SESSION_COUNTER}" ]]; then
    cat > "${SESSION_COUNTER}" <<SCEOF
{
  "total_sessions": 0,
  "current_session_id": null
}
SCEOF
    success "session-counter.json initialized"
else
    dim "  session-counter.json already exists (preserved)"
fi

# Initialize index.json (only if it doesn't exist)
INDEX_FILE="${DATA_DIR}/index.json"
if [[ ! -f "${INDEX_FILE}" ]]; then
    cat > "${INDEX_FILE}" <<IEOF
{
  "total_entries": 0,
  "entries_by_type": {},
  "entries_by_project": {},
  "tag_cloud": {},
  "growth_summary": {
    "total_features": 0,
    "total_bugs_fixed": 0,
    "total_learnings": 0,
    "total_corrections": 0,
    "skill_distribution": {}
  },
  "last_updated": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
IEOF
    success "index.json initialized"
else
    dim "  index.json already exists (preserved)"
fi

# Initialize correction-tracker.json (only if it doesn't exist)
CORRECTION_TRACKER="${DATA_DIR}/correction-tracker.json"
if [[ ! -f "${CORRECTION_TRACKER}" ]]; then
    cat > "${CORRECTION_TRACKER}" <<CTEOF
{
  "schema_version": 1,
  "patterns": {},
  "last_updated": ""
}
CTEOF
    success "correction-tracker.json initialized"
else
    dim "  correction-tracker.json already exists (preserved)"
fi

# ============================================================================
# STEP 14: Intake Scan Offer
# ============================================================================
header "Step 13/14  Intake Scan"

info "Scribe can import your existing chat history and Claude"
info "project data to build an initial profile. This scans for"
info "your role, expertise, projects, patterns, and preferences."
printf "\n"
info "This is optional -- you can run it later with /scribe-import."
printf "\n"

INTAKE_ACTION="skipped"
if ask_yn "Would you like to set up an intake scan?" "n"; then
    IMPORT_DIR="${DATA_DIR}/import"
    mkdir -p "${IMPORT_DIR}"
    printf "\n"
    info "To run the intake scan:"
    printf "\n"
    dim "  1. Export your chat history from ChatGPT, Gemini, or other tools"
    dim "  2. Place the export files in:"
    dim "     ${IMPORT_DIR}/"
    dim "  3. Start a Claude Code session and run:"
    dim "     /scribe-import"
    printf "\n"
    info "Scribe will analyze the exports and present findings for your"
    info "review before saving anything. Nothing is assumed or fabricated."
    success "Import directory created at ${IMPORT_DIR}/"
    INTAKE_ACTION="ready"
else
    dim "  Skipped. Run /scribe-import anytime."
fi

# ============================================================================
# STEP 15: Summary
# ============================================================================
header "Step 14/14  Setup Complete"

printf "  %s%s" "${BOLD}" "${GREEN}"
printf "  ╔══════════════════════════════════════╗\n"
printf "  ║       Scribe is ready.               ║\n"
printf "  ╚══════════════════════════════════════╝\n"
printf "  %s\n" "${RESET}"

printf "  %s%sConfiguration Summary%s\n\n" "${BOLD}" "${WHITE}" "${RESET}"

info "Data directory:      ${DATA_DIR}"
printf "\n"

# Storage
printf "  %sStorage targets:%s\n" "${BOLD}" "${RESET}"
printf "    Local files:       %senabled (primary)%s\n" "${GREEN}" "${RESET}"
if [[ "${STORAGE_GDRIVE}" == "true" ]]; then
    printf "    Google Drive:      %senabled%s\n" "${GREEN}" "${RESET}"
else
    printf "    Google Drive:      %soff%s\n" "${DIM}" "${RESET}"
fi
if [[ "${STORAGE_SUPABASE}" == "true" ]]; then
    printf "    Supabase:          %senabled%s\n" "${GREEN}" "${RESET}"
else
    printf "    Supabase:          %soff%s\n" "${DIM}" "${RESET}"
fi
printf "\n"

# Toggles
printf "  %sFeatures:%s\n" "${BOLD}" "${RESET}"
if [[ "${BEHAVIORAL_TRACKING}" == "true" ]]; then
    printf "    Behavioral tracking: %son%s\n" "${GREEN}" "${RESET}"
else
    printf "    Behavioral tracking: %soff%s\n" "${DIM}" "${RESET}"
fi
if [[ "${ENCRYPTION_ENABLED}" == "true" ]]; then
    printf "    Encryption:          %son%s\n" "${GREEN}" "${RESET}"
else
    printf "    Encryption:          %soff%s\n" "${DIM}" "${RESET}"
fi
if [[ "${STATUS_LINE}" == "true" ]]; then
    printf "    Status line:         %son%s\n" "${GREEN}" "${RESET}"
else
    printf "    Status line:         %soff%s\n" "${DIM}" "${RESET}"
fi
printf "\n"

# Skills
printf "  %sSkills tracked:%s\n" "${BOLD}" "${RESET}"
if [[ "$SKILL_INDEX" -gt 0 ]]; then
    for ((i=0; i<SKILL_INDEX; i++)); do
        printf "    - %s\n" "${SKILL_NAMES[$i]}"
    done
else
    printf "    (none)\n"
fi
printf "\n"

# CLAUDE.md
printf "  %sCLAUDE.md:%s %s\n" "${BOLD}" "${RESET}" "${CLAUDE_MD_ACTION}"
printf "\n"

# Next steps
printf "  %s%sNext Steps%s\n\n" "${BOLD}" "${WHITE}" "${RESET}"
info "1. Start a new Claude Code session -- Scribe will activate"
info "   automatically via the CLAUDE.md directives."
printf "\n"
info "2. Type /scribe-help for available commands."
printf "\n"
info "3. Ask \"How am I doing?\" anytime for a reflection."
printf "\n"

if [[ "${INTAKE_ACTION}" == "ready" ]]; then
    info "4. Drop your chat exports into ${DATA_DIR}/import/"
    info "   and run: /scribe-import"
    printf "\n"
fi

dim "  Documentation: ${REPO_ROOT}/README.md"
dim "  Design doc:    ${REPO_ROOT}/DESIGN.md"
printf "\n"
