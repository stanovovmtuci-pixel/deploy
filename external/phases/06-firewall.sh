#!/usr/bin/env bash
# 06-firewall.sh - UFW configuration and persistent iptables baseline
#
# What it does:
#   1. install ufw (if not present)
#   2. reset ufw to clean slate
#   3. set defaults: deny incoming, allow outgoing, allow routed
#   4. allow on lo
#   5. allow ssh (port from state)
#   6. allow AWG port (UDP)
#   7. (optional) allow ssh from current SSH_CLIENT_IP regardless of password auth state
#   8. preview rules; abort if --interactive declined
#   9. enable ufw
#  10. persist iptables (so reboot survives)
#
# Idempotent. UFW reset+reconfigure is fine to re-run.
#
# Notes on architecture:
#   - We do NOT add MASQUERADE for AWG. The chain is
#     internal_client -> internal_xray -> AWG -> external_xray (userspace) -> SOCKS5(WARP).
#     External xray opens NEW outbound connections from its own host, so kernel
#     forwarding/NAT is not on the data path.
#   - Docker is NOT installed by this deploy. No DOCKER-USER chain handling needed.
#   - WARP runs in proxy mode (SOCKS5 on 127.0.0.1:40000) — no kernel routes from WARP.

PHASE_ID="06-firewall"

run_phase() {
    load_state

    [ -n "${SSHD_PORT:-}"        ] || fail "SSHD_PORT not set"
    [ -n "${AWG_LISTEN_PORT:-}"  ] || fail "AWG_LISTEN_PORT not set"
    [ -n "${UFW_ENABLED:-}"      ] || fail "UFW_ENABLED not set"
    [ -n "${UFW_DEFAULT_INCOMING:-}" ] || fail "UFW_DEFAULT_INCOMING not set"
    [ -n "${UFW_DEFAULT_OUTGOING:-}" ] || fail "UFW_DEFAULT_OUTGOING not set"
    [ -n "${UFW_DEFAULT_ROUTED:-}"   ] || fail "UFW_DEFAULT_ROUTED not set"

    backup_init "$PHASE_ID"
    backup_dir_recursive /etc/ufw
    backup_file /etc/iptables/rules.v4
    backup_file /etc/iptables/rules.v6
    backup_iptables
    backup_systemd_state
    ok "backup taken (incl. iptables snapshot)"

    # ----------------------------------------------------------------
    # 1. install ufw
    # ----------------------------------------------------------------
    log "1/8 install ufw"
    if dpkg -s ufw >/dev/null 2>&1; then
        ok "ufw already installed"
    else
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q ufw \
            || fail "ufw install failed"
        ok "ufw installed"
    fi

    # ----------------------------------------------------------------
    # 2. reset to clean slate
    # ----------------------------------------------------------------
    log "2/8 ufw reset (clean slate)"
    ufw --force reset >/dev/null 2>&1 || warn "ufw reset reported issues"
    ok "ufw reset"

    # ----------------------------------------------------------------
    # 3. defaults
    # ----------------------------------------------------------------
    log "3/8 ufw defaults"
    ufw default "$UFW_DEFAULT_INCOMING" incoming >/dev/null 2>&1 || fail "ufw default incoming failed"
    ufw default "$UFW_DEFAULT_OUTGOING" outgoing >/dev/null 2>&1 || fail "ufw default outgoing failed"
    ufw default "$UFW_DEFAULT_ROUTED"  routed   >/dev/null 2>&1 || fail "ufw default routed failed"
    ok "defaults: in=$UFW_DEFAULT_INCOMING out=$UFW_DEFAULT_OUTGOING routed=$UFW_DEFAULT_ROUTED"

    # ----------------------------------------------------------------
    # 4. loopback
    # ----------------------------------------------------------------
    log "4/8 allow loopback"
    ufw allow in on lo >/dev/null 2>&1 || warn "lo allow failed"
    ok "loopback allowed"

    # ----------------------------------------------------------------
    # 5. SSH
    # ----------------------------------------------------------------
    log "5/8 allow SSH on tcp/${SSHD_PORT}"
    ufw allow "${SSHD_PORT}/tcp" comment 'SSH' >/dev/null 2>&1 \
        || fail "ufw allow ssh failed"
    ok "ssh allowed"

    # ----------------------------------------------------------------
    # 6. AWG
    # ----------------------------------------------------------------
    log "6/8 allow AmneziaWG on udp/${AWG_LISTEN_PORT}"
    ufw allow "${AWG_LISTEN_PORT}/udp" comment 'AmneziaWG' >/dev/null 2>&1 \
        || fail "ufw allow awg failed"
    ok "awg allowed"

    # ----------------------------------------------------------------
    # 7. SSH-from-current-client safety net (optional)
    # ----------------------------------------------------------------
    log "7/8 SSH client safety net"
    local ssh_ip
    ssh_ip=$(detect_ssh_client_ip)
    if [ -n "$ssh_ip" ]; then
        # Add specific allow with priority so even if generic allow gets dropped,
        # the current admin doesn't lose access. ufw inserts rules at the start
        # of the user chain in declaration order; since we're allowing all on
        # the SSH port already, this is mostly belt-and-braces.
        log "  current ssh client: $ssh_ip — adding explicit allow"
        ufw allow from "$ssh_ip" to any port "$SSHD_PORT" proto tcp \
            comment "SSH safety: current client" >/dev/null 2>&1 \
            || warn "ssh safety rule add failed (non-fatal)"
        ok "ssh safety net added for $ssh_ip"
    else
        log "  no SSH_CLIENT in env (running locally?); skipping safety net"
    fi

    # ----------------------------------------------------------------
    # 8. preview + enable
    # ----------------------------------------------------------------
    log "8/8 preview + enable"
    log "Rules that will be applied:"
    ufw show added 2>/dev/null | sed 's/^/    /'
    echo

    if [ "$UFW_ENABLED" != "true" ] && [ "$UFW_ENABLED" != "yes" ] && [ "$UFW_ENABLED" != "1" ]; then
        warn "UFW_ENABLED=$UFW_ENABLED in state; rules are configured but firewall stays inactive"
        ok "ufw configured, NOT enabled (per manifest)"
    else
        # Confirm with user UNLESS explicitly --non-interactive
        if [ -z "${DEPLOY_NONINTERACTIVE:-}" ]; then
            warn "Enabling UFW will apply these rules immediately."
            warn "Make sure SSH access ($ssh_ip via tcp/$SSHD_PORT) will still work."
            if ! ask_yn "Enable UFW now?" "y"; then
                warn "User declined; UFW configured but NOT enabled"
                ok "ufw configured, NOT enabled (user choice)"
                _persist_iptables
                return 0
            fi
        fi

        ufw --force enable >/dev/null 2>&1 || {
            ufw status verbose
            fail "ufw enable failed"
        }

        # Verify it's running
        if ufw status 2>&1 | head -1 | grep -qi 'active'; then
            ok "ufw enabled and active"
        else
            ufw status verbose
            fail "ufw not active after enable"
        fi
    fi

    _persist_iptables

    return 0
}

# ============================================================
# Helpers (private to this phase)
# ============================================================

# _persist_iptables -> save current rules to /etc/iptables/rules.{v4,v6}
# so they survive reboot via netfilter-persistent.
_persist_iptables() {
    log "persist iptables to /etc/iptables/"
    mkdir -p /etc/iptables
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null \
        || warn "iptables-save failed"
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null \
        || warn "ip6tables-save failed"
    chmod 640 /etc/iptables/rules.v4 /etc/iptables/rules.v6 2>/dev/null || true

    # Reload netfilter-persistent so it picks up the new file
    if systemctl list-unit-files --no-pager 2>/dev/null | grep -q '^netfilter-persistent\.service'; then
        systemctl restart netfilter-persistent 2>/dev/null \
            || warn "netfilter-persistent restart returned non-zero"
    fi
    ok "iptables persisted"
}