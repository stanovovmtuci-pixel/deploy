#!/usr/bin/env bash
# backup.sh - phase backup and rollback system
# Sourced by phases. Provides per-phase snapshots with 24h TTL.

# RUN_ID is set by deploy.sh entrypoint and exported
# Format: YYYYMMDD-HHMMSS-PID
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
export RUN_ID

BACKUP_ROOT="${BACKUP_ROOT:-/var/backups/deploy}"

# Internal: derive backup dir for current phase
_phase_backup_dir() {
    local phase="$1"
    echo "${BACKUP_ROOT}/${RUN_ID}/${phase}"
}

# backup_init PHASE_ID
# Creates backup directory for the phase. Call at start of each phase.
backup_init() {
    local phase="$1"
    local dir
    dir=$(_phase_backup_dir "$phase")
    mkdir -p "$dir/files"
    chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
    chmod 700 "${BACKUP_ROOT}/${RUN_ID}" 2>/dev/null || true
    chmod 700 "$dir" 2>/dev/null || true
    log_file "[$phase] backup init at $dir"
    echo "$dir" > /tmp/.deploy-current-backup
}

_current_backup_dir() {
    if [ -f /tmp/.deploy-current-backup ]; then
        cat /tmp/.deploy-current-backup
    else
        echo ""
    fi
}

# backup_file PATH
# Snapshots a single file to current phase backup. Path is preserved as filename
# with / replaced by _. If file doesn't exist, records that fact (so rollback
# knows to delete the new file).
backup_file() {
    local src="$1"
    local dir
    dir=$(_current_backup_dir)
    [ -n "$dir" ] || fail "backup_file called outside backup_init"

    local safe_name
    safe_name=$(echo "$src" | sed 's|^/||; s|/|_|g')

    if [ -f "$src" ]; then
        cp -a "$src" "${dir}/files/${safe_name}"
        log_file "  backed up file: $src"
    else
        # Mark as "did not exist" so rollback can delete what we created
        echo "$src" >> "${dir}/files-to-delete-on-rollback.txt"
        log_file "  noted absent file: $src (will delete on rollback)"
    fi
}

# backup_dir_recursive PATH
# Snapshots whole directory as tar.gz. If absent, marks for deletion.
backup_dir_recursive() {
    local src="$1"
    local dir
    dir=$(_current_backup_dir)
    [ -n "$dir" ] || fail "backup_dir_recursive called outside backup_init"

    local safe_name
    safe_name=$(echo "$src" | sed 's|^/||; s|/|_|g')

    if [ -d "$src" ]; then
        tar -czf "${dir}/files/${safe_name}.tar.gz" -C "$(dirname "$src")" "$(basename "$src")" 2>/dev/null
        log_file "  backed up dir: $src"
    else
        echo "$src" >> "${dir}/dirs-to-delete-on-rollback.txt"
        log_file "  noted absent dir: $src (will delete on rollback)"
    fi
}

# backup_systemd_state
# Records currently active systemd units. Rollback can stop newly-started ones.
backup_systemd_state() {
    local dir
    dir=$(_current_backup_dir)
    [ -n "$dir" ] || fail "backup_systemd_state called outside backup_init"

    systemctl list-units --type=service --state=active --no-pager --no-legend 2>/dev/null \
        | awk '{print $1}' | sort > "${dir}/systemd-active-before.txt"
    log_file "  snapshotted systemd active services"
}

# backup_iptables
# Saves current iptables and ip6tables for restore.
backup_iptables() {
    local dir
    dir=$(_current_backup_dir)
    [ -n "$dir" ] || fail "backup_iptables called outside backup_init"

    iptables-save  > "${dir}/iptables.rules"  2>/dev/null || true
    ip6tables-save > "${dir}/ip6tables.rules" 2>/dev/null || true
    log_file "  snapshotted iptables / ip6tables"
}

# rollback_phase PHASE_ID
# Restores everything that backup_* functions captured.
rollback_phase() {
    local phase="$1"
    local dir
    dir=$(_phase_backup_dir "$phase")

    if [ ! -d "$dir" ]; then
        warn "rollback_phase: no backup found for phase $phase at $dir"
        return 1
    fi

    warn "Rolling back phase: $phase (backup at $dir)"

    # 1. Restore files (and delete files that didn't exist before)
    if [ -d "${dir}/files" ]; then
        for backup in "${dir}/files"/*; do
            [ -f "$backup" ] || continue
            local fname
            fname=$(basename "$backup")
            # Restore tar.gz dirs separately
            if [[ "$fname" == *.tar.gz ]]; then
                local dirname_safe="${fname%.tar.gz}"
                local original_dir="/$(echo "$dirname_safe" | sed 's|_|/|g')"
                local parent
                parent=$(dirname "$original_dir")
                rm -rf "$original_dir" 2>/dev/null || true
                mkdir -p "$parent"
                tar -xzf "$backup" -C "$parent" 2>/dev/null
                log_file "  restored dir: $original_dir"
            else
                local original="/$(echo "$fname" | sed 's|_|/|g')"
                cp -a "$backup" "$original"
                log_file "  restored file: $original"
            fi
        done
    fi

    # 2. Delete files that we created (which weren't there before)
    if [ -f "${dir}/files-to-delete-on-rollback.txt" ]; then
        while IFS= read -r path; do
            [ -n "$path" ] && rm -f "$path" 2>/dev/null && log_file "  deleted (was absent): $path"
        done < "${dir}/files-to-delete-on-rollback.txt"
    fi

    if [ -f "${dir}/dirs-to-delete-on-rollback.txt" ]; then
        while IFS= read -r path; do
            [ -n "$path" ] && rm -rf "$path" 2>/dev/null && log_file "  deleted dir (was absent): $path"
        done < "${dir}/dirs-to-delete-on-rollback.txt"
    fi

    # 3. Restore iptables
    if [ -f "${dir}/iptables.rules" ]; then
        iptables-restore < "${dir}/iptables.rules" 2>/dev/null || true
        log_file "  restored iptables"
    fi
    if [ -f "${dir}/ip6tables.rules" ]; then
        ip6tables-restore < "${dir}/ip6tables.rules" 2>/dev/null || true
        log_file "  restored ip6tables"
    fi

    # 4. Stop services that we started during this phase
    if [ -f "${dir}/systemd-active-before.txt" ]; then
        local active_now
        active_now=$(systemctl list-units --type=service --state=active --no-pager --no-legend 2>/dev/null | awk '{print $1}' | sort)
        local newly_started
        newly_started=$(comm -13 "${dir}/systemd-active-before.txt" <(echo "$active_now"))
        if [ -n "$newly_started" ]; then
            for svc in $newly_started; do
                systemctl stop "$svc" 2>/dev/null && log_file "  stopped newly-started service: $svc"
            done
        fi
    fi

    log_file "[$phase] rollback complete"
    warn "Rollback of $phase complete. Manual cleanup may still be needed for: apt packages, certbot certs."
}

# rollback_all
# Rolls back every phase in current RUN_ID, in reverse order.
rollback_all() {
    local run_dir="${BACKUP_ROOT}/${RUN_ID}"
    if [ ! -d "$run_dir" ]; then
        warn "rollback_all: no backups for current RUN_ID=$RUN_ID"
        return 1
    fi

    local phases
    phases=$(ls -1 "$run_dir" 2>/dev/null | sort -r)
    for phase in $phases; do
        rollback_phase "$phase" || true
    done
}

# list_backups
# Shows what's in BACKUP_ROOT.
list_backups() {
    if [ ! -d "$BACKUP_ROOT" ]; then
        log "No backups exist at $BACKUP_ROOT"
        return 0
    fi
    log "Backups under $BACKUP_ROOT:"
    for run in "$BACKUP_ROOT"/*; do
        [ -d "$run" ] || continue
        local rid
        rid=$(basename "$run")
        echo "  ${C_CYAN}${rid}${C_RESET}"
        for phase in "$run"/*; do
            [ -d "$phase" ] || continue
            local pname size
            pname=$(basename "$phase")
            size=$(du -sh "$phase" 2>/dev/null | awk '{print $1}')
            echo "    - $pname ($size)"
        done
    done
}

# install_backup_cron
# Installs cron job to delete backups older than 24h. Idempotent.
install_backup_cron() {
    local cron_file=/etc/cron.d/deploy-backup-cleanup
    if [ -f "$cron_file" ]; then
        return 0
    fi
    cat > "$cron_file" <<'CRON'
# Cleanup deploy-kit backups older than 24h
0 4 * * * root find /var/backups/deploy -mindepth 1 -maxdepth 1 -type d -mtime +1 -exec rm -rf {} + 2>/dev/null
CRON
    chmod 644 "$cron_file"
    log_file "installed backup cleanup cron"
}

# uninstall_backup_cron
uninstall_backup_cron() {
    rm -f /etc/cron.d/deploy-backup-cleanup
}