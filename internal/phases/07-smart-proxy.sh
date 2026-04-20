#!/usr/bin/env bash
# 07-smart-proxy.sh - install smart-proxy daemon
# Copies daemon Python modules, renders systemd unit, starts service.

PHASE_ID="07-smart-proxy"

run_phase() {
    load_state

    [ -n "${TEMPLATES_DIR:-}" ] || fail "TEMPLATES_DIR not set"

    # ----------------------------------------------------------------
    # Backup
    # ----------------------------------------------------------------
    backup_init "$PHASE_ID"
    backup_dir_recursive /usr/local/bin/smart-proxy
    backup_dir_recursive /etc/smart-proxy
    backup_dir_recursive /var/lib/smart-proxy
    backup_file /etc/systemd/system/smart-proxy.service
    backup_file /usr/local/bin/smart-proxy-ctl
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. Install Python deps
    # ----------------------------------------------------------------
    log "Installing Python deps for smart-proxy..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        python3 python3-pip \
        || fail "python3 install failed"
    # The daemon uses only stdlib, but we document this step for clarity.
    ok "python3 ready"

    # ----------------------------------------------------------------
    # 2. Deploy daemon modules
    # ----------------------------------------------------------------
    log "Deploying smart-proxy modules..."
    install -d -m 755 /usr/local/bin/smart-proxy

    for f in daemon.py tester.py db.py cli.py; do
        install -m 644 \
            "${TEMPLATES_DIR}/smart-proxy/$f" \
            "/usr/local/bin/smart-proxy/$f" \
            || fail "failed to install smart-proxy/$f"
    done
    ok "daemon modules installed"

    # CLI wrapper
    install -m 755 \
        "${TEMPLATES_DIR}/smart-proxy/smart-proxy-ctl" \
        /usr/local/bin/smart-proxy-ctl \
        || fail "failed to install smart-proxy-ctl"
    ok "smart-proxy-ctl installed"

    # ----------------------------------------------------------------
    # 3. Runtime dirs and config
    # ----------------------------------------------------------------
    log "Setting up runtime dirs..."

    install -d -m 755 /etc/smart-proxy
    install -d -m 755 /var/lib/smart-proxy
    install -d -m 755 /var/log

    # config.json was rendered in phase 06-routing, but if this phase runs
    # standalone (via --from-phase), we re-render to be safe.
    if [ ! -f /etc/smart-proxy/config.json ]; then
        render_template \
            "${TEMPLATES_DIR}/configs/smart-proxy-config.json.tpl" \
            /etc/smart-proxy/config.json
        chmod 644 /etc/smart-proxy/config.json
    fi

    # Touch cache db so first start doesn't race
    if [ ! -f /var/lib/smart-proxy/cache.db ]; then
        touch /var/lib/smart-proxy/cache.db
        chmod 644 /var/lib/smart-proxy/cache.db
    fi

    # Log files for tail -f in prxy-panel
    touch /var/log/smart-proxy.log /var/log/smart-proxy-access.log
    chmod 644 /var/log/smart-proxy.log /var/log/smart-proxy-access.log

    ok "runtime dirs and files ready"

    # ----------------------------------------------------------------
    # 4. systemd unit
    # ----------------------------------------------------------------
    log "Installing systemd unit..."

    render_template \
        "${TEMPLATES_DIR}/systemd/smart-proxy.service.tpl" \
        /etc/systemd/system/smart-proxy.service
    chmod 644 /etc/systemd/system/smart-proxy.service

    systemctl daemon-reload
    systemctl enable smart-proxy >/dev/null 2>&1 || true
    ok "systemd unit installed"

    # ----------------------------------------------------------------
    # 5. Start daemon
    # ----------------------------------------------------------------
    log "Starting smart-proxy daemon..."

    systemctl restart smart-proxy \
        || { journalctl -u smart-proxy --no-pager -n 30; fail "smart-proxy start failed"; }

    sleep 2

    if ! systemctl is-active --quiet smart-proxy; then
        journalctl -u smart-proxy --no-pager -n 30
        fail "smart-proxy not active"
    fi

    # Verify it's listening on 127.0.0.1:7070
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":7070$"; then
        ok "smart-proxy listening on 127.0.0.1:7070"
    else
        warn "smart-proxy running but not listening on 7070 yet, checking again..."
        sleep 3
        if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":7070$"; then
            ok "smart-proxy listening on 7070"
        else
            journalctl -u smart-proxy --no-pager -n 30
            fail "smart-proxy not listening on expected port"
        fi
    fi

    # ----------------------------------------------------------------
    # 6. Smoke test: ask CLI to show status of something
    # ----------------------------------------------------------------
    if command -v smart-proxy-ctl >/dev/null 2>&1; then
        if smart-proxy-ctl status example.com >/dev/null 2>&1; then
            ok "smart-proxy-ctl responds"
        else
            warn "smart-proxy-ctl did not respond to 'status example.com' (may be normal if daemon hasn't classified any domain yet)"
        fi
    fi

    return 0
}