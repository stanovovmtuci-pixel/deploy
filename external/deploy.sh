#!/usr/bin/env bash
# deploy.sh - external (FI) node deployment entrypoint
# Orchestrates 10 phases to turn fresh Ubuntu 22.04 into a working external node:
#   AWG endpoint + xray VLESS bridge + Cloudflare WARP egress.
#
# Usage:
#   sudo ./deploy.sh                       # full interactive deploy
#   sudo ./deploy.sh --from-phase 03       # resume from phase 03
#   sudo ./deploy.sh --only 04             # run only phase 04 (idempotent)
#   sudo ./deploy.sh --rollback 04         # rollback phase 04 (must be in same RUN_ID)
#   sudo ./deploy.sh --rollback-all        # rollback every phase of current RUN_ID
#   sudo ./deploy.sh --list                # list phases and exit
#   sudo ./deploy.sh --dry-run             # parse manifest, show summary, exit
#   sudo ./deploy.sh --manifest-summary    # print all placeholders with classification
#
# Environment:
#   NO_COLOR=1            -> disable ANSI colors
#   DEPLOY_LOG=path       -> override log path (default /var/log/deploy-external.log)
#   DEPLOY_STATE_DIR=path -> override state dir (default /etc/deploy)
#   BACKUP_ROOT=path      -> override backups root (default /var/backups/deploy)
#   SECRETS_DIR=path      -> override secrets dir (default /root/external-deploy-secrets)
#   RUN_ID=string         -> override run id (default YYYYMMDD-HHMMSS-PID)

set -u
# NOTE: we intentionally do NOT use `set -e` globally. Error handling is explicit
# per-phase via trap ERR inside each phase. This gives us control over rollback.

# ============================================================
# Locate self and load libs
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEPLOY_ROOT="$SCRIPT_DIR"
export TEMPLATES_DIR="${DEPLOY_ROOT}/templates"
export PHASES_DIR="${DEPLOY_ROOT}/phases"
export LIB_DIR="${DEPLOY_ROOT}/lib"
export MANIFEST_FILE="${DEPLOY_ROOT}/manifest.json"

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/render.sh
source "${LIB_DIR}/render.sh"
# shellcheck source=lib/backup.sh
source "${LIB_DIR}/backup.sh"
# shellcheck source=lib/validation.sh
source "${LIB_DIR}/validation.sh"
# shellcheck source=lib/manifest.sh
source "${LIB_DIR}/manifest.sh"
# shellcheck source=lib/secrets.sh
source "${LIB_DIR}/secrets.sh"

# ============================================================
# Ordered phase list
# ============================================================
PHASES=(
    "00-init"
    "01-precheck"
    "02-base"
    "03-amneziawg"
    "04-warp"
    "05-xray"
    "06-firewall"
    "07-validate"
    "08-secrets-export"
    "09-finalize"
)

# ============================================================
# Argument parsing
# ============================================================
MODE="full"           # full | from | only | rollback | rollback-all | list | dry-run | manifest-summary
TARGET_PHASE=""       # phase id for from / only / rollback
DRY_RUN="0"

usage() {
    sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --from-phase|--from)
            MODE="from"
            shift
            TARGET_PHASE="${1:-}"
            [ -n "$TARGET_PHASE" ] || { echo "ERROR: --from-phase needs argument"; usage 2; }
            ;;
        --only)
            MODE="only"
            shift
            TARGET_PHASE="${1:-}"
            [ -n "$TARGET_PHASE" ] || { echo "ERROR: --only needs argument"; usage 2; }
            ;;
        --rollback)
            MODE="rollback"
            shift
            TARGET_PHASE="${1:-}"
            [ -n "$TARGET_PHASE" ] || { echo "ERROR: --rollback needs argument"; usage 2; }
            ;;
        --rollback-all)
            MODE="rollback-all"
            ;;
        --list|--list-phases)
            MODE="list"
            ;;
        --dry-run)
            DRY_RUN="1"
            MODE="dry-run"
            ;;
        --manifest-summary)
            MODE="manifest-summary"
            ;;
        -h|--help)
            usage 0
            ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage 2
            ;;
    esac
    shift
done

# ============================================================
# Quick-action modes (no root needed for some)
# ============================================================

if [ "$MODE" = "list" ]; then
    log "Phases (in execution order):"
    for ph in "${PHASES[@]}"; do
        local_path="${PHASES_DIR}/${ph}.sh"
        if [ -f "$local_path" ]; then
            echo "  ${ph}"
        else
            echo "  ${ph}  ${C_YELLOW}(not implemented yet)${C_RESET}"
        fi
    done
    exit 0
fi

if [ "$MODE" = "manifest-summary" ]; then
    require_command jq
    manifest_print_summary
    exit 0
fi

if [ "$MODE" = "dry-run" ]; then
    require_command jq
    log "Dry run — parsing manifest only, no system changes"
    manifest_print_summary
    log "Phases that would run (in order):"
    for ph in "${PHASES[@]}"; do
        local_path="${PHASES_DIR}/${ph}.sh"
        [ -f "$local_path" ] && echo "  ${ph}" || echo "  ${ph}  (not implemented)"
    done
    exit 0
fi

# ============================================================
# Real-action modes need root
# ============================================================
require_root

# Setup log dir/file
mkdir -p "$(dirname "$DEPLOY_LOG")" 2>/dev/null || true
touch "$DEPLOY_LOG" 2>/dev/null || true
chmod 600 "$DEPLOY_LOG" 2>/dev/null || true

step "External-node deploy / RUN_ID=$RUN_ID / mode=$MODE"
log_file "================================================================"
log_file "deploy.sh start: mode=$MODE target=${TARGET_PHASE:-none} run=$RUN_ID"

# ============================================================
# Run a single phase
# ============================================================
run_phase_file() {
    local ph="$1"
    local path="${PHASES_DIR}/${ph}.sh"

    if [ ! -f "$path" ]; then
        warn "phase script not found: $path (skipping)"
        return 0
    fi

    if is_phase_done "$ph" && [ "$MODE" != "only" ]; then
        log "Phase ${C_BOLD}${ph}${C_RESET} already completed (skip; use --only to force re-run)"
        return 0
    fi

    step "Running phase: $ph"
    log_file "[$ph] starting"

    # Source phase script (it must define run_phase function)
    PHASE_ID="$ph"
    # shellcheck disable=SC1090
    source "$path"

    # Per-phase trap: on any error, attempt rollback of THIS phase
    trap '
        rc=$?
        warn "phase $PHASE_ID failed (rc=$rc); rolling back..."
        rollback_phase "$PHASE_ID" || warn "rollback returned non-zero"
        log_file "[$PHASE_ID] failed rc=$rc, rolled back"
        exit $rc
    ' ERR

    # Re-enable -e inside the phase context
    set -e
    run_phase
    set +e
    trap - ERR

    mark_phase_done "$ph"
    log_file "[$ph] done"
    ok "phase $ph complete"
}

# ============================================================
# Mode dispatch
# ============================================================

case "$MODE" in
    full)
        for ph in "${PHASES[@]}"; do
            run_phase_file "$ph"
        done
        ;;

    from)
        local_seen="0"
        for ph in "${PHASES[@]}"; do
            if [ "$ph" = "$TARGET_PHASE" ]; then
                local_seen="1"
            fi
            if [ "$local_seen" = "1" ]; then
                run_phase_file "$ph"
            fi
        done
        if [ "$local_seen" = "0" ]; then
            fail "phase '$TARGET_PHASE' not found in PHASES list"
        fi
        ;;

    only)
        local_found="0"
        for ph in "${PHASES[@]}"; do
            if [ "$ph" = "$TARGET_PHASE" ]; then
                local_found="1"
                run_phase_file "$ph"
            fi
        done
        if [ "$local_found" = "0" ]; then
            fail "phase '$TARGET_PHASE' not found in PHASES list"
        fi
        ;;

    rollback)
        rollback_phase "$TARGET_PHASE" || fail "rollback failed"
        ok "rollback of $TARGET_PHASE done"
        ;;

    rollback-all)
        rollback_all || fail "rollback-all encountered errors"
        ok "rollback-all done"
        ;;

    *)
        fail "internal error: unknown mode $MODE"
        ;;
esac

# ============================================================
# Final summary
# ============================================================

if [ "$MODE" = "full" ] || [ "$MODE" = "from" ]; then
    step "Deploy complete"
    log "RUN_ID: $RUN_ID"
    log "Log:    $DEPLOY_LOG"
    log "State:  $DEPLOY_STATE_FILE"
    log "Backups under: ${BACKUP_ROOT}/${RUN_ID}/"
    log_file "deploy.sh finished successfully"
fi