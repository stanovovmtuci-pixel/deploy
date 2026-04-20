#!/usr/bin/env bash
# 00-init.sh - interactive parameter collection
# This phase doesn't change the system yet, it only asks questions.
# All answers are saved to /etc/deploy/state.env for subsequent phases.

run_phase() {
    step "Interactive setup for internal node"
    echo

    # ----------------------------------------------------------------
    # 1. Node identity
    # ----------------------------------------------------------------
    log "1/5 Node identity"

    NODE_ID=$(ask_with_confirm "Node ID (number 1-9999)" "1" is_valid_node_id)
    BASE_DOMAIN=$(ask_with_confirm "Base domain (example.com)" "" is_valid_fqdn)
    NODE_FQDN="node${NODE_ID}.${BASE_DOMAIN}"

    log "Node FQDN will be: ${C_CYAN}${NODE_FQDN}${C_RESET}"
    ask_yn "Is this correct?" "y" || fail "Aborted by user"

    ADMIN_USER=$(ask_with_confirm "System admin username" "admin" is_valid_username)

    save_state NODE_ID       "$NODE_ID"
    save_state BASE_DOMAIN   "$BASE_DOMAIN"
    save_state NODE_FQDN     "$NODE_FQDN"
    save_state ADMIN_USER    "$ADMIN_USER"

    export NODE_ID BASE_DOMAIN NODE_FQDN ADMIN_USER

    # ----------------------------------------------------------------
    # 2. External (outbound) server
    # ----------------------------------------------------------------
    echo
    log "2/5 External server (AWG endpoint)"

    EXTERNAL_IPV6_EP=$(ask_with_confirm "External server IPv6 address" "" is_valid_ipv6)
    EXTERNAL_AWG_PORT=$(ask_with_confirm "External AWG port" "51821" is_valid_port)

    log "We will connect to external via SSH to exchange AWG keys."
    log "The password is used once during phase 04 and is not stored."
    EXTERNAL_ROOT_PASSWORD=$(ask_password "External server root password")

    save_state EXTERNAL_IPV6_EP   "$EXTERNAL_IPV6_EP"
    save_state EXTERNAL_AWG_PORT  "$EXTERNAL_AWG_PORT"
    # NOTE: external root password is kept only in memory / env, never on disk
    export EXTERNAL_IPV6_EP EXTERNAL_AWG_PORT EXTERNAL_ROOT_PASSWORD

    # ----------------------------------------------------------------
    # 3. Smart-proxy filtered keyword
    # ----------------------------------------------------------------
    echo
    log "3/5 Smart-proxy configuration"

    log "Clients whose email contains this keyword will be routed via smart-proxy."
    log "Default is 'filtered', but you can pick any word."
    FILTERED_KEYWORD=$(ask_with_confirm "Filtered keyword" "filtered" "")

    save_state FILTERED_KEYWORD "$FILTERED_KEYWORD"
    export FILTERED_KEYWORD

    # ----------------------------------------------------------------
    # 4. fail2ban whitelist wizard
    # ----------------------------------------------------------------
    echo
    log "4/5 fail2ban whitelist"

    local ips_accumulator=""

    # Offer external server
    local ext_v4
    # Try to resolve v4 of the IPv6 external endpoint via reverse -- unlikely,
    # so just add the IPv6 EP itself.
    if ask_yn "Add external server (${EXTERNAL_IPV6_EP}) to whitelist?" "y"; then
        ips_accumulator="${EXTERNAL_IPV6_EP}"
    fi

    # Offer current SSH client
    local ssh_ip
    ssh_ip=$(detect_ssh_client_ip)
    if [ -n "$ssh_ip" ]; then
        if ask_yn "Add current SSH client IP (${ssh_ip}) to whitelist?" "y"; then
            ips_accumulator="${ips_accumulator:+$ips_accumulator }${ssh_ip}"
        fi
    else
        warn "Could not detect SSH client IP (not in SSH session?)"
    fi

    # Manual entries
    while ask_yn "Add another IP to whitelist?" "n"; do
        local extra
        extra=$(ask "IP address (v4 or v6)")
        if [ -n "$extra" ]; then
            ips_accumulator="${ips_accumulator:+$ips_accumulator }${extra}"
        fi
    done

    echo
    log "Final fail2ban whitelist: ${C_CYAN}${ips_accumulator:-<empty>}${C_RESET}"
    if ! ask_yn "Confirm whitelist?" "y"; then
        fail "Aborted by user"
    fi

    F2B_IGNORE_IPS="$ips_accumulator"
    save_state F2B_IGNORE_IPS "$F2B_IGNORE_IPS"
    export F2B_IGNORE_IPS

    # ----------------------------------------------------------------
    # 5. Auto-detected & generated values
    # ----------------------------------------------------------------
    echo
    log "5/5 Auto-detection and generation"

    INTERNAL_IPV4=$(detect_ipv4)
    INTERNAL_IPV6=$(detect_ipv6)
    WAN_IFACE=$(detect_wan_iface)

    [ -n "$INTERNAL_IPV4" ] || fail "Could not detect server IPv4"
    [ -n "$WAN_IFACE" ]     || fail "Could not detect WAN interface"

    ok "WAN interface: $WAN_IFACE"
    ok "Internal IPv4: $INTERNAL_IPV4"
    ok "Internal IPv6: ${INTERNAL_IPV6:-<none>}"

    # Fixed defaults (can be overridden by editing state.env before resume)
    AWG_MTU="${AWG_MTU:-1280}"
    AWG_TUN_IPV6_INTERNAL="${AWG_TUN_IPV6_INTERNAL:-fd10::2}"
    AWG_TUN_IPV6_EXTERNAL="${AWG_TUN_IPV6_EXTERNAL:-fd10::1}"
    AWG_TUN_IPV4_INTERNAL="${AWG_TUN_IPV4_INTERNAL:-10.10.0.2}"
    AWG_TUN_IPV4_EXTERNAL="${AWG_TUN_IPV4_EXTERNAL:-10.10.0.1}"
    SSLH_CAMO_SNI="${SSLH_CAMO_SNI:-yandex.ru}"
    REALITY_DEST="${REALITY_DEST:-yandex.ru:443}"
    X_UI_PANEL_PORT="${X_UI_PANEL_PORT:-2053}"
    X_UI_WEB_BASE="${X_UI_WEB_BASE:-/p4n3l}"

    # Generated values
    INTERNAL_AWG_LISTEN_PORT=$(random_port 30000 60000)
    EXTERNAL_PROXY_PORT=$(random_port 10000 20000)
    EXTERNAL_PROXY_UUID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c 'import uuid;print(uuid.uuid4())')
    PRXY_PANEL_INIT_PASSWORD=$(random_string 24)
    X_UI_ADMIN_USER="admin_$(random_string 6 | tr '[:upper:]' '[:lower:]')"
    X_UI_ADMIN_PASS=$(random_string 20)
    CURRENT_YEAR=$(date +%Y)

    ok "INTERNAL_AWG_LISTEN_PORT: $INTERNAL_AWG_LISTEN_PORT"
    ok "EXTERNAL_PROXY_PORT:      $EXTERNAL_PROXY_PORT"
    ok "EXTERNAL_PROXY_UUID:      $EXTERNAL_PROXY_UUID"
    ok "X_UI_ADMIN_USER:          $X_UI_ADMIN_USER"
    ok "prxy-panel password:      (generated, shown at end)"

    # Save everything
    for var in INTERNAL_IPV4 INTERNAL_IPV6 WAN_IFACE \
               AWG_MTU AWG_TUN_IPV6_INTERNAL AWG_TUN_IPV6_EXTERNAL \
               AWG_TUN_IPV4_INTERNAL AWG_TUN_IPV4_EXTERNAL \
               SSLH_CAMO_SNI REALITY_DEST \
               X_UI_PANEL_PORT X_UI_WEB_BASE \
               INTERNAL_AWG_LISTEN_PORT EXTERNAL_PROXY_PORT EXTERNAL_PROXY_UUID \
               PRXY_PANEL_INIT_PASSWORD X_UI_ADMIN_USER X_UI_ADMIN_PASS \
               CURRENT_YEAR; do
        save_state "$var" "${!var}"
        export "${var?}"
    done

    # AWG private key is generated in phase 04 (requires `awg` binary),
    # AWG public key from external is fetched over SSH in phase 04.

    # ----------------------------------------------------------------
    # Final summary
    # ----------------------------------------------------------------
    echo
    step "Summary"
    cat <<SUMMARY
  Node:              ${C_CYAN}${NODE_FQDN}${C_RESET}
  Admin user:        ${ADMIN_USER}
  External endpoint: [${EXTERNAL_IPV6_EP}]:${EXTERNAL_AWG_PORT}
  Filtered keyword:  ${FILTERED_KEYWORD}
  f2b whitelist:     ${F2B_IGNORE_IPS:-<empty>}
  AWG listen port:   ${INTERNAL_AWG_LISTEN_PORT}
  State saved to:    ${DEPLOY_STATE_FILE}

SUMMARY

    ask_yn "Proceed with deployment?" "y" || fail "Aborted by user"

    return 0
}