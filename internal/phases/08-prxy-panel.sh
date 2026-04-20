#!/usr/bin/env bash
# 08-prxy-panel.sh - install prxy-panel (Flask) as a gunicorn service
# Nginx proxies /prxy/ -> 127.0.0.1:5001. Initial password stored via env once.

PHASE_ID="08-prxy-panel"

run_phase() {
    load_state

    [ -n "${ADMIN_USER:-}" ]                 || fail "ADMIN_USER not set"
    [ -n "${PRXY_PANEL_INIT_PASSWORD:-}" ]   || fail "PRXY_PANEL_INIT_PASSWORD not in env (rerun 00-init)"
    [ -n "${TEMPLATES_DIR:-}" ]              || fail "TEMPLATES_DIR not set"

    id "$ADMIN_USER" >/dev/null 2>&1 || fail "admin user $ADMIN_USER does not exist"

    # ----------------------------------------------------------------
    # Backup
    # ----------------------------------------------------------------
    backup_init "$PHASE_ID"
    backup_dir_recursive /opt/prxy-panel
    backup_file /etc/systemd/system/prxy-panel.service
    backup_file /etc/sudoers.d/prxy-panel
    backup_file /etc/default/prxy-panel
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. Python deps (as admin user, to --user site)
    # ----------------------------------------------------------------
    log "Installing Python deps (flask, gunicorn, bcrypt) as $ADMIN_USER..."

    sudo -u "$ADMIN_USER" -H python3 -m pip install --user --quiet --upgrade pip \
        || warn "pip upgrade failed (continuing)"

    sudo -u "$ADMIN_USER" -H python3 -m pip install --user --quiet \
        flask==3.0.* gunicorn bcrypt \
        || fail "pip install failed"

    # Sanity check
    local user_home
    user_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    local gunicorn_bin="${user_home}/.local/bin/gunicorn"

    [ -x "$gunicorn_bin" ] || fail "gunicorn not installed at $gunicorn_bin"
    ok "Python deps installed"

    # ----------------------------------------------------------------
    # 2. Deploy application files
    # ----------------------------------------------------------------
    log "Deploying prxy-panel files..."

    install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 755 /opt/prxy-panel
    install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 755 /opt/prxy-panel/templates
    install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 755 /opt/prxy-panel/static

    render_template \
        "${TEMPLATES_DIR}/prxy-panel/app.py.tpl" \
        /opt/prxy-panel/app.py
    chown "$ADMIN_USER:$ADMIN_USER" /opt/prxy-panel/app.py
    chmod 640 /opt/prxy-panel/app.py

    render_template \
        "${TEMPLATES_DIR}/prxy-panel/templates/index.html.tpl" \
        /opt/prxy-panel/templates/index.html
    render_template \
        "${TEMPLATES_DIR}/prxy-panel/templates/login.html.tpl" \
        /opt/prxy-panel/templates/login.html
    render_template \
        "${TEMPLATES_DIR}/prxy-panel/static/app.js.tpl" \
        /opt/prxy-panel/static/app.js

    chown -R "$ADMIN_USER:$ADMIN_USER" /opt/prxy-panel
    ok "prxy-panel files deployed"

    # ----------------------------------------------------------------
    # 3. Sudoers for panel -> systemctl
    # ----------------------------------------------------------------
    log "Installing sudoers for panel..."

    local sudoers_tmp=/tmp/prxy-panel.sudoers.new
    render_template \
        "${TEMPLATES_DIR}/configs/sudoers-prxy-panel.tpl" \
        "$sudoers_tmp"

    # Validate with visudo before installing
    if ! visudo -c -f "$sudoers_tmp" >/dev/null 2>&1; then
        rm -f "$sudoers_tmp"
        fail "sudoers template produced invalid file; refusing to install"
    fi

    install -m 440 "$sudoers_tmp" /etc/sudoers.d/prxy-panel
    rm -f "$sudoers_tmp"
    ok "sudoers installed"

    # ----------------------------------------------------------------
    # 4. Systemd unit
    # ----------------------------------------------------------------
    log "Installing systemd unit..."
    render_template \
        "${TEMPLATES_DIR}/systemd/prxy-panel.service.tpl" \
        /etc/systemd/system/prxy-panel.service
    chmod 644 /etc/systemd/system/prxy-panel.service
    systemctl daemon-reload

    # ----------------------------------------------------------------
    # 5. One-time password via env file
    # ----------------------------------------------------------------
    log "Writing one-time init password to /etc/default/prxy-panel..."

    # Make sure users.json does NOT exist, otherwise init_users() skips and
    # we'll be left with no admin account.
    rm -f /opt/prxy-panel/users.json

    cat > /etc/default/prxy-panel <<ENV
# TEMPORARY - cleared after first successful start
PRXY_PANEL_INIT_PASSWORD=${PRXY_PANEL_INIT_PASSWORD}
PRXY_PANEL_PREFIX=/prxy
ENV
    chmod 600 /etc/default/prxy-panel

    # ----------------------------------------------------------------
    # 6. First start -> bcrypt hash written to users.json
    # ----------------------------------------------------------------
    log "Starting prxy-panel for first time..."
    systemctl enable prxy-panel >/dev/null 2>&1 || true
    systemctl restart prxy-panel \
        || { journalctl -u prxy-panel --no-pager -n 30; fail "prxy-panel start failed"; }

    # Wait for gunicorn + trigger init_users() via first HTTP hit
    local attempts=0
    while [ "$attempts" -lt 10 ]; do
        if curl -sf -o /dev/null --max-time 3 http://127.0.0.1:5001/prxy/login 2>/dev/null; then
            break
        fi
        attempts=$((attempts + 1))
        sleep 1
    done

    if [ "$attempts" -ge 10 ]; then
        journalctl -u prxy-panel --no-pager -n 30
        fail "prxy-panel did not respond on 127.0.0.1:5001 after 10s"
    fi

    # Confirm users.json was created with admin
    if [ ! -s /opt/prxy-panel/users.json ]; then
        journalctl -u prxy-panel --no-pager -n 30
        fail "users.json not created after first hit"
    fi
    ok "prxy-panel up and users.json initialized"

    # ----------------------------------------------------------------
    # 7. Wipe init password from env file (bcrypt hash is in users.json now)
    # ----------------------------------------------------------------
    cat > /etc/default/prxy-panel <<ENV
# Init password cleared after first start.
# Admin password is now bcrypt-hashed in /opt/prxy-panel/users.json.
PRXY_PANEL_PREFIX=/prxy
ENV
    chmod 600 /etc/default/prxy-panel

    # Restart so the cleared env takes effect (harmless; users.json exists)
    systemctl restart prxy-panel
    sleep 1

    if systemctl is-active --quiet prxy-panel; then
        ok "prxy-panel running; init password wiped from /etc/default/prxy-panel"
    else
        fail "prxy-panel not active after restart"
    fi

    return 0
}