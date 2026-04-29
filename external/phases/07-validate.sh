#!/usr/bin/env bash
# 07-validate.sh - end-to-end validation of the deploy
#
# READ-ONLY. Verifies that every component installed by previous phases is
# actually working as intended.
#
# Each check is non-fatal individually; failures are accumulated and reported
# at the end. Phase fails only if there are CRITICAL failures (marked accordingly).

PHASE_ID="07-validate"

# Counters for the summary
VAL_OK_COUNT=0
VAL_WARN_COUNT=0
VAL_FAIL_COUNT=0
VAL_CRITICAL_COUNT=0

# ============================================================
# Validation primitives
# ============================================================
v_ok()       { ok       "[$1] $2"; VAL_OK_COUNT=$((VAL_OK_COUNT+1)); }
v_warn()     { warn     "[$1] $2"; VAL_WARN_COUNT=$((VAL_WARN_COUNT+1)); }
v_fail()     { warn     "[$1] FAIL: $2"; VAL_FAIL_COUNT=$((VAL_FAIL_COUNT+1)); }
v_critical() { warn     "[$1] CRITICAL: $2"; VAL_FAIL_COUNT=$((VAL_FAIL_COUNT+1)); VAL_CRITICAL_COUNT=$((VAL_CRITICAL_COUNT+1)); }

run_phase() {
    load_state

    backup_init "$PHASE_ID"
    ok "backup init (read-only phase)"

    log "Running end-to-end validation"
    echo

    # ----------------------------------------------------------------
    # 1. systemd active
    # ----------------------------------------------------------------
    log "1/14 systemd units active"
    local active_units=(ssh fail2ban "awg-quick@${AWG_IFACE:-awg0}" warp-svc xray netfilter-persistent)
    for u in "${active_units[@]}"; do
        if systemctl is-active --quiet "$u"; then
            v_ok "systemd-active" "$u"
        else
            v_critical "systemd-active" "$u is not active"
        fi
    done

    # ----------------------------------------------------------------
    # 2. systemd enabled (will survive reboot)
    # ----------------------------------------------------------------
    log "2/14 systemd units enabled"
    local enabled_units=(ssh fail2ban "awg-quick@${AWG_IFACE:-awg0}" warp-svc xray netfilter-persistent)
    for u in "${enabled_units[@]}"; do
        local state
        state=$(systemctl is-enabled "$u" 2>/dev/null)
        case "$state" in
            enabled|alias|static|enabled-runtime|generated|indirect)
                v_ok "systemd-enabled" "$u ($state)"
                ;;
            *)
                v_warn "systemd-enabled" "$u is '$state' — may not start on reboot"
                ;;
        esac
    done

    # ----------------------------------------------------------------
    # 3. AmneziaWG kernel module
    # ----------------------------------------------------------------
    log "3/14 AmneziaWG kernel module loaded"
    if check_awg_module_loaded; then
        v_ok "kmod" "amneziawg loaded"
    else
        v_critical "kmod" "amneziawg module not loaded"
    fi

    # ----------------------------------------------------------------
    # 4. AWG interface
    # ----------------------------------------------------------------
    log "4/14 AWG interface ${AWG_IFACE:-awg0}"
    local iface="${AWG_IFACE:-awg0}"
    if check_awg_iface_up "$iface"; then
        v_ok "awg-iface" "$iface is UP"
    else
        v_critical "awg-iface" "$iface is DOWN or absent"
    fi

    if [ -n "${AWG_TUN_IPV6:-}" ]; then
        if ip -6 addr show dev "$iface" 2>/dev/null | grep -q "$AWG_TUN_IPV6"; then
            v_ok "awg-addr" "$AWG_TUN_IPV6 on $iface"
        else
            v_critical "awg-addr" "$AWG_TUN_IPV6 not on $iface"
        fi
    fi

    # ----------------------------------------------------------------
    # 5. DKMS coverage for all installed kernels
    # ----------------------------------------------------------------
    log "5/14 DKMS coverage"
    local kvers
    kvers=$(ls /lib/modules/ 2>/dev/null)
    local dkms_missing=0
    for k in $kvers; do
        if find "/lib/modules/$k" -name 'amneziawg.ko*' 2>/dev/null | grep -q .; then
            v_ok "dkms" "amneziawg.ko present for $k"
        else
            v_warn "dkms" "no amneziawg.ko for $k (reboot to $k will break the tunnel)"
            dkms_missing=$((dkms_missing+1))
        fi
    done

    # ----------------------------------------------------------------
    # 6. xray listening
    # ----------------------------------------------------------------
    log "6/14 xray listening"
    local xray_listen="${XRAY_INBOUND_LISTEN:-fd10::1}"
    local xray_port="${XRAY_INBOUND_PORT:-10555}"
    local xray_listen_line
    xray_listen_line=$(ss -tlnp 2>/dev/null \
        | grep -E "\[?${xray_listen}\]?:${xray_port}\b" \
        | head -1)
    if [ -n "$xray_listen_line" ]; then
        v_ok "xray-listen" "${xray_listen}:${xray_port} (xray)"
        # Also check it's NOT running as root
        if echo "$xray_listen_line" | grep -q '"xray"'; then
            v_ok "xray-listen" "process is xray"
        fi
    else
        v_critical "xray-listen" "nothing on ${xray_listen}:${xray_port}"
    fi

    # ----------------------------------------------------------------
    # 7. xray config validation
    # ----------------------------------------------------------------
    log "7/14 xray config syntax"
    local xray_bin="${XRAY_INSTALL_DIR:-/usr/local/bin}/xray"
    local xray_conf="${XRAY_CONFIG_DIR:-/usr/local/etc/xray}/config.json"
    if [ -x "$xray_bin" ] && [ -f "$xray_conf" ]; then
        if "$xray_bin" run -test -config "$xray_conf" >/dev/null 2>&1; then
            v_ok "xray-conf" "valid"
        else
            v_critical "xray-conf" "$xray_conf failed -test"
        fi
    else
        v_warn "xray-conf" "binary or config not present"
    fi

    # ----------------------------------------------------------------
    # 8. WARP status
    # ----------------------------------------------------------------
    log "8/14 WARP status"
    local warp_status
    warp_status=$(warp-cli --accept-tos status 2>/dev/null || echo "")
    if echo "$warp_status" | grep -qiE 'connected'; then
        v_ok "warp-cli" "Connected"
    else
        v_critical "warp-cli" "not connected: $(echo "$warp_status" | head -1)"
    fi

    # ----------------------------------------------------------------
    # 9. WARP SOCKS5 end-to-end
    # ----------------------------------------------------------------
    log "9/14 WARP SOCKS5 end-to-end"
    local warp_port="${WARP_SOCKS5_PORT:-40000}"
    if ss -tlnp 2>/dev/null | grep -qE "127\.0\.0\.1:${warp_port}\b"; then
        v_ok "warp-socks5" "listening on 127.0.0.1:${warp_port}"
    else
        v_critical "warp-socks5" "127.0.0.1:${warp_port} not listening"
    fi

    local trace
    trace=$(curl -s --max-time 8 \
        --proxy "socks5h://127.0.0.1:${warp_port}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
    if echo "$trace" | grep -qE '^warp=(on|plus)'; then
        local warp_field
        warp_field=$(echo "$trace" | grep -E '^warp=' | head -1)
        v_ok "warp-trace" "trace ok ($warp_field)"
    elif [ -n "$trace" ]; then
        v_warn "warp-trace" "warp= field absent or off; proxy works but path may bypass WARP"
    else
        v_warn "warp-trace" "no trace response (network or proxy issue)"
    fi

    # ----------------------------------------------------------------
    # 10. UFW status
    # ----------------------------------------------------------------
    log "10/14 UFW status"
    local ufw_status
    ufw_status=$(ufw status 2>/dev/null | head -1 | awk '{print $2}')
    if [ "${UFW_ENABLED:-true}" = "true" ] || [ "${UFW_ENABLED:-true}" = "yes" ] || [ "${UFW_ENABLED:-true}" = "1" ]; then
        if [ "$ufw_status" = "active" ]; then
            v_ok "ufw" "active"
            # Verify our key allow rules exist
            local rules
            rules=$(ufw status 2>/dev/null)
            for rule in "${SSHD_PORT:-22}/tcp" "${AWG_LISTEN_PORT:-51821}/udp"; do
                if echo "$rules" | grep -qE "^${rule}\\s+ALLOW"; then
                    v_ok "ufw-rule" "$rule allowed"
                else
                    v_fail "ufw-rule" "$rule NOT in allow list"
                fi
            done
        else
            v_critical "ufw" "expected active, got '$ufw_status'"
        fi
    else
        v_ok "ufw" "skipped per UFW_ENABLED=$UFW_ENABLED"
    fi

    # ----------------------------------------------------------------
    # 11. fail2ban jails
    # ----------------------------------------------------------------
    log "11/14 fail2ban jails"
    local jails
    jails=$(fail2ban-client status 2>/dev/null | grep 'Jail list:' | sed 's/.*://; s/,//g')
    for j in sshd recidive; do
        if echo "$jails" | grep -qw "$j"; then
            v_ok "f2b" "jail $j active"
        else
            v_warn "f2b" "jail $j NOT in active list"
        fi
    done

    # ----------------------------------------------------------------
    # 12. sshd config
    # ----------------------------------------------------------------
    log "12/14 sshd config"
    if sshd -t 2>/dev/null; then
        v_ok "sshd-t" "config valid"
    else
        v_critical "sshd-t" "sshd -t failed"
    fi

    # Verify key directives
    local effective
    effective=$(sshd -T 2>/dev/null)
    if echo "$effective" | grep -qiE '^permitrootlogin no\b'; then
        v_ok "sshd-cfg" "PermitRootLogin no"
    else
        v_warn "sshd-cfg" "PermitRootLogin not 'no' (current: $(echo "$effective" | grep -i '^permitrootlogin' | awk '{print $2}'))"
    fi

    # ----------------------------------------------------------------
    # 13. sysctl
    # ----------------------------------------------------------------
    log "13/14 sysctl forwarding"
    [ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null)"          = "1" ] \
        && v_ok "sysctl" "ipv4 forwarding on" \
        || v_warn "sysctl" "ipv4 forwarding NOT on"
    [ "$(sysctl -n net.ipv6.conf.all.forwarding 2>/dev/null)" = "1" ] \
        && v_ok "sysctl" "ipv6 forwarding on" \
        || v_warn "sysctl" "ipv6 forwarding NOT on"

    # ----------------------------------------------------------------
    # 14. Listening ports survey
    # ----------------------------------------------------------------
    log "14/14 listening ports survey"
    local listening
    listening=$(ss -tlnp 2>/dev/null | awk 'NR>1 {print $4}' | sort -u)
    log "  ports listening (TCP):"
    echo "$listening" | sed 's/^/    /'
    local listening_udp
    listening_udp=$(ss -ulnp 2>/dev/null | awk 'NR>1 {print $5}' | sort -u)
    log "  ports listening (UDP):"
    echo "$listening_udp" | sed 's/^/    /'

    # ----------------------------------------------------------------
    # Summary
    # ----------------------------------------------------------------
    echo
    step "Validation summary"
    echo "  OK:        $VAL_OK_COUNT"
    echo "  WARN:      $VAL_WARN_COUNT"
    echo "  FAIL:      $VAL_FAIL_COUNT  (of which CRITICAL: $VAL_CRITICAL_COUNT)"
    echo

    if [ "$VAL_CRITICAL_COUNT" -gt 0 ]; then
        fail "Validation found $VAL_CRITICAL_COUNT critical failure(s); deploy is NOT healthy"
    fi
    if [ "$VAL_FAIL_COUNT" -gt 0 ]; then
        warn "Validation completed with $VAL_FAIL_COUNT non-critical failure(s); review the log"
    fi

    return 0
}