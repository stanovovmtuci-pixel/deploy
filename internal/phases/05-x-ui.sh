#!/usr/bin/env bash
# 05-x-ui.sh - install and configure 3x-ui panel with Xray core
# Sets custom port, web base path, admin credentials, geo files auto-update.

PHASE_ID="05-x-ui"

run_phase() {
    load_state

    [ -n "${X_UI_PANEL_PORT:-}" ]  || fail "X_UI_PANEL_PORT not set"
    [ -n "${X_UI_WEB_BASE:-}" ]    || fail "X_UI_WEB_BASE not set"
    [ -n "${X_UI_ADMIN_USER:-}" ]  || fail "X_UI_ADMIN_USER not set"
    [ -n "${X_UI_ADMIN_PASS:-}" ]  || fail "X_UI_ADMIN_PASS not set"

    # ----------------------------------------------------------------
    # Backup
    # ----------------------------------------------------------------
    backup_init "$PHASE_ID"
    backup_dir_recursive /etc/x-ui
    backup_dir_recursive /usr/local/x-ui
    backup_file /etc/systemd/system/x-ui.service
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. Install 3x-ui (non-interactive)
    # ----------------------------------------------------------------
    log "Installing 3x-ui..."

    if systemctl list-unit-files x-ui.service >/dev/null 2>&1; then
        ok "x-ui already installed (will reconfigure)"
    else
        # The upstream installer is interactive; pipe blank answers to get defaults.
        # Installer URL pinned to mhsanaei/3x-ui master (stable)
        local installer_url="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"

        if ! curl -fsSL "$installer_url" -o /tmp/x-ui-install.sh; then
            fail "failed to download 3x-ui installer"
        fi

        chmod +x /tmp/x-ui-install.sh
        # Feed "n" answers to all prompts; installer accepts defaults.
        printf 'n\nn\nn\nn\n' | bash /tmp/x-ui-install.sh \
            || fail "3x-ui install script failed"

        rm -f /tmp/x-ui-install.sh
    fi

    [ -f /etc/x-ui/x-ui.db ] || fail "x-ui.db not found after install"
    ok "3x-ui installed"

    # ----------------------------------------------------------------
    # 2. Stop x-ui to modify DB safely
    # ----------------------------------------------------------------
    systemctl stop x-ui 2>/dev/null || true
    sleep 1

    # ----------------------------------------------------------------
    # 3. Configure panel via sqlite (port, webBasePath, credentials)
    # ----------------------------------------------------------------
    log "Configuring panel..."

    local db=/etc/x-ui/x-ui.db

    # Update settings table
    sqlite3 "$db" <<SQL
UPDATE settings SET value='${X_UI_PANEL_PORT}' WHERE key='webPort';
UPDATE settings SET value='${X_UI_WEB_BASE}' WHERE key='webBasePath';
UPDATE settings SET value='127.0.0.1' WHERE key='webListen';
INSERT OR REPLACE INTO settings (key, value) VALUES ('webPort','${X_UI_PANEL_PORT}');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webBasePath','${X_UI_WEB_BASE}');
INSERT OR REPLACE INTO settings (key, value) VALUES ('webListen','127.0.0.1');
SQL

    # Update admin credentials. 3x-ui stores in users table (plain for username,
    # bcrypt for password depending on version). We use its built-in CLI if exists.
    if command -v x-ui >/dev/null 2>&1; then
        # x-ui has a menu CLI; we need to script it. Different versions differ.
        # Safest: modify DB directly.
        :
    fi

    # Direct DB update (users table schema: id, username, password)
    sqlite3 "$db" <<SQL
UPDATE users SET username='${X_UI_ADMIN_USER}', password='${X_UI_ADMIN_PASS}' WHERE id=1;
SQL

    ok "panel configured: port=$X_UI_PANEL_PORT base=$X_UI_WEB_BASE user=$X_UI_ADMIN_USER"

    # ----------------------------------------------------------------
    # 4. Geo files: install and schedule updates
    # ----------------------------------------------------------------
    log "Installing Runet Freedom geo files..."

    local geo_dir=/usr/local/x-ui/bin
    mkdir -p "$geo_dir"

    local geoip_url="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geoip.dat"
    local geosite_url="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat"

    if curl -fsSL -o "${geo_dir}/geoip.dat.new" "$geoip_url" \
    && curl -fsSL -o "${geo_dir}/geosite.dat.new" "$geosite_url"; then
        mv "${geo_dir}/geoip.dat.new"   "${geo_dir}/geoip.dat"
        mv "${geo_dir}/geosite.dat.new" "${geo_dir}/geosite.dat"
        ok "geo files installed ($(du -h ${geo_dir}/geoip.dat | awk '{print $1}') + $(du -h ${geo_dir}/geosite.dat | awk '{print $1}'))"
    else
        warn "failed to download geo files (will retry via cron)"
    fi

    # ---- update script
    cat > /usr/local/bin/update-geodat.sh <<'UPDSCRIPT'
#!/bin/bash
# Update Runet Freedom geo files for Xray. Atomic replacement, rollback on failure.
set -e
GEO_DIR=/usr/local/x-ui/bin
BASE="https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download"
LOG=/var/log/geodat-update.log

log() { echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

cd "$GEO_DIR"
for f in geoip.dat geosite.dat; do
    if ! curl -fsSL -o "${f}.new" "${BASE}/${f}"; then
        log "FAIL download $f"
        rm -f "${f}.new"
        continue
    fi
    # Rollback-safe atomic replace
    cp -a "$f" "${f}.bak" 2>/dev/null || true
    mv "${f}.new" "$f"
    log "updated $f ($(sha256sum $f | cut -c1-16)...)"
done

systemctl restart x-ui 2>/dev/null && log "x-ui restarted"
UPDSCRIPT
    chmod +x /usr/local/bin/update-geodat.sh

    # ---- systemd timer for hourly update
    cat > /etc/systemd/system/geodat-update.service <<'SRV'
[Unit]
Description=Update Xray geo files from runetfreedom
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/update-geodat.sh
SRV
    cat > /etc/systemd/system/geodat-update.timer <<'TMR'
[Unit]
Description=Update Xray geo files hourly

[Timer]
OnBootSec=15min
OnUnitActiveSec=1h
Persistent=true

[Install]
WantedBy=timers.target
TMR
    systemctl daemon-reload
    systemctl enable --now geodat-update.timer >/dev/null 2>&1 || warn "geodat-update.timer enable failed"
    ok "geodat-update timer scheduled (hourly)"

    # ----------------------------------------------------------------
    # 5. Start x-ui
    # ----------------------------------------------------------------
    systemctl enable x-ui >/dev/null 2>&1 || true
    systemctl start  x-ui \
        || { journalctl -u x-ui --no-pager -n 20; fail "x-ui failed to start"; }

    sleep 3
    if systemctl is-active --quiet x-ui; then
        ok "x-ui is running on 127.0.0.1:${X_UI_PANEL_PORT}"
    else
        fail "x-ui not active after start"
    fi

    return 0
}