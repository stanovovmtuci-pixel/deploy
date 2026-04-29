#!/usr/bin/env bash
# 09-finalize.sh - finalize deploy: install backup cron, write summary, print next steps
#
# What it does:
#   1. install /etc/cron.d/deploy-backup-cleanup (auto-prune backups > 24h)
#   2. write /etc/deploy/deploy-summary.txt — full record of this run
#   3. print human-readable summary + next steps
#
# This phase makes minimal system changes; rollback is essentially a noop.

PHASE_ID="09-finalize"

run_phase() {
    load_state

    backup_init "$PHASE_ID"
    backup_file /etc/cron.d/deploy-backup-cleanup
    backup_file /etc/deploy/deploy-summary.txt
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. backup cron
    # ----------------------------------------------------------------
    log "1/3 install backup cleanup cron"
    install_backup_cron
    ok "cron at /etc/cron.d/deploy-backup-cleanup"

    # ----------------------------------------------------------------
    # 2. deploy summary file
    # ----------------------------------------------------------------
    log "2/3 write /etc/deploy/deploy-summary.txt"
    mkdir -p /etc/deploy
    chmod 700 /etc/deploy

    local now_iso
    now_iso=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

    local kvers
    kvers=$(ls /lib/modules/ 2>/dev/null | tr '\n' ' ')

    local awg_kver_coverage=""
    for k in $(ls /lib/modules/ 2>/dev/null); do
        if find "/lib/modules/$k" -name 'amneziawg.ko*' 2>/dev/null | grep -q .; then
            awg_kver_coverage="${awg_kver_coverage}${k}=yes "
        else
            awg_kver_coverage="${awg_kver_coverage}${k}=NO "
        fi
    done

    cat > /etc/deploy/deploy-summary.txt <<EOF
================================================================
External-node deploy summary
================================================================
Generated:        ${now_iso}
RUN_ID:           ${RUN_ID}
Hostname:         ${NODE_HOSTNAME:-$(hostname)}
Node ID:          ${NODE_ID:-<unset>}

----------------------------------------------------------------
System
----------------------------------------------------------------
OS:               $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
Current kernel:   $(uname -r)
Installed kernels: ${kvers}
AWG kmod by kernel: ${awg_kver_coverage}

----------------------------------------------------------------
Network
----------------------------------------------------------------
WAN interface:    ${WAN_IFACE:-<unset>}
Public IPv4:      ${PUBLIC_IPV4:-<unset>}
Public IPv6:      ${PUBLIC_IPV6:-<not configured>}

----------------------------------------------------------------
SSH
----------------------------------------------------------------
Port:             ${SSHD_PORT:-22}
Admin user:       ${ADMIN_USER:-<unset>}
Password auth:    ${SSHD_PERMIT_PASSWORD_AUTH:-<unset>}
PermitRootLogin:  ${SSHD_PERMIT_ROOT_LOGIN:-<unset>}
Authorized key:   $([ -n "${ADMIN_PUBKEY:-}" ] && echo "installed" || echo "<none>")

----------------------------------------------------------------
AmneziaWG
----------------------------------------------------------------
Interface:        ${AWG_IFACE:-awg0}
Listen port:      ${AWG_LISTEN_PORT:-<unset>}/udp
Tunnel address:   ${AWG_TUN_IPV6:-<unset>}/${AWG_TUN_IPV6_PREFIX:-64}
MTU:              ${AWG_MTU:-<unset>}
Public key:       ${AWG_PUB_EXTERNAL:-<unset>}
Obfuscation:      Jc=${AWG_OBFUSC_JC:-} Jmin=${AWG_OBFUSC_JMIN:-} Jmax=${AWG_OBFUSC_JMAX:-}
                  S1=${AWG_OBFUSC_S1:-} S2=${AWG_OBFUSC_S2:-}
                  H1=${AWG_OBFUSC_H1:-} H2=${AWG_OBFUSC_H2:-}
                  H3=${AWG_OBFUSC_H3:-} H4=${AWG_OBFUSC_H4:-}
DKMS package:     amneziawg-${AMNEZIAWG_DKMS_VERSION:-1.0.0}
DKMS sources:     /usr/src/amneziawg-${AMNEZIAWG_DKMS_VERSION:-1.0.0}/

----------------------------------------------------------------
Cloudflare WARP
----------------------------------------------------------------
Mode:             proxy
SOCKS5 listen:    127.0.0.1:${WARP_SOCKS5_PORT:-40000}
Registration:     ${WARP_REGISTRATION_MODE:-anonymous}

----------------------------------------------------------------
Xray
----------------------------------------------------------------
Binary:           ${XRAY_INSTALL_DIR:-/usr/local/bin}/xray
Config:           ${XRAY_CONFIG_DIR:-/usr/local/etc/xray}/config.json
Logs:             ${XRAY_LOG_DIR:-/var/log/xray}/
Service user:     ${XRAY_SERVICE_USER:-nobody}:${XRAY_SERVICE_GROUP:-nogroup}
Inbound:          ${XRAY_INBOUND_LISTEN:-fd10::1}:${XRAY_INBOUND_PORT:-<unset>} (${XRAY_INBOUND_TRANSPORT:-tcp})
Inbound UUID:     ${XRAY_CLIENT_UUID:-<unset>}
Outbound:         ${XRAY_OUTBOUND_TAG:-warp-out} -> ${XRAY_OUTBOUND_ADDRESS:-127.0.0.1}:${XRAY_OUTBOUND_PORT:-<unset>}

----------------------------------------------------------------
Firewall
----------------------------------------------------------------
UFW:              $(ufw status 2>/dev/null | head -1 | awk '{print $2}')
Allowed (in):     ${SSHD_PORT:-22}/tcp ssh, ${AWG_LISTEN_PORT:-51821}/udp awg
fail2ban jails:   $(fail2ban-client status 2>/dev/null | grep 'Jail list:' | sed 's/.*://; s/^[ \t]*//')

----------------------------------------------------------------
Paths of interest
----------------------------------------------------------------
Deploy log:       ${DEPLOY_LOG:-/var/log/deploy-external.log}
State:            ${DEPLOY_STATE_FILE:-/etc/deploy/state.env}
Backups:          ${BACKUP_ROOT:-/var/backups/deploy}/${RUN_ID}/
Secrets dir:      ${SECRETS_DIR:-/root/external-deploy-secrets}/
Secrets bundle:   /home/${ADMIN_USER:-admin}/external-deploy-secrets-${RUN_ID}.tar.gz

----------------------------------------------------------------
Next steps
----------------------------------------------------------------
1. Download the secrets bundle to your workstation:
     scp ${ADMIN_USER:-admin}@${PUBLIC_IPV4:-<HOST>}:~/external-deploy-secrets-${RUN_ID}.tar.gz .

2. Add an internal node as AWG peer (run on THIS server):
     sudo /opt/deploy-kit/external/scripts/add-peer.sh \\
         --pubkey '<INTERNAL_AWG_PUB_KEY>' \\
         --allowed 'fd10::2/128'

3. On the internal node, configure xray outbound to:
     address: ${XRAY_INBOUND_LISTEN:-fd10::1}
     port:    ${XRAY_INBOUND_PORT:-<unset>}
     uuid:    ${XRAY_CLIENT_UUID:-<unset>}

4. Test handshake from internal:
     awg show awg0 latest-handshakes
     ping6 ${AWG_TUN_IPV6:-fd10::1}

5. After the bundle is safely on your workstation, wipe server copy:
     sudo rm -f /home/${ADMIN_USER:-admin}/external-deploy-secrets-${RUN_ID}.tar.gz
     sudo rm -f /root/external-deploy-secrets-${RUN_ID}.tar.gz
     sudo rm -rf ${SECRETS_DIR:-/root/external-deploy-secrets}

================================================================
EOF
    chmod 600 /etc/deploy/deploy-summary.txt
    ok "deploy-summary.txt written"

    # ----------------------------------------------------------------
    # 3. Print summary to console
    # ----------------------------------------------------------------
    log "3/3 final summary"
    echo
    step "Deploy complete — external node ready"
    echo
    cat /etc/deploy/deploy-summary.txt
    echo

    log_file "[$PHASE_ID] deploy finalized"
    log_file "[$PHASE_ID] summary at /etc/deploy/deploy-summary.txt"

    return 0
}