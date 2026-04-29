#!/usr/bin/env bash
# 01-precheck.sh - pre-flight checks before any system changes
#
# Verifies:
#   - OS is Ubuntu 22.04 (warns otherwise)
#   - Internet + GitHub reachability
#   - Kernel headers for DKMS
#   - Required commands available (or installable)
#   - Required ports free
#   - Disk space, RAM
#   - state.env populated by 00-init
#   - No conflicting services running

PHASE_ID="01-precheck"

# Tools we need at *some* phase. Installed-by-this-phase set is small;
# the rest are checked-only and installed in their respective phases.
REQUIRED_NOW=(jq curl awk tar python3)
REQUIRED_LATER=(git make gcc dkms uuidgen openssl iptables ip ss systemctl)

# Disk space minimum (KB) — 2 GiB
DISK_MIN_KB=$((2 * 1024 * 1024))

# RAM minimum (KB) — 900 MiB (some 1GB VPS report 950000)
RAM_MIN_KB=$((900 * 1024))

run_phase() {
    backup_init "$PHASE_ID"
    # No file backup needed — this phase only checks
    ok "backup init (no file changes expected in this phase)"

    load_state

    # ----------------------------------------------------------------
    # 1. OS check
    # ----------------------------------------------------------------
    log "1/10 OS check"
    if check_os_ubuntu_2204; then
        ok "Ubuntu 22.04 confirmed"
    else
        warn "Not Ubuntu 22.04 — deploy is tested only on this version"
        if ! ask_yn "Continue anyway?" "n"; then
            fail "User aborted on non-Ubuntu-22.04 system"
        fi
    fi

    # ----------------------------------------------------------------
    # 2. Internet
    # ----------------------------------------------------------------
    log "2/10 Internet"
    if check_internet; then
        ok "internet reachable (1.1.1.1)"
    else
        fail "no internet — cannot proceed (apt, github, warp register all need network)"
    fi

    # ----------------------------------------------------------------
    # 3. GitHub
    # ----------------------------------------------------------------
    log "3/10 GitHub"
    if check_github_reachable; then
        ok "github.com reachable"
    else
        warn "github.com unreachable; phase 03-amneziawg (DKMS git clone) will fail"
        warn "this is critical — deploy will likely fail at phase 03"
        if ! ask_yn "Continue anyway?" "n"; then
            fail "User aborted on github unreachable"
        fi
    fi

    # ----------------------------------------------------------------
    # 4. Kernel and headers
    # ----------------------------------------------------------------
    log "4/10 Kernel + headers (for DKMS)"
    local kver
    kver=$(uname -r)
    log "  current kernel: $kver"

    if check_kernel_headers; then
        ok "kernel headers present at /lib/modules/${kver}/build"
    else
        warn "kernel headers missing for $kver"
        log "  attempting: apt-get install linux-headers-$kver"
        DEBIAN_FRONTEND=noninteractive apt-get update -y -q  >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "linux-headers-$kver" \
            || fail "could not install linux-headers-$kver"
        if check_kernel_headers; then
            ok "kernel headers installed"
        else
            fail "headers still not detected after apt install — investigate manually"
        fi
    fi

    # ----------------------------------------------------------------
    # 5. Required commands (now)
    # ----------------------------------------------------------------
    log "5/10 Required commands (install now if missing)"
    local missing_now=()
    for cmd in "${REQUIRED_NOW[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_now+=("$cmd")
        fi
    done

    if [ "${#missing_now[@]}" -gt 0 ]; then
        log "  installing: ${missing_now[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -y -q  >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing_now[@]}" \
            || fail "apt install of basic tools failed: ${missing_now[*]}"
        # Re-verify
        for cmd in "${missing_now[@]}"; do
            command -v "$cmd" >/dev/null 2>&1 || fail "still missing after install: $cmd"
        done
    fi
    ok "required-now commands present: ${REQUIRED_NOW[*]}"

    # ----------------------------------------------------------------
    # 6. Required commands (later) — check-only
    # ----------------------------------------------------------------
    log "6/10 Required commands (later phases)"
    local missing_later=()
    for cmd in "${REQUIRED_LATER[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            missing_later+=("$cmd")
        fi
    done
    if [ "${#missing_later[@]}" -gt 0 ]; then
        log "  will be installed in later phases: ${missing_later[*]}"
    else
        ok "all later-phase commands already present"
    fi

    # ----------------------------------------------------------------
    # 7. Required ports free
    # ----------------------------------------------------------------
    log "7/10 Required ports free"
    local awg_port="${AWG_LISTEN_PORT:-51821}"
    local xray_port="${XRAY_INBOUND_PORT:-}"

    if check_port_free "$awg_port"; then
        ok "port $awg_port (AWG) free"
    else
        local who
        who=$(ss -tulnp 2>/dev/null | grep -E ":${awg_port}\b" | head -1)
        warn "port $awg_port already in use: $who"
        if ! ask_yn "AWG port $awg_port is busy. Continue?" "n"; then
            fail "AWG port conflict; pick another via state.env or fix the listener"
        fi
    fi

    if [ -n "$xray_port" ]; then
        if check_port_free "$xray_port"; then
            ok "port $xray_port (xray inbound) free"
        else
            warn "port $xray_port (xray) already in use"
            if ! ask_yn "xray port $xray_port is busy. Continue?" "n"; then
                fail "xray port conflict"
            fi
        fi
    fi

    # ----------------------------------------------------------------
    # 8. Disk space
    # ----------------------------------------------------------------
    log "8/10 Disk space"
    local free_kb
    free_kb=$(df -k / | awk 'NR==2 {print $4}')
    if [ "$free_kb" -lt "$DISK_MIN_KB" ]; then
        warn "low disk: $((free_kb/1024)) MiB free, recommend at least $((DISK_MIN_KB/1024)) MiB"
        if ! ask_yn "Continue with low disk?" "n"; then
            fail "insufficient disk space"
        fi
    else
        ok "disk: $((free_kb/1024)) MiB free on /"
    fi

    # ----------------------------------------------------------------
    # 9. RAM
    # ----------------------------------------------------------------
    log "9/10 RAM"
    local total_kb
    total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)
    if [ "$total_kb" -lt "$RAM_MIN_KB" ]; then
        warn "low RAM: $((total_kb/1024)) MiB total, recommend at least $((RAM_MIN_KB/1024)) MiB"
        warn "  DKMS module build for AmneziaWG may struggle"
        if ! ask_yn "Continue with low RAM?" "n"; then
            fail "insufficient RAM"
        fi
    else
        ok "RAM: $((total_kb/1024)) MiB total"
    fi

    # ----------------------------------------------------------------
    # 10. Conflicting services
    # ----------------------------------------------------------------
    log "10/10 Conflicting services"
    local conflicts=()
    if systemctl is-active --quiet wg-quick@wg0 2>/dev/null; then
        conflicts+=("wg-quick@wg0 (vanilla WireGuard) is active")
    fi
    if systemctl is-active --quiet openvpn-server@server 2>/dev/null; then
        conflicts+=("openvpn-server@server is active")
    fi
    if systemctl is-active --quiet awg-quick@awg0 2>/dev/null; then
        # Not a conflict, but worth noting; deploy will reuse this interface name
        log "  note: awg-quick@awg0 is already active (will be reconfigured in phase 03)"
    fi

    if [ "${#conflicts[@]}" -gt 0 ]; then
        warn "found conflicting services:"
        for c in "${conflicts[@]}"; do
            warn "  - $c"
        done
        if ! ask_yn "Continue (you must resolve conflicts manually before phase 03)?" "n"; then
            fail "Resolve conflicts first, then re-run"
        fi
    else
        ok "no conflicting VPN services running"
    fi

    # ----------------------------------------------------------------
    # State sanity
    # ----------------------------------------------------------------
    log "Verifying state.env was populated by 00-init..."
    local critical=(NODE_ID ADMIN_USER WAN_IFACE PUBLIC_IPV4 AWG_LISTEN_PORT AWG_TUN_IPV6 XRAY_INBOUND_PORT XRAY_CLIENT_UUID)
    local missing_state=()
    for k in "${critical[@]}"; do
        if [ -z "${!k:-}" ]; then
            missing_state+=("$k")
        fi
    done
    if [ "${#missing_state[@]}" -gt 0 ]; then
        warn "state.env missing critical keys: ${missing_state[*]}"
        fail "Run 00-init first, or use 'sudo ./deploy.sh --only 00-init'"
    fi
    ok "state.env has all critical keys"

    log "Pre-flight passed. System is ready for deploy."
    return 0
}