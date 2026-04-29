#!/usr/bin/env bash
# 04-warp.sh - Cloudflare WARP installation, registration, proxy mode
#
# What it does:
#   1. add Cloudflare apt repo (pkg.cloudflareclient.com)
#   2. install cloudflare-warp
#   3. start warp-svc; wait for daemon
#   4. anonymous registration (warp-cli registration new)
#   5. switch to proxy mode (warp-cli mode proxy)
#   6. set proxy port (default 40000) — listens on 127.0.0.1
#   7. connect (warp-cli connect)
#   8. verify connectivity via SOCKS5
#
# Idempotent. Safe to re-run.

PHASE_ID="04-warp"

CF_REPO_FILE=/etc/apt/sources.list.d/cloudflare-client.list
CF_KEYRING=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg

# Some warp-cli versions keep `--accept-tos` mandatory; we always pass it.
# The flag is harmless on versions that don't require it.
WARP_CLI=(warp-cli --accept-tos)

run_phase() {
    load_state

    [ -n "${WARP_SOCKS5_PORT:-}" ] || fail "WARP_SOCKS5_PORT not set"

    backup_init "$PHASE_ID"
    backup_file "$CF_REPO_FILE"
    backup_file "$CF_KEYRING"
    backup_dir_recursive /var/lib/cloudflare-warp
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. apt repo
    # ----------------------------------------------------------------
    log "1/8 Cloudflare apt repo"
    if [ -f "$CF_REPO_FILE" ] && [ -f "$CF_KEYRING" ]; then
        ok "repo + keyring already present"
    else
        # Add the GPG key
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
            | gpg --dearmor --yes -o "$CF_KEYRING" \
            || fail "failed to fetch/import Cloudflare GPG key"
        chmod 644 "$CF_KEYRING"

        # Determine codename for repo line
        local codename
        codename=$(lsb_release -cs 2>/dev/null || echo "jammy")

        echo "deb [arch=amd64 signed-by=${CF_KEYRING}] https://pkg.cloudflareclient.com/ ${codename} main" \
            > "$CF_REPO_FILE"
        chmod 644 "$CF_REPO_FILE"

        DEBIAN_FRONTEND=noninteractive apt-get update -y -q  >/dev/null 2>&1 || \
            fail "apt update after adding cloudflare repo failed"
        ok "repo + keyring installed (codename: $codename)"
    fi

    # ----------------------------------------------------------------
    # 2. install cloudflare-warp
    # ----------------------------------------------------------------
    log "2/8 install cloudflare-warp"
    if dpkg -s cloudflare-warp >/dev/null 2>&1; then
        ok "cloudflare-warp already installed ($(dpkg -s cloudflare-warp | awk '/^Version:/ {print $2}'))"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q cloudflare-warp \
            || fail "cloudflare-warp install failed"
        ok "cloudflare-warp installed"
    fi

    command -v warp-cli  >/dev/null 2>&1 || fail "warp-cli missing after install"
    command -v warp-svc  >/dev/null 2>&1 || true   # warp-svc may be at /usr/bin/warp-svc

    # ----------------------------------------------------------------
    # 3. warp-svc daemon
    # ----------------------------------------------------------------
    log "3/8 warp-svc daemon"
    systemctl enable warp-svc >/dev/null 2>&1 || true
    if systemctl is-active --quiet warp-svc; then
        ok "warp-svc active"
    else
        systemctl start warp-svc || fail "warp-svc start failed"
        # Daemon takes a moment to be ready
        local i
        for i in 1 2 3 4 5 6 7 8 9 10; do
            if "${WARP_CLI[@]}" status >/dev/null 2>&1; then
                break
            fi
            sleep 1
        done
        if ! systemctl is-active --quiet warp-svc; then
            journalctl -u warp-svc --no-pager -n 30
            fail "warp-svc still not active"
        fi
        ok "warp-svc started"
    fi

    # ----------------------------------------------------------------
    # 4. registration (anonymous)
    # ----------------------------------------------------------------
    log "4/8 anonymous registration"
    # Two CLI dialects exist:
    #   newer:  warp-cli registration new
    #   older:  warp-cli register
    local reg_status
    reg_status=$("${WARP_CLI[@]}" registration show 2>&1 | head -3 || true)

    if echo "$reg_status" | grep -qiE 'account|registration id|token'; then
        ok "already registered"
    else
        if "${WARP_CLI[@]}" registration new </dev/null >/dev/null 2>&1; then
            ok "registered via 'registration new'"
        elif "${WARP_CLI[@]}" register </dev/null >/dev/null 2>&1; then
            ok "registered via legacy 'register'"
        else
            "${WARP_CLI[@]}" registration show 2>&1 | head -10
            fail "warp-cli registration failed (both new/legacy commands)"
        fi
    fi

    # ----------------------------------------------------------------
    # 5. mode = proxy
    # ----------------------------------------------------------------
    log "5/8 mode -> proxy"
    # Newer: warp-cli mode proxy
    # Older: warp-cli set-mode proxy
    if "${WARP_CLI[@]}" mode proxy >/dev/null 2>&1; then
        ok "mode set via 'mode proxy'"
    elif "${WARP_CLI[@]}" set-mode proxy >/dev/null 2>&1; then
        ok "mode set via legacy 'set-mode proxy'"
    else
        "${WARP_CLI[@]}" --help 2>&1 | head -30
        fail "warp-cli could not set mode to 'proxy'"
    fi

    # ----------------------------------------------------------------
    # 6. proxy port
    # ----------------------------------------------------------------
    log "6/8 proxy port -> ${WARP_SOCKS5_PORT}"
    # Newer: warp-cli proxy port <P>
    # Older: warp-cli set-proxy-port <P>
    if "${WARP_CLI[@]}" proxy port "$WARP_SOCKS5_PORT" >/dev/null 2>&1; then
        ok "port set via 'proxy port'"
    elif "${WARP_CLI[@]}" set-proxy-port "$WARP_SOCKS5_PORT" >/dev/null 2>&1; then
        ok "port set via legacy 'set-proxy-port'"
    else
        warn "warp-cli could not set proxy port; default may apply"
    fi

    # ----------------------------------------------------------------
    # 7. connect
    # ----------------------------------------------------------------
    log "7/8 connect"
    "${WARP_CLI[@]}" connect >/dev/null 2>&1 || true
    # Wait until connected
    local i status
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        status=$("${WARP_CLI[@]}" status 2>&1 || true)
        if echo "$status" | grep -qiE 'connected'; then
            break
        fi
        sleep 1
    done
    if ! echo "$status" | grep -qiE 'connected'; then
        warn "warp-cli status did not reach 'Connected' after 12s:"
        echo "$status" | sed 's/^/    /'
        fail "WARP did not connect"
    fi
    ok "WARP connected"

    # ----------------------------------------------------------------
    # 8. verify SOCKS5 works
    # ----------------------------------------------------------------
    log "8/8 verify SOCKS5 on 127.0.0.1:${WARP_SOCKS5_PORT}"
    if ! ss -tlnp 2>/dev/null | grep -qE "127\.0\.0\.1:${WARP_SOCKS5_PORT}\b"; then
        warn "nothing listening on 127.0.0.1:${WARP_SOCKS5_PORT}"
        ss -tlnp 2>/dev/null | grep -E ":[0-9]+\s" | head -10
        fail "WARP SOCKS5 not listening"
    fi
    ok "SOCKS5 socket present"

    # End-to-end: trace through the proxy
    local trace
    trace=$(curl -s --max-time 8 \
        --proxy "socks5h://127.0.0.1:${WARP_SOCKS5_PORT}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)

    if echo "$trace" | grep -q '^warp=on'; then
        ok "end-to-end via WARP proxy: warp=on"
    elif echo "$trace" | grep -q '^warp=plus'; then
        ok "end-to-end via WARP proxy: warp=plus (paid)"
    elif [ -n "$trace" ]; then
        warn "proxy reachable but warp= field missing or off:"
        echo "$trace" | grep -E '^(ip|warp|fl)=' | sed 's/^/    /'
        warn "  (continuing — connectivity works even if WARP is off-path)"
    else
        warn "could not curl through SOCKS5 (network or proxy issue)"
        warn "  trace was empty; deploy will continue but verify manually after"
    fi

    return 0
}