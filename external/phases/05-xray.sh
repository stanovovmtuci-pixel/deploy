#!/usr/bin/env bash
# 05-xray.sh - install Xray (XTLS/Xray-core) binary + systemd unit + config
#
# What it does:
#   1. download Xray binary from github releases (or skip if version match)
#   2. install to /usr/local/bin/xray (mode 755 root:root)
#   3. create /usr/local/etc/xray/  and  /var/log/xray/
#   4. render config.json (VLESS inbound on fd10::1:PORT -> SOCKS5 outbound to WARP)
#   5. render xray.service + drop-in 10-donot_touch_single_conf.conf
#   6. systemctl daemon-reload + enable + restart
#   7. verify: process running, listening on AWG_TUN_IPV6:XRAY_INBOUND_PORT
#
# Idempotent. Safe to re-run (config refresh).

PHASE_ID="05-xray"

XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
XRAY_DOWNLOAD_URL_TEMPLATE="https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-64.zip"
XRAY_TMP_DIR="/tmp/xray-install-$$"

run_phase() {
    load_state

    # Required state
    [ -n "${XRAY_INSTALL_DIR:-}"      ] || fail "XRAY_INSTALL_DIR not set"
    [ -n "${XRAY_CONFIG_DIR:-}"       ] || fail "XRAY_CONFIG_DIR not set"
    [ -n "${XRAY_LOG_DIR:-}"          ] || fail "XRAY_LOG_DIR not set"
    [ -n "${XRAY_SERVICE_USER:-}"     ] || fail "XRAY_SERVICE_USER not set"
    [ -n "${XRAY_SERVICE_GROUP:-}"    ] || fail "XRAY_SERVICE_GROUP not set"
    [ -n "${XRAY_INBOUND_LISTEN:-}"   ] || fail "XRAY_INBOUND_LISTEN not set"
    [ -n "${XRAY_INBOUND_PORT:-}"     ] || fail "XRAY_INBOUND_PORT not set"
    [ -n "${XRAY_CLIENT_UUID:-}"      ] || fail "XRAY_CLIENT_UUID not set (run 00-init)"
    [ -n "${XRAY_OUTBOUND_ADDRESS:-}" ] || fail "XRAY_OUTBOUND_ADDRESS not set"
    [ -n "${XRAY_OUTBOUND_PORT:-}"    ] || fail "XRAY_OUTBOUND_PORT not set"

    backup_init "$PHASE_ID"
    backup_file "${XRAY_INSTALL_DIR}/xray"
    backup_dir_recursive "${XRAY_CONFIG_DIR}"
    backup_file /etc/systemd/system/xray.service
    backup_dir_recursive /etc/systemd/system/xray.service.d
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. Download xray binary
    # ----------------------------------------------------------------
    log "1/7 download xray binary"

    local need_install="1"
    if [ -x "${XRAY_INSTALL_DIR}/xray" ]; then
        local cur_ver
        cur_ver=$("${XRAY_INSTALL_DIR}/xray" version 2>/dev/null | head -1 || echo "")
        if [ -n "$cur_ver" ]; then
            log "  current: $cur_ver"
            # If we want a specific version, check here. With "latest" we
            # always re-download to be safe.
            if [ "${XRAY_VERSION:-latest}" != "latest" ]; then
                # Pinned version: skip if matches
                if echo "$cur_ver" | grep -q "$XRAY_VERSION"; then
                    ok "already at pinned version $XRAY_VERSION"
                    need_install="0"
                fi
            else
                # latest: skip if file exists & is recent (<7 days)
                if [ -n "$(find "${XRAY_INSTALL_DIR}/xray" -mtime -7 2>/dev/null)" ]; then
                    log "  binary < 7d old; skipping re-download (use --only 05-xray to force)"
                    need_install="0"
                fi
            fi
        fi
    fi

    if [ "$need_install" = "1" ]; then
        rm -rf "$XRAY_TMP_DIR"
        mkdir -p "$XRAY_TMP_DIR"

        local url="$XRAY_DOWNLOAD_URL_TEMPLATE"
        if [ "${XRAY_VERSION:-latest}" != "latest" ]; then
            url="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}/Xray-linux-64.zip"
        fi
        log "  fetching: $url"

        if ! curl -fsSL --max-time 120 -o "${XRAY_TMP_DIR}/xray.zip" "$url"; then
            fail "xray binary download failed from $url"
        fi

        require_command unzip || {
            DEBIAN_FRONTEND=noninteractive apt-get install -y -q unzip \
                || fail "unzip install failed"
        }

        unzip -q -o "${XRAY_TMP_DIR}/xray.zip" -d "$XRAY_TMP_DIR" \
            || fail "unzip failed"

        [ -f "${XRAY_TMP_DIR}/xray" ] || fail "xray binary missing in archive"

        mkdir -p "$XRAY_INSTALL_DIR"
        install -m 755 -o root -g root "${XRAY_TMP_DIR}/xray" "${XRAY_INSTALL_DIR}/xray"
        # Optionally install geoip/geosite if shipped in zip
        for asset in geoip.dat geosite.dat; do
            if [ -f "${XRAY_TMP_DIR}/${asset}" ]; then
                install -m 644 -o root -g root "${XRAY_TMP_DIR}/${asset}" \
                    "${XRAY_INSTALL_DIR}/${asset}" || true
            fi
        done

        rm -rf "$XRAY_TMP_DIR"
        ok "xray installed: $("${XRAY_INSTALL_DIR}/xray" version 2>&1 | head -1)"
    fi

    # ----------------------------------------------------------------
    # 2. Directories
    # ----------------------------------------------------------------
    log "2/7 directories"
    mkdir -p "$XRAY_CONFIG_DIR"
    chmod 755 "$XRAY_CONFIG_DIR"
    chown root:root "$XRAY_CONFIG_DIR"

    mkdir -p "$XRAY_LOG_DIR"
    chmod 750 "$XRAY_LOG_DIR"
    chown "$XRAY_SERVICE_USER:$XRAY_SERVICE_GROUP" "$XRAY_LOG_DIR"
    ok "directories ready"

    # ----------------------------------------------------------------
    # 3. Render config.json
    # ----------------------------------------------------------------
    log "3/7 render config.json"
    render_template \
        "${TEMPLATES_DIR}/xray/config.json.tpl" \
        "${XRAY_CONFIG_DIR}/config.json"

    chmod 640 "${XRAY_CONFIG_DIR}/config.json"
    chown "root:${XRAY_SERVICE_GROUP}" "${XRAY_CONFIG_DIR}/config.json"

    # Validate config syntactically before going further
    if ! "${XRAY_INSTALL_DIR}/xray" run -test -config "${XRAY_CONFIG_DIR}/config.json" >/dev/null 2>&1; then
        "${XRAY_INSTALL_DIR}/xray" run -test -config "${XRAY_CONFIG_DIR}/config.json"
        fail "xray config.json failed validation"
    fi
    ok "config.json valid (xray run -test passed)"

    # ----------------------------------------------------------------
    # 4. systemd unit + drop-in
    # ----------------------------------------------------------------
    log "4/7 systemd unit + drop-in"
    render_template \
        "${TEMPLATES_DIR}/systemd/xray.service.tpl" \
        /etc/systemd/system/xray.service
    chmod 644 /etc/systemd/system/xray.service

    mkdir -p /etc/systemd/system/xray.service.d
    render_template \
        "${TEMPLATES_DIR}/systemd/xray.service.d-10-donot_touch_single_conf.conf.tpl" \
        /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf
    chmod 644 /etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf

    systemctl daemon-reload
    ok "systemd unit installed"

    # ----------------------------------------------------------------
    # 5. enable + start
    # ----------------------------------------------------------------
    log "5/7 enable + start xray"
    systemctl enable xray >/dev/null 2>&1 || true

    if systemctl is-active --quiet xray; then
        systemctl restart xray \
            || { journalctl -u xray --no-pager -n 30; fail "xray restart failed"; }
    else
        systemctl start xray \
            || { journalctl -u xray --no-pager -n 30; fail "xray start failed"; }
    fi

    # Wait for listening socket
    local i
    for i in 1 2 3 4 5 6 7 8; do
        if ss -tlnp 2>/dev/null | grep -qE "\[?${XRAY_INBOUND_LISTEN}\]?:${XRAY_INBOUND_PORT}\b"; then
            break
        fi
        sleep 1
    done
    ok "xray service running"

    # ----------------------------------------------------------------
    # 6. Listening verification
    # ----------------------------------------------------------------
    log "6/7 listen verification"
    local listen_line
    listen_line=$(ss -tlnp 2>/dev/null | grep -E "\[?${XRAY_INBOUND_LISTEN}\]?:${XRAY_INBOUND_PORT}\b" | head -1)
    if [ -z "$listen_line" ]; then
        warn "xray not listening on ${XRAY_INBOUND_LISTEN}:${XRAY_INBOUND_PORT}"
        ss -tlnp 2>/dev/null | grep xray | sed 's/^/    /'
        # Possible cause: AWG interface not yet up (handshake pending)
        # For VLESS over fd10::1, the interface MUST be up — but it should be (phase 03 ensured it)
        if ! ip addr show "${AWG_IFACE:-awg0}" 2>/dev/null | grep -q "${XRAY_INBOUND_LISTEN}"; then
            fail "xray cannot bind: ${XRAY_INBOUND_LISTEN} not on interface ${AWG_IFACE:-awg0}"
        fi
        fail "xray not listening; check 'journalctl -u xray'"
    fi
    ok "xray listens: $listen_line"

    # ----------------------------------------------------------------
    # 7. Service runs as expected user
    # ----------------------------------------------------------------
    log "7/7 service user"
    local proc_user
    proc_user=$(ps -C xray -o user= 2>/dev/null | head -1 | tr -d ' ')
    if [ -z "$proc_user" ]; then
        warn "xray process not visible in ps -C"
    elif [ "$proc_user" != "$XRAY_SERVICE_USER" ]; then
        warn "xray runs as '$proc_user', expected '$XRAY_SERVICE_USER'"
    else
        ok "xray running as $proc_user"
    fi

    log_file "[$PHASE_ID] xray up: ${XRAY_INBOUND_LISTEN}:${XRAY_INBOUND_PORT} uuid=${XRAY_CLIENT_UUID}"
    return 0
}