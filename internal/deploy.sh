#!/usr/bin/env bash
# deploy.sh - internal-server deployment entrypoint
# Orchestrates 10 phases to turn fresh Ubuntu 22.04 into a working internal node.

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

# shellcheck source=lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=lib/render.sh
source "${LIB_DIR}/render.sh"
# shellcheck source=lib/backup.sh
source "${LIB_DIR}/backup.sh"
# shellcheck source=lib/validation.sh
source "${LIB_DIR}/validation.sh"

# ============================================================
# Ordered phase list
# ============================================================
PHASES=(
    "00-init"
    "01-precheck"
    "02-base"
    "03-ssl"
    "04-awg"
    "05-x-ui"
    "06-routing"
    "07-smart-proxy"
    "08-prxy-panel"
    "09-finalize"
)

# ============================================================
# Argument parsing
# ============================================================
MODE="full"
FROM_PHASE=""
ROLLBACK_PHASE=""
DRY_RUN="0"

usage() {
    cat <<HELP
Usage: sudo $0 [OPTIONS]

Deploys a new internal-node from scratch on Ubuntu 22.04.

Options:
  --from-phase N         Resume from phase N (e.g. 05-x-ui or 5)
  --rollback PHASE       Rollback a single phase (requires current RUN_ID)
  --rollback-all         Rollback every phase of current RUN_ID in reverse
  --list-backups         List available backups and exit
  --dry-run              Print what would happen without changing anything
  --help, -h             Show this help

Phases (in order):
HELP
    for p in "${PHASES[@]}"; do
        echo "  $p"
    done
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --from-phase)
            MODE="resume"
            FROM_PHASE="$2"
            shift 2
            ;;
        --rollback)
            MODE="rollback"
            ROLLBACK_PHASE="$2"
            shift 2
            ;;
        --rollback-all)
            MODE="rollback-all"
            shift
            ;;
        --list-backups)
            MODE="list-backups"
            shift
            ;;
        --dry-run)
            DRY_RUN="1"
            export DRY_RUN
            shift
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1
            ;;
    esac
done

# ============================================================
# Preflight: must be root, log dir exists
# ============================================================
require_root
mkdir -p "$(dirname "$DEPLOY_LOG")"
touch "$DEPLOY_LOG" 2>/dev/null || true
chmod 600 "$DEPLOY_LOG" 2>/dev/null || true

log_file "===== deploy.sh invoked ====="
log_file "args: $*"
log_file "mode: $MODE"
log_file "RUN_ID: $RUN_ID"

# ============================================================
# Handle special modes first
# ============================================================
case "$MODE" in
    list-backups)
        list_backups
        exit 0
        ;;
    rollback)
        # RUN_ID must be set or inferred from state
        load_state
        if [ -n "${LAST_RUN_ID:-}" ]; then
            RUN_ID="$LAST_RUN_ID"
            export RUN_ID
        fi
        rollback_phase "$ROLLBACK_PHASE"
        exit $?
        ;;
    rollback-all)
        load_state
        if [ -n "${LAST_RUN_ID:-}" ]; then
            RUN_ID="$LAST_RUN_ID"
            export RUN_ID
        fi
        rollback_all
        exit $?
        ;;
esac

# ============================================================
# Determine starting phase
# ============================================================
start_idx=0

if [ "$MODE" = "resume" ]; then
    # Accept both "5" and "05-x-ui"
    normalized=""
    if [[ "$FROM_PHASE" =~ ^[0-9]+$ ]]; then
        for i in "${!PHASES[@]}"; do
            if [[ "${PHASES[$i]}" == $(printf "%02d" "$FROM_PHASE")-* ]]; then
                normalized="${PHASES[$i]}"
                start_idx="$i"
                break
            fi
        done
    else
        for i in "${!PHASES[@]}"; do
            if [ "${PHASES[$i]}" = "$FROM_PHASE" ]; then
                normalized="$FROM_PHASE"
                start_idx="$i"
                break
            fi
        done
    fi
    [ -n "$normalized" ] || fail "Unknown phase: $FROM_PHASE"
    log "Resuming from $normalized"
fi

# Save RUN_ID for future --rollback invocations without args
save_state "LAST_RUN_ID" "$RUN_ID"
install_backup_cron

# ============================================================
# Main loop
# ============================================================
if [ "$DRY_RUN" = "1" ]; then
    log "DRY-RUN mode: will not actually change the system"
fi

step "Starting deploy RUN_ID=$RUN_ID"

for (( i = start_idx; i < ${#PHASES[@]}; i++ )); do
    phase="${PHASES[$i]}"
    phase_file="${PHASES_DIR}/${phase}.sh"

    if [ ! -f "$phase_file" ]; then
        fail "Phase script not found: $phase_file"
    fi

    step "Phase $phase"
    log_file "===== phase $phase start ====="

    if [ "$DRY_RUN" = "1" ]; then
        log "  [dry-run] would source $phase_file and run run_phase"
        continue
    fi

    # Each phase file defines a function run_phase that does the work.
    # shellcheck disable=SC1090
    source "$phase_file"

    if ! declare -f run_phase >/dev/null; then
        fail "Phase $phase: run_phase function not defined in $phase_file"
    fi

    # Run the phase. On failure, rollback is triggered.
    if run_phase; then
        mark_phase_done "$phase"
        ok "Phase $phase complete"
        log_file "===== phase $phase done ====="
    else
        warn "Phase $phase failed, rolling back..."
        rollback_phase "$phase" || true
        fail "Deployment aborted at phase $phase. See $DEPLOY_LOG for details."
    fi

    # Unset run_phase so the next phase's definition is clean
    unset -f run_phase
done

step "Deployment complete"
log "All phases finished successfully. RUN_ID=$RUN_ID"
log "Backups retained for 24h at $BACKUP_ROOT/$RUN_ID"
log_file "===== deploy.sh finished OK ====="