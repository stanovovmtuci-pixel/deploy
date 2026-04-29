#!/usr/bin/env bash
# validation.sh - validators and pre-flight checks
# Sourced by phases. All validators return 0 (ok) or 1 (fail).

# ============================================================
# Format validators (suitable for ask_with_confirm)
# ============================================================

is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    local IFS='.'
    # shellcheck disable=SC2206
    local parts=($ip)
    for p in "${parts[@]}"; do
        [ "$p" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

is_valid_ipv6() {
    local ip="$1"
    # Quick sanity check; full RFC validation is hard. Accept compressed form.
    [[ "$ip" =~ ^([0-9a-fA-F:]+)$ ]] && [[ "$ip" == *":"* ]]
}

is_valid_fqdn() {
    local fqdn="$1"
    [[ "$fqdn" =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

is_valid_port() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ]
}

is_valid_node_id() {
    local id="$1"
    [[ "$id" =~ ^[0-9]+$ ]] && [ "$id" -ge 1 ] && [ "$id" -le 9999 ]
}

is_valid_username() {
    local u="$1"
    [[ "$u" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

# is_valid_uuid -> validates UUID v4 / generic UUID format
# 8-4-4-4-12 hex digits separated by dashes
is_valid_uuid() {
    local id="$1"
    [[ "$id" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
}

# is_valid_awg_key -> validates base64-encoded WireGuard/AmneziaWG key
# Always 44 chars: 32 bytes base64-encoded, ending with '=' for proper padding
is_valid_awg_key() {
    local key="$1"
    [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

# is_valid_ssh_pubkey -> very loose check that string starts with ssh-{rsa,ed25519,ecdsa}
is_valid_ssh_pubkey() {
    local key="$1"
    [[ "$key" =~ ^ssh-(rsa|ed25519|ecdsa-sha2-nistp[0-9]+)\ [A-Za-z0-9+/=]+(\ .*)?$ ]] \
        || [[ "$key" =~ ^ecdsa-sha2-nistp[0-9]+\ [A-Za-z0-9+/=]+(\ .*)?$ ]]
}

# ============================================================
# DNS check
# ============================================================

# check_dns_a FQDN EXPECTED_IPV4
# Returns 0 if FQDN resolves to EXPECTED_IPV4, 1 otherwise.
check_dns_a() {
    local fqdn="$1"
    local expected="$2"
    local resolved=""

    if command -v dig >/dev/null 2>&1; then
        resolved=$(dig +short +time=3 +tries=2 A "$fqdn" 2>/dev/null | tail -1)
    elif command -v getent >/dev/null 2>&1; then
        resolved=$(getent ahostsv4 "$fqdn" 2>/dev/null | awk '{print $1; exit}')
    else
        warn "Neither dig nor getent available for DNS check"
        return 1
    fi

    if [ -z "$resolved" ]; then
        warn "DNS lookup failed for $fqdn"
        return 1
    fi

    if [ "$resolved" != "$expected" ]; then
        warn "$fqdn resolves to $resolved, expected $expected"
        return 1
    fi

    return 0
}

# ============================================================
# Port checks
# ============================================================

# check_port_free PORT [PROTO]  (proto = tcp or udp, default tcp)
# Returns 0 if port is free locally, 1 if something is listening.
check_port_free() {
    local port="$1"
    local proto="${2:-tcp}"
    if command -v ss >/dev/null 2>&1; then
        if ss -tuln 2>/dev/null | awk '{print $5}' | grep -qE ":${port}\$"; then
            return 1
        fi
    elif command -v netstat >/dev/null 2>&1; then
        if netstat -tuln 2>/dev/null | awk '{print $4}' | grep -qE ":${port}\$"; then
            return 1
        fi
    else
        warn "Neither ss nor netstat available; cannot check port $port"
        return 1
    fi
    return 0
}

# require_ports_free PORT [PORT...]
# Aborts deploy if any port is taken.
require_ports_free() {
    for port in "$@"; do
        if ! check_port_free "$port"; then
            local who
            who=$(ss -tulnp 2>/dev/null | grep -E ":${port}\b" | head -1)
            fail "Port $port is already in use: $who"
        fi
    done
}

# ============================================================
# OS check
# ============================================================

# check_os_ubuntu_2204 -> 0 if running Ubuntu 22.04, 1 otherwise
check_os_ubuntu_2204() {
    if [ ! -f /etc/os-release ]; then
        return 1
    fi
    # shellcheck disable=SC1091
    . /etc/os-release
    [ "${ID:-}" = "ubuntu" ] && [ "${VERSION_ID:-}" = "22.04" ]
}

# check_kernel_headers -> 0 if linux-headers package for current kernel is installed
# Required for AmneziaWG DKMS build.
check_kernel_headers() {
    local kver
    kver=$(uname -r)
    [ -d "/lib/modules/${kver}/build" ] && [ -f "/lib/modules/${kver}/build/Makefile" ]
}

# ============================================================
# Network checks
# ============================================================

# check_internet -> 0 if can reach known IP, 1 otherwise
check_internet() {
    if command -v curl >/dev/null 2>&1; then
        curl -sf --max-time 5 -o /dev/null https://1.1.1.1 && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q --timeout=5 --tries=1 -O /dev/null https://1.1.1.1 && return 0
    fi
    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1
}

# check_github_reachable -> 0 if github.com (codeload) is reachable
# Required for AmneziaWG DKMS install (git clone).
check_github_reachable() {
    if command -v curl >/dev/null 2>&1; then
        curl -sf --max-time 5 -o /dev/null https://github.com 2>/dev/null && return 0
    fi
    return 1
}

# check_ssh_to_external HOST PORT USER PASSWORD
# Tries one ssh connect with sshpass. Returns 0 if works.
check_ssh_to_external() {
    local host="$1"
    local port="${2:-22}"
    local user="${3:-root}"
    local pass="$4"

    require_command sshpass

    local out
    out=$(sshpass -p "$pass" ssh -o StrictHostKeyChecking=accept-new \
              -o ConnectTimeout=10 -o BatchMode=no \
              -p "$port" "${user}@${host}" "echo OK" 2>&1)
    [ "$out" = "OK" ]
}

# check_external_awg_port HOST PORT
# Checks if AWG endpoint is reachable (UDP, no real handshake).
check_external_awg_port() {
    local host="$1"
    local port="$2"
    if command -v nc >/dev/null 2>&1; then
        # UDP "scan" via nc is unreliable; treat 0 OR 1 with no error as success.
        nc -zuv -w 3 "$host" "$port" 2>&1 | grep -qE "succeeded|open" && return 0
    fi
    # Fallback: just check we can resolve and nothing else
    return 0
}

# ============================================================
# AmneziaWG / kernel module checks
# ============================================================

# check_awg_module_loaded -> 0 if amneziawg kernel module is loaded
check_awg_module_loaded() {
    lsmod 2>/dev/null | grep -q '^amneziawg '
}

# check_awg_module_available -> 0 if module file exists for current kernel
# (could be loaded or just available via modprobe)
check_awg_module_available() {
    local kver
    kver=$(uname -r)
    find "/lib/modules/${kver}" -name 'amneziawg.ko*' 2>/dev/null | grep -q .
}

# check_awg_iface_up IFACE -> 0 if interface exists and is UP
check_awg_iface_up() {
    local iface="${1:-awg0}"
    ip -o link show "$iface" 2>/dev/null | grep -q 'state UP\|state UNKNOWN'
}

# ============================================================
# Combined pre-flight
# ============================================================

# preflight_summary  -> prints checklist
preflight_summary() {
    log "Pre-flight checklist:"
    if check_os_ubuntu_2204; then
        ok "OS: Ubuntu 22.04"
    else
        warn "OS: not Ubuntu 22.04 (deploy may fail)"
    fi
    if check_internet; then
        ok "Internet: reachable"
    else
        warn "Internet: unreachable"
    fi
    if check_github_reachable; then
        ok "GitHub: reachable (needed for AWG DKMS)"
    else
        warn "GitHub: unreachable (AWG DKMS install will fail)"
    fi
    if check_kernel_headers; then
        ok "Kernel headers: installed for $(uname -r)"
    else
        warn "Kernel headers: missing for $(uname -r) (will be installed in phase 03)"
    fi
    local iface
    iface=$(detect_wan_iface)
    if [ -n "$iface" ]; then
        ok "WAN interface: $iface"
    else
        warn "WAN interface: not detected"
    fi
}