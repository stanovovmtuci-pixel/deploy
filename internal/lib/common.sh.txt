#!/usr/bin/env bash
# common.sh - shared functions for deploy.sh and all phases
# This file is sourced, not executed directly

# ============================================================
# Color output
# ============================================================
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
    C_RESET=$'\033[0m'
else
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
    C_BOLD=''
    C_RESET=''
fi

# ============================================================
# Logging
# ============================================================
log()   { echo "${C_BLUE}[$(date +%H:%M:%S)]${C_RESET} $*"; }
ok()    { echo "  ${C_GREEN}OK${C_RESET}: $*"; }
warn()  { echo "  ${C_YELLOW}WARN${C_RESET}: $*" >&2; }
fail()  { echo "  ${C_RED}FAIL${C_RESET}: $*" >&2; exit 1; }
step()  { echo "${C_CYAN}${C_BOLD}---${C_RESET} ${C_BOLD}$*${C_RESET} ${C_CYAN}---${C_RESET}"; }

# Persistent log file (set by deploy.sh)
DEPLOY_LOG="${DEPLOY_LOG:-/var/log/deploy-internal.log}"

log_file() {
    local msg="[$(date +'%Y-%m-%d %H:%M:%S')] $*"
    echo "$msg" >> "$DEPLOY_LOG" 2>/dev/null || true
}

# ============================================================
# Interactive input
# ============================================================

# ask "Question" -> echoes user input (no validation)
ask() {
    local prompt="$1"
    local answer
    read -r -p "${C_BOLD}>${C_RESET} ${prompt}: " answer
    echo "$answer"
}

# ask_default "Question" "default-value" -> echoes user input or default
ask_default() {
    local prompt="$1"
    local default="$2"
    local answer
    read -r -p "${C_BOLD}>${C_RESET} ${prompt} [${C_CYAN}${default}${C_RESET}]: " answer
    echo "${answer:-$default}"
}

# ask_yn "Question" "y|n" -> returns 0 (yes) or 1 (no)
ask_yn() {
    local prompt="$1"
    local default="${2:-n}"
    local hint
    case "$default" in
        y|Y|yes) hint="Y/n" ;;
        *)       hint="y/N" ;;
    esac
    local answer
    read -r -p "${C_BOLD}>${C_RESET} ${prompt} [${C_CYAN}${hint}${C_RESET}]: " answer
    answer="${answer:-$default}"
    case "$answer" in
        y|Y|yes|YES|Yes) return 0 ;;
        *)               return 1 ;;
    esac
}

# ask_password "Question" -> echoes password (input hidden)
ask_password() {
    local prompt="$1"
    local pw
    read -r -s -p "${C_BOLD}>${C_RESET} ${prompt}: " pw
    echo >&2
    echo "$pw"
}

# ask_with_confirm "Question" "default" "validator-fn"
# Asks, shows result, asks confirmation. Loops until confirmed.
# Validator function takes value as $1, returns 0 if ok.
ask_with_confirm() {
    local prompt="$1"
    local default="$2"
    local validator="${3:-}"
    local value
    while true; do
        if [ -n "$default" ]; then
            value=$(ask_default "$prompt" "$default")
        else
            value=$(ask "$prompt")
        fi
        if [ -z "$value" ]; then
            warn "Empty value, try again"
            continue
        fi
        if [ -n "$validator" ] && ! "$validator" "$value"; then
            warn "Validation failed, try again"
            continue
        fi
        echo "  You entered: ${C_CYAN}${value}${C_RESET}" >&2
        if ask_yn "Confirm?" "y"; then
            echo "$value"
            return 0
        fi
    done
}

# ============================================================
# System helpers
# ============================================================

require_root() {
    if [ "$(id -u)" != "0" ]; then
        fail "This script must be run as root (use sudo)"
    fi
}

require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        fail "Required command not found: $cmd"
    fi
}

# random_string LENGTH (default 24, alphanumeric)
random_string() {
    local len="${1:-24}"
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
}

# random_port MIN MAX
random_port() {
    local min="${1:-10000}"
    local max="${2:-60000}"
    local range=$((max - min + 1))
    echo $((min + RANDOM % range))
}

# detect_wan_iface -> echoes name of default-route interface
detect_wan_iface() {
    ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

# detect_ipv4 -> echoes primary IPv4 of WAN iface
detect_ipv4() {
    local iface="${1:-$(detect_wan_iface)}"
    ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

# detect_ipv6 -> echoes primary global IPv6 of WAN iface
detect_ipv6() {
    local iface="${1:-$(detect_wan_iface)}"
    ip -6 -o addr show dev "$iface" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1
}

# detect_ssh_client_ip -> echoes IP that initiated current SSH session
detect_ssh_client_ip() {
    if [ -n "${SSH_CLIENT:-}" ]; then
        echo "$SSH_CLIENT" | awk '{print $1}'
    elif [ -n "${SSH_CONNECTION:-}" ]; then
        echo "$SSH_CONNECTION" | awk '{print $1}'
    else
        echo ""
    fi
}

# ============================================================
# State persistence
# ============================================================
DEPLOY_STATE_DIR="${DEPLOY_STATE_DIR:-/etc/deploy}"
DEPLOY_STATE_FILE="${DEPLOY_STATE_DIR}/state.env"

# save_state KEY VALUE  -> persists to state file
save_state() {
    local key="$1"
    local value="$2"
    mkdir -p "$DEPLOY_STATE_DIR"
    chmod 700 "$DEPLOY_STATE_DIR"
    touch "$DEPLOY_STATE_FILE"
    chmod 600 "$DEPLOY_STATE_FILE"
    # Remove existing line for this key
    if grep -q "^${key}=" "$DEPLOY_STATE_FILE" 2>/dev/null; then
        sed -i "/^${key}=/d" "$DEPLOY_STATE_FILE"
    fi
    echo "${key}=${value}" >> "$DEPLOY_STATE_FILE"
}

# load_state -> sources state file into current shell
load_state() {
    if [ -f "$DEPLOY_STATE_FILE" ]; then
        set -a
        # shellcheck disable=SC1090
        source "$DEPLOY_STATE_FILE"
        set +a
    fi
}

# mark_phase_done PHASE_ID -> records that phase completed successfully
mark_phase_done() {
    local phase="$1"
    save_state "PHASE_${phase}_DONE" "$(date +%s)"
}

# is_phase_done PHASE_ID -> returns 0 if done, 1 if not
is_phase_done() {
    local phase="$1"
    load_state
    local var="PHASE_${phase}_DONE"
    [ -n "${!var:-}" ]
}