#!/usr/bin/env bash
# 01-precheck.sh - pre-flight validation before making any system changes
# No modifications here, only checks. Hard-fails on critical issues.

run_phase() {
    load_state

    local errors=0
    local warnings=0

    # ----------------------------------------------------------------
    # 1. OS
    # ----------------------------------------------------------------
    log "Checking OS..."
    if check_os_ubuntu_2204; then
        ok "OS is Ubuntu 22.04"
    else
        local os_info=""
        if [ -f /etc/os-release ]; then
            . /etc/os-release
            os_info="${PRETTY_NAME:-unknown}"
        fi
        warn "Expected Ubuntu 22.04, found: $os_info"
        if ! ask_yn "Continue anyway (deployment may fail)?" "n"; then
            fail "Aborted by user"
        fi
        warnings=$((warnings + 1))
    fi

    # ----------------------------------------------------------------
    # 2. Internet
    # ----------------------------------------------------------------
    log "Checking internet connectivity..."
    if check_internet; then
        ok "Internet is reachable"
    else
        fail "No internet connectivity (cannot fetch apt packages or Let's Encrypt)"
    fi

    # ----------------------------------------------------------------
    # 3. Required tools that must be in base Ubuntu 22.04
    # ----------------------------------------------------------------
    log "Checking base tools..."
    for tool in systemctl ip awk sed grep tar curl sqlite3; do
        if command -v "$tool" >/dev/null 2>&1; then
            ok "$tool present"
        else
            if [ "$tool" = "sqlite3" ] || [ "$tool" = "curl" ]; then
                warn "$tool missing (will be installed in phase 02)"
                warnings=$((warnings + 1))
            else
                errors=$((errors + 1))
                warn "$tool missing (unexpected on Ubuntu 22.04)"
            fi
        fi
    done

    # ----------------------------------------------------------------
    # 4. Network: WAN iface + public IP
    # ----------------------------------------------------------------
    log "Checking network..."
    [ -n "$WAN_IFACE" ]     || { errors=$((errors + 1)); warn "WAN_IFACE not set in state"; }
    [ -n "$INTERNAL_IPV4" ] || { errors=$((errors + 1)); warn "INTERNAL_IPV4 not set in state"; }

    # Is INTERNAL_IPV4 actually on our WAN iface?
    if [ -n "$INTERNAL_IPV4" ] && [ -n "$WAN_IFACE" ]; then
        local actual
        actual=$(ip -4 -o addr show dev "$WAN_IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
        if [ "$actual" = "$INTERNAL_IPV4" ]; then
            ok "$INTERNAL_IPV4 is bound to $WAN_IFACE"
        else
            warn "INTERNAL_IPV4=$INTERNAL_IPV4 does not match $WAN_IFACE actual $actual"
            warnings=$((warnings + 1))
        fi
    fi

    # ----------------------------------------------------------------
    # 5. Ports 80 and 443 must be free
    # ----------------------------------------------------------------
    log "Checking ports 80, 443..."
    if check_port_free 80; then
        ok "Port 80 is free"
    else
        warn "Port 80 is in use:"
        ss -tulnp 2>/dev/null | grep -E ":80\b" || true
        fail "Free port 80 before retrying"
    fi
    if check_port_free 443; then
        ok "Port 443 is free"
    else
        warn "Port 443 is in use:"
        ss -tulnp 2>/dev/null | grep -E ":443\b" || true
        fail "Free port 443 before retrying"
    fi

    # ----------------------------------------------------------------
    # 6. DNS check for NODE_FQDN -> INTERNAL_IPV4
    # ----------------------------------------------------------------
    log "Checking DNS for $NODE_FQDN..."
    if command -v dig >/dev/null 2>&1 || command -v getent >/dev/null 2>&1; then
        if check_dns_a "$NODE_FQDN" "$INTERNAL_IPV4"; then
            ok "DNS A record resolves $NODE_FQDN -> $INTERNAL_IPV4"
        else
            warn "DNS A record for $NODE_FQDN does not resolve to $INTERNAL_IPV4"
            warn "This will cause phase 03-ssl to fail."
            warn "You probably need to:"
            warn "  1. Log in to your DNS provider"
            warn "  2. Add an A record: $NODE_FQDN -> $INTERNAL_IPV4"
            warn "  3. Wait for propagation (usually <5 minutes)"
            if ! ask_yn "Continue anyway?" "n"; then
                fail "Aborted. Fix DNS and re-run."
            fi
            warnings=$((warnings + 1))
        fi
    else
        warn "No DNS tool available (dig/getent), skipping DNS check"
        warnings=$((warnings + 1))
    fi

    # ----------------------------------------------------------------
    # 7. External server reachability (SSH)
    # ----------------------------------------------------------------
    log "Checking external server connectivity..."
    # sshpass will be installed in phase 02 if missing, so here we just ping
    if command -v ping >/dev/null 2>&1; then
        if ping -6 -c 1 -W 3 "$EXTERNAL_IPV6_EP" >/dev/null 2>&1; then
            ok "External server $EXTERNAL_IPV6_EP is reachable via IPv6 ping"
        else
            warn "External server not reachable via IPv6 ping (may still work over SSH)"
            warnings=$((warnings + 1))
        fi
    fi

    # ----------------------------------------------------------------
    # 8. Disk space: need at least 2 GB free on /
    # ----------------------------------------------------------------
    log "Checking disk space..."
    local free_kb
    free_kb=$(df --output=avail -k / | tail -1 | tr -d ' ')
    local free_gb=$((free_kb / 1024 / 1024))
    if [ "$free_gb" -ge 2 ]; then
        ok "Free disk space on /: ${free_gb} GB"
    else
        errors=$((errors + 1))
        warn "Only ${free_gb} GB free on /, need at least 2 GB"
    fi

    # ----------------------------------------------------------------
    # Summary
    # ----------------------------------------------------------------
    echo
    if [ "$errors" -gt 0 ]; then
        fail "Pre-check found $errors critical error(s) and $warnings warning(s)"
    fi
    if [ "$warnings" -gt 0 ]; then
        warn "Pre-check passed with $warnings warning(s)"
    else
        ok "All pre-checks passed"
    fi

    return 0
}