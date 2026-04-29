#!/usr/bin/env bash
# 03-amneziawg.sh - AmneziaWG kernel module (via DKMS) + userspace + interface up
#
# Mirrors the workflow we hand-tested on the live FI server:
#   1. apt deps for DKMS build
#   2. git clone amnezia-vpn/amneziawg-linux-kernel-module
#   3. dkms add/build/install -> .ko in /lib/modules/<kver>/updates/dkms/
#   4. ALSO build for any other installed kernels (defense vs. surprise reboot)
#   5. apt install amneziawg-tools (userspace)
#   6. generate keypair (idempotent, from secrets.sh)
#   7. render awg0.conf from template (NO peers; add via scripts/add-peer.sh)
#   8. enable + start awg-quick@awg0
#   9. sanity: interface UP, listening on AWG_LISTEN_PORT

PHASE_ID="03-amneziawg"

AWG_PKG_NAME="amneziawg"
AWG_DKMS_VERSION="${AMNEZIAWG_DKMS_VERSION:-1.0.0}"
AWG_GIT_URL="${AMNEZIAWG_GIT_URL:-https://github.com/amnezia-vpn/amneziawg-linux-kernel-module.git}"
AWG_GIT_REF="${AMNEZIAWG_GIT_REF:-master}"

DKMS_SRC_DIR="/usr/src/${AWG_PKG_NAME}-${AWG_DKMS_VERSION}"
GIT_CLONE_DIR="/tmp/amneziawg-build-$$"

BUILD_DEPS=(build-essential dkms git make gcc)

# amneziawg-tools repository (userspace utilities)
# Pinned to the repo Romario validated on the live server
AWG_TOOLS_GIT_URL="https://github.com/amnezia-vpn/amneziawg-tools.git"
AWG_TOOLS_BUILD_DIR="/tmp/amneziawg-tools-build-$$"

run_phase() {
    load_state

    [ -n "${AWG_IFACE:-}"        ] || fail "AWG_IFACE not set"
    [ -n "${AWG_LISTEN_PORT:-}"  ] || fail "AWG_LISTEN_PORT not set"
    [ -n "${AWG_TUN_IPV6:-}"     ] || fail "AWG_TUN_IPV6 not set"
    [ -n "${AWG_TUN_IPV6_PREFIX:-}" ] || fail "AWG_TUN_IPV6_PREFIX not set"

    backup_init "$PHASE_ID"
    backup_dir_recursive /etc/amnezia
    backup_file "/etc/systemd/system/awg-quick@${AWG_IFACE}.service"
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. Build dependencies
    # ----------------------------------------------------------------
    log "1/9 build deps"
    local missing=()
    for d in "${BUILD_DEPS[@]}"; do
        dpkg -s "$d" >/dev/null 2>&1 || missing+=("$d")
    done

    local kver
    kver=$(uname -r)
    if ! check_kernel_headers; then
        missing+=("linux-headers-$kver")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        log "  installing: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get update -y -q  >/dev/null 2>&1 || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}" \
            || fail "build deps install failed"
    fi
    command -v dkms >/dev/null 2>&1 || fail "dkms not in PATH after install"
    ok "build deps present"

    # ----------------------------------------------------------------
    # 2. Source code (idempotent)
    # ----------------------------------------------------------------
    log "2/9 source code @ ${DKMS_SRC_DIR}"
    if [ -f "${DKMS_SRC_DIR}/dkms.conf" ]; then
        ok "source already at ${DKMS_SRC_DIR} (skipping git clone)"
    else
        rm -rf "$GIT_CLONE_DIR"
        check_github_reachable || fail "github.com unreachable; cannot clone"
        git clone --depth 1 -b "$AWG_GIT_REF" "$AWG_GIT_URL" "$GIT_CLONE_DIR" \
            || fail "git clone failed"

        [ -f "${GIT_CLONE_DIR}/src/dkms.conf" ] \
            || fail "expected dkms.conf in src/ — repo layout changed?"

        # Verify version in dkms.conf matches what we expect (otherwise refuse)
        local repo_ver
        repo_ver=$(grep '^PACKAGE_VERSION=' "${GIT_CLONE_DIR}/src/dkms.conf" | cut -d'"' -f2)
        if [ "$repo_ver" != "$AWG_DKMS_VERSION" ]; then
            warn "dkms.conf says PACKAGE_VERSION=$repo_ver, manifest expected $AWG_DKMS_VERSION"
            warn "  using repo's version: $repo_ver"
            AWG_DKMS_VERSION="$repo_ver"
            DKMS_SRC_DIR="/usr/src/${AWG_PKG_NAME}-${AWG_DKMS_VERSION}"
        fi

        mkdir -p "$DKMS_SRC_DIR"
        cp -r "${GIT_CLONE_DIR}/src/." "$DKMS_SRC_DIR/"
        rm -rf "$GIT_CLONE_DIR"
        ok "source installed to ${DKMS_SRC_DIR}"
    fi

    # ----------------------------------------------------------------
    # 3. DKMS register
    # ----------------------------------------------------------------
    log "3/9 dkms add"
    if dkms status -m "$AWG_PKG_NAME" -v "$AWG_DKMS_VERSION" 2>/dev/null | grep -q .; then
        ok "already registered in DKMS"
    else
        dkms add -m "$AWG_PKG_NAME" -v "$AWG_DKMS_VERSION" \
            || fail "dkms add failed"
    fi

    # ----------------------------------------------------------------
    # 4. DKMS build + install for current kernel
    # ----------------------------------------------------------------
    log "4/9 dkms build + install for current kernel ($kver)"
    if dkms status -m "$AWG_PKG_NAME" -v "$AWG_DKMS_VERSION" -k "$kver" 2>/dev/null \
        | grep -q 'installed'; then
        ok "module already installed for $kver"
    else
        dkms build   -m "$AWG_PKG_NAME" -v "$AWG_DKMS_VERSION" -k "$kver" \
            || fail "dkms build failed for $kver"
        dkms install -m "$AWG_PKG_NAME" -v "$AWG_DKMS_VERSION" -k "$kver" \
            || fail "dkms install failed for $kver"
        ok "module installed for $kver"
    fi

    # ----------------------------------------------------------------
    # 5. ALSO build for any other installed kernels
    #    (so a surprise reboot to a different kernel does not break the tunnel)
    # ----------------------------------------------------------------
    log "5/9 dkms build for other installed kernels (defense)"
    local other_kvers
    other_kvers=$(ls /lib/modules/ 2>/dev/null | grep -v "^${kver}$" || true)
    if [ -n "$other_kvers" ]; then
        for k in $other_kvers; do
            if [ ! -d "/lib/modules/$k/build" ]; then
                log "  $k: no build/ -> install linux-headers-$k"
                DEBIAN_FRONTEND=noninteractive apt-get install -y -q "linux-headers-$k" >/dev/null 2>&1 \
                    || { warn "  could not install headers for $k; skipping"; continue; }
            fi
            if dkms status -m "$AWG_PKG_NAME" -v "$AWG_DKMS_VERSION" -k "$k" 2>/dev/null \
                | grep -q 'installed'; then
                log "  $k: already installed"
            else
                dkms build   -m "$AWG_PKG_NAME" -v "$AWG_DKMS_VERSION" -k "$k" >/dev/null 2>&1 \
                    && dkms install -m "$AWG_PKG_NAME" -v "$AWG_DKMS_VERSION" -k "$k" >/dev/null 2>&1 \
                    && ok "  $k: installed" \
                    || warn "  $k: build/install failed"
            fi
        done
    else
        log "  only one kernel installed ($kver); nothing extra to build"
    fi

    # Verify .ko files exist
    if ! check_awg_module_available; then
        fail "amneziawg.ko NOT found in /lib/modules/$kver/ after install"
    fi
    ok "amneziawg.ko present for current kernel"

    # ----------------------------------------------------------------
    # 6. Load module
    # ----------------------------------------------------------------
    log "6/9 modprobe amneziawg"
    if check_awg_module_loaded; then
        ok "module already loaded"
    else
        modprobe amneziawg || fail "modprobe amneziawg failed"
        ok "module loaded"
    fi

    # ----------------------------------------------------------------
    # 7. Userspace tools (awg, awg-quick)
    #    These are NOT part of the kernel-module repo. Build from
    #    amneziawg-tools repo, install to /usr/bin.
    # ----------------------------------------------------------------
    log "7/9 amneziawg userspace tools"
    if command -v awg >/dev/null 2>&1 && command -v awg-quick >/dev/null 2>&1; then
        ok "awg and awg-quick already installed"
    else
        rm -rf "$AWG_TOOLS_BUILD_DIR"
        git clone --depth 1 "$AWG_TOOLS_GIT_URL" "$AWG_TOOLS_BUILD_DIR" \
            || fail "git clone amneziawg-tools failed"

        # Build & install (Makefile in src/)
        if [ -f "${AWG_TOOLS_BUILD_DIR}/src/Makefile" ]; then
            make -C "${AWG_TOOLS_BUILD_DIR}/src" -j"$(nproc)" \
                || fail "amneziawg-tools build failed"
            make -C "${AWG_TOOLS_BUILD_DIR}/src" install \
                || fail "amneziawg-tools install failed"
        else
            fail "amneziawg-tools repo layout unexpected (no src/Makefile)"
        fi
        rm -rf "$AWG_TOOLS_BUILD_DIR"
    fi
    command -v awg       >/dev/null 2>&1 || fail "awg still not in PATH"
    command -v awg-quick >/dev/null 2>&1 || fail "awg-quick still not in PATH"
    ok "awg/awg-quick installed"

    # ----------------------------------------------------------------
    # 8. Keypair + config render
    # ----------------------------------------------------------------
    log "8/9 keypair + awg0.conf"

    # Generate keypair (idempotent — uses SECRETS_DIR)
    generate_awg_keypair

    # Both AWG_PRIV_EXTERNAL and AWG_PUB_EXTERNAL are now in env
    [ -n "${AWG_PRIV_EXTERNAL:-}" ] || fail "AWG_PRIV_EXTERNAL not set after generate"
    [ -n "${AWG_PUB_EXTERNAL:-}"  ] || fail "AWG_PUB_EXTERNAL not set after generate"

    mkdir -p /etc/amnezia/amneziawg
    chmod 700 /etc/amnezia/amneziawg

    render_template \
        "${TEMPLATES_DIR}/configs/awg0.conf.tpl" \
        "/etc/amnezia/amneziawg/${AWG_IFACE}.conf"

    chmod 600 "/etc/amnezia/amneziawg/${AWG_IFACE}.conf"
    ok "awg0.conf rendered (no peers — add via scripts/add-peer.sh)"

    # ----------------------------------------------------------------
    # 9. Enable + start interface
    # ----------------------------------------------------------------
    log "9/9 awg-quick@${AWG_IFACE}"
    systemctl enable "awg-quick@${AWG_IFACE}" >/dev/null 2>&1 || true

    # If running, restart for clean state; otherwise start
    if systemctl is-active --quiet "awg-quick@${AWG_IFACE}"; then
        systemctl restart "awg-quick@${AWG_IFACE}" \
            || { journalctl -u "awg-quick@${AWG_IFACE}" --no-pager -n 30; fail "awg restart failed"; }
    else
        systemctl start "awg-quick@${AWG_IFACE}" \
            || { journalctl -u "awg-quick@${AWG_IFACE}" --no-pager -n 30; fail "awg start failed"; }
    fi

    sleep 2

    if ! check_awg_iface_up "$AWG_IFACE"; then
        fail "interface ${AWG_IFACE} not up after start"
    fi

    # Verify address is assigned
    if ! ip -6 addr show dev "$AWG_IFACE" 2>/dev/null | grep -q "$AWG_TUN_IPV6"; then
        fail "address $AWG_TUN_IPV6 not on $AWG_IFACE"
    fi

    ok "${AWG_IFACE} up; addr=${AWG_TUN_IPV6}/${AWG_TUN_IPV6_PREFIX}; pub=${AWG_PUB_EXTERNAL}"
    log_file "[$PHASE_ID] AWG up: ${AWG_IFACE} ${AWG_TUN_IPV6}/${AWG_TUN_IPV6_PREFIX} pub=${AWG_PUB_EXTERNAL}"

    return 0
}