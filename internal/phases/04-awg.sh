#!/usr/bin/env bash
# 04-awg.sh - AmneziaWG tunnel: install, keys exchange, bring up awg0
# Connects to external server via SSH to fetch pubkey and register as peer.

PHASE_ID="04-awg"

run_phase() {
    load_state

    [ -n "${EXTERNAL_IPV6_EP:-}" ]          || fail "EXTERNAL_IPV6_EP not set"
    [ -n "${EXTERNAL_AWG_PORT:-}" ]         || fail "EXTERNAL_AWG_PORT not set"
    [ -n "${EXTERNAL_ROOT_PASSWORD:-}" ]    || fail "EXTERNAL_ROOT_PASSWORD not in env (rerun 00-init)"
    [ -n "${INTERNAL_AWG_LISTEN_PORT:-}" ]  || fail "INTERNAL_AWG_LISTEN_PORT not set"
    [ -n "${AWG_TUN_IPV6_INTERNAL:-}" ]     || fail "AWG_TUN_IPV6_INTERNAL not set"

    command -v sshpass >/dev/null 2>&1 || fail "sshpass not installed (phase 02?)"

    # ----------------------------------------------------------------
    # Backup
    # ----------------------------------------------------------------
    backup_init "$PHASE_ID"
    backup_dir_recursive /etc/amnezia
    backup_file /etc/systemd/system/awg-quick@awg0.service
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. Install AmneziaWG
    # ----------------------------------------------------------------
    log "Installing AmneziaWG..."

    if ! command -v awg >/dev/null 2>&1; then
        # Add Amnezia PPA
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q software-properties-common \
            || fail "failed to install software-properties-common"
        add-apt-repository -y ppa:amnezia/ppa \
            || fail "failed to add amnezia PPA"
        apt-get update -y -q || fail "apt-get update failed"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q amneziawg amneziawg-tools \
            || fail "amneziawg install failed"
    fi

    command -v awg >/dev/null 2>&1 || fail "awg binary still not present after install"
    ok "AmneziaWG installed"

    # ----------------------------------------------------------------
    # 2. Generate our keypair
    # ----------------------------------------------------------------
    log "Generating AWG keypair..."
    mkdir -p /etc/amnezia/amneziawg
    chmod 700 /etc/amnezia/amneziawg

    local priv_file=/etc/amnezia/amneziawg/awg0.priv
    local pub_file=/etc/amnezia/amneziawg/awg0.pub

    if [ ! -f "$priv_file" ]; then
        awg genkey | tee "$priv_file" | awg pubkey > "$pub_file"
        chmod 600 "$priv_file"
        chmod 644 "$pub_file"
    fi

    AWG_PRIV_INTERNAL=$(cat "$priv_file")
    local AWG_PUB_INTERNAL
    AWG_PUB_INTERNAL=$(cat "$pub_file")
    export AWG_PRIV_INTERNAL AWG_PUB_INTERNAL
    save_state AWG_PUB_INTERNAL "$AWG_PUB_INTERNAL"

    ok "keypair generated; pub=$AWG_PUB_INTERNAL"

    # ----------------------------------------------------------------
    # 3. SSH to external, fetch its AWG pubkey
    # ----------------------------------------------------------------
    log "Connecting to external server to fetch AWG pubkey..."

    local ssh_opts="-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=no"

    # Find the AWG config on external. It may live in different paths depending on setup.
    local remote_conf
    remote_conf=$(sshpass -p "$EXTERNAL_ROOT_PASSWORD" ssh $ssh_opts \
        "root@${EXTERNAL_IPV6_EP}" \
        'for p in /etc/amnezia/amneziawg/awg0.conf /opt/amnezia/awg/wg0.conf /etc/wireguard/awg0.conf; do [ -f "$p" ] && echo "$p" && break; done' \
        2>/dev/null)

    if [ -z "$remote_conf" ]; then
        fail "Could not locate AWG config on external server. Is it set up?"
    fi
    ok "external AWG config at: $remote_conf"

    AWG_PUB_EXTERNAL=$(sshpass -p "$EXTERNAL_ROOT_PASSWORD" ssh $ssh_opts \
        "root@${EXTERNAL_IPV6_EP}" \
        "awk '/PrivateKey/{getline; exit}; /^PrivateKey/{print \$3}' $remote_conf 2>/dev/null | head -1 | awg pubkey" \
        2>/dev/null)

    # Fallback: some setups keep only pubkey in a separate file
    if [ -z "$AWG_PUB_EXTERNAL" ] || [ ${#AWG_PUB_EXTERNAL} -lt 40 ]; then
        AWG_PUB_EXTERNAL=$(sshpass -p "$EXTERNAL_ROOT_PASSWORD" ssh $ssh_opts \
            "root@${EXTERNAL_IPV6_EP}" \
            'cat /etc/amnezia/amneziawg/awg0.pub 2>/dev/null || cat /opt/amnezia/awg/wg0.pub 2>/dev/null' \
            2>/dev/null)
    fi

    if [ -z "$AWG_PUB_EXTERNAL" ] || [ ${#AWG_PUB_EXTERNAL} -lt 40 ]; then
        fail "Could not get external's AWG pubkey. Check external server config."
    fi

    export AWG_PUB_EXTERNAL
    save_state AWG_PUB_EXTERNAL "$AWG_PUB_EXTERNAL"
    ok "external AWG pubkey: $AWG_PUB_EXTERNAL"

    # ----------------------------------------------------------------
    # 4. Register ourselves as peer on external
    # ----------------------------------------------------------------
    log "Registering as peer on external server..."

    local peer_block
    peer_block=$(cat <<PEER

[Peer]
# Internal node ${NODE_FQDN}
PublicKey = ${AWG_PUB_INTERNAL}
AllowedIPs = ${AWG_TUN_IPV6_INTERNAL}/128, ${AWG_TUN_IPV4_INTERNAL}/32
PersistentKeepalive = 25
PEER
)

    # Check if peer already exists (idempotency)
    local exists
    exists=$(sshpass -p "$EXTERNAL_ROOT_PASSWORD" ssh $ssh_opts \
        "root@${EXTERNAL_IPV6_EP}" \
        "grep -c '^PublicKey = ${AWG_PUB_INTERNAL}$' $remote_conf 2>/dev/null || echo 0")

    if [ "$exists" = "0" ]; then
        sshpass -p "$EXTERNAL_ROOT_PASSWORD" ssh $ssh_opts \
            "root@${EXTERNAL_IPV6_EP}" \
            "echo '${peer_block}' >> $remote_conf && awg syncconf awg0 <(awg-quick strip awg0) 2>/dev/null || systemctl restart awg-quick@awg0" \
            || fail "failed to add peer on external"
        ok "peer added to external and awg reloaded"
    else
        ok "peer already exists on external (idempotent)"
    fi

    # ----------------------------------------------------------------
    # 5. Render local awg0.conf
    # ----------------------------------------------------------------
    log "Rendering local awg0.conf..."

    render_template \
        "${TEMPLATES_DIR}/configs/awg0.conf.tpl" \
        /etc/amnezia/amneziawg/awg0.conf

    chmod 600 /etc/amnezia/amneziawg/awg0.conf

    # ----------------------------------------------------------------
    # 6. Bring up awg0
    # ----------------------------------------------------------------
    log "Bringing up awg0..."

    systemctl enable awg-quick@awg0 >/dev/null 2>&1 || true

    # Stop in case it's running
    systemctl stop awg-quick@awg0 >/dev/null 2>&1 || true
    sleep 1

    systemctl start awg-quick@awg0 \
        || { journalctl -u awg-quick@awg0 --no-pager -n 30; fail "awg-quick@awg0 start failed"; }

    sleep 3

    # ----------------------------------------------------------------
    # 7. Verify handshake
    # ----------------------------------------------------------------
    log "Verifying tunnel..."
    local handshake
    handshake=$(awg show awg0 latest-handshakes 2>/dev/null | awk '{print $2}')

    if [ -n "$handshake" ] && [ "$handshake" != "0" ]; then
        ok "AWG handshake successful at epoch $handshake"
    else
        warn "No handshake yet; pinging fd10::1 to trigger..."
        if ping -6 -c 3 -W 3 "$AWG_TUN_IPV6_EXTERNAL" >/dev/null 2>&1; then
            ok "ping to $AWG_TUN_IPV6_EXTERNAL works, tunnel up"
        else
            warn "Ping over tunnel failed. Check external peer configuration."
            warn "Output of 'awg show awg0':"
            awg show awg0 2>&1 | head -20
            fail "AWG tunnel not functional"
        fi
    fi

    # Clear external root password from env now that we're done with ssh
    unset EXTERNAL_ROOT_PASSWORD

    return 0
}