#!/usr/bin/env bash
# 09-finalize.sh - health checks and credentials output
# No backup needed (only reads state and verifies). Final phase.

PHASE_ID="09-finalize"

run_phase() {
    load_state

    # ----------------------------------------------------------------
    # 1. Health checks: systemd services
    # ----------------------------------------------------------------
    log "Running health checks..."

    local services=(ssh nginx sslh x-ui awg-quick@awg0 smart-proxy prxy-panel fail2ban)
    local failed_services=""

    for svc in "${services[@]}"; do
        if systemctl is-active --quiet "$svc"; then
            ok "$svc: active"
        else
            warn "$svc: NOT active"
            failed_services="${failed_services}${svc} "
        fi
    done

    # certbot.timer is a timer, not a service
    if systemctl is-active --quiet certbot.timer; then
        ok "certbot.timer: active (auto-renewal)"
    else
        warn "certbot.timer: not active"
    fi

    # ----------------------------------------------------------------
    # 2. HTTP endpoint checks
    # ----------------------------------------------------------------
    log "Testing HTTP endpoints..."

    # NTP camo page via localhost -> nginx :8444
    if curl -sf -o /dev/null --max-time 5 -k "https://127.0.0.1:8444/" \
        -H "Host: ${NODE_FQDN}"; then
        ok "NTP camo page responds on :8444"
    else
        warn "NTP camo page did not respond on :8444"
    fi

    # prxy-panel
    if curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:5001/prxy/login"; then
        ok "prxy-panel responds on :5001/prxy/"
    else
        warn "prxy-panel did not respond on :5001/prxy/"
    fi

    # 3x-ui
    if curl -sf -o /dev/null --max-time 5 "http://127.0.0.1:${X_UI_PANEL_PORT}${X_UI_WEB_BASE}/"; then
        ok "3x-ui panel responds on :${X_UI_PANEL_PORT}${X_UI_WEB_BASE}/"
    else
        warn "3x-ui panel did not respond (first-load may be slow, try in 10s)"
    fi

    # ----------------------------------------------------------------
    # 3. AWG handshake
    # ----------------------------------------------------------------
    if command -v awg >/dev/null 2>&1; then
        local handshake
        handshake=$(awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2; exit}')
        local now; now=$(date +%s)
        if [ -n "$handshake" ] && [ "$handshake" -gt 0 ] 2>/dev/null; then
            local age=$((now - handshake))
            if [ "$age" -lt 180 ]; then
                ok "AWG tunnel: last handshake ${age}s ago"
            else
                warn "AWG tunnel: last handshake was ${age}s ago (stale, pinging fd10::1)"
                ping -6 -c 1 -W 2 "$AWG_TUN_IPV6_EXTERNAL" >/dev/null 2>&1 \
                    && ok "ping over tunnel OK" \
                    || warn "ping over tunnel FAILED"
            fi
        else
            warn "AWG tunnel: no handshake yet"
        fi
    fi

    # ----------------------------------------------------------------
    # 4. Credentials report
    # ----------------------------------------------------------------
    local summary_file=/root/deploy-summary.txt
    local prxy_pw="${PRXY_PANEL_INIT_PASSWORD:-<cleared, check phase 08 logs>}"
    local admin_initial_pw="${ADMIN_USER_INITIAL_PASSWORD:-<user existed, password not changed>}"

    cat > "$summary_file" <<SUMMARY
=================================================================
DEPLOY SUMMARY -- node ${NODE_FQDN}
Generated: $(date -u +'%Y-%m-%d %H:%M:%S UTC')
RUN_ID:    ${RUN_ID}

KEEP THIS FILE SAFE. The passwords below are shown only here.

-----------------------------------------------------------------
System user
-----------------------------------------------------------------
  Username:           ${ADMIN_USER}
  Initial password:   ${admin_initial_pw}
  SSH:                ssh ${ADMIN_USER}@${INTERNAL_IPV4}

-----------------------------------------------------------------
3x-ui panel (Xray management)
-----------------------------------------------------------------
  URL:                https://${NODE_FQDN}${X_UI_WEB_BASE}/
  Username:           ${X_UI_ADMIN_USER}
  Password:           ${X_UI_ADMIN_PASS}
  Listen (internal):  127.0.0.1:${X_UI_PANEL_PORT}

-----------------------------------------------------------------
prxy-panel (smart-proxy management)
-----------------------------------------------------------------
  URL:                https://${NODE_FQDN}/prxy/
  Username:           admin
  Initial password:   ${prxy_pw}
  Listen (internal):  127.0.0.1:5001

  You can add more users from the 'Admin' tab inside the panel.

-----------------------------------------------------------------
Infrastructure
-----------------------------------------------------------------
  AWG listen port:    ${INTERNAL_AWG_LISTEN_PORT}/udp
  External endpoint:  [${EXTERNAL_IPV6_EP}]:${EXTERNAL_AWG_PORT}
  External proxy:     vless://${EXTERNAL_PROXY_UUID}@[${AWG_TUN_IPV6_EXTERNAL}]:${EXTERNAL_PROXY_PORT}
  Reality pubkey:     ${REALITY_PUB:-<not in state>}
  Reality shortid:    ${REALITY_SHORTID:-<not in state>}
  Filtered keyword:   ${FILTERED_KEYWORD}
  fail2ban whitelist: ${F2B_IGNORE_IPS}

-----------------------------------------------------------------
Operations
-----------------------------------------------------------------
  Deploy log:         /var/log/deploy-internal.log
  Deploy state:       /etc/deploy/state.env
  Backups (24h TTL):  /var/backups/deploy/${RUN_ID}/
  Rollback one phase: sudo ./deploy.sh --rollback PHASE
  Rollback all:       sudo ./deploy.sh --rollback-all

=================================================================
SUMMARY

    chmod 600 "$summary_file"

    # Print to screen, highlighted
    echo
    echo "${C_BOLD}${C_GREEN}======================================================${C_RESET}"
    echo "${C_BOLD}${C_GREEN}  DEPLOYMENT COMPLETE${C_RESET}"
    echo "${C_BOLD}${C_GREEN}======================================================${C_RESET}"
    cat "$summary_file"
    echo
    echo "${C_BOLD}Saved a copy to ${C_CYAN}${summary_file}${C_RESET}${C_BOLD} (mode 600)${C_RESET}"
    echo

    # ----------------------------------------------------------------
    # 5. Final warnings
    # ----------------------------------------------------------------
    if [ -n "$failed_services" ]; then
        warn "Some services are not active: ${failed_services}"
        warn "Check 'journalctl -u <service>' for each of them."
    fi

    # Cleanup sensitive env vars
    unset PRXY_PANEL_INIT_PASSWORD
    unset X_UI_ADMIN_PASS
    unset ADMIN_USER_INITIAL_PASSWORD
    unset EXTERNAL_ROOT_PASSWORD

    # Also remove them from state.env (they're now in /root/deploy-summary.txt)
    sed -i '/^PRXY_PANEL_INIT_PASSWORD=/d' "$DEPLOY_STATE_FILE" 2>/dev/null || true
    sed -i '/^X_UI_ADMIN_PASS=/d' "$DEPLOY_STATE_FILE" 2>/dev/null || true
    sed -i '/^ADMIN_USER_INITIAL_PASSWORD=/d' "$DEPLOY_STATE_FILE" 2>/dev/null || true

    ok "secrets wiped from state.env (copy is in /root/deploy-summary.txt)"

    return 0
}