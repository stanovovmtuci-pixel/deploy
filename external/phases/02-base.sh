#!/usr/bin/env bash
# 02-base.sh - base system hardening
#
# Idempotent. What it does:
#   - apt update + upgrade safe packages
#   - install base tools (htop, ncdu, nano, dnsutils, jq, curl)
#   - timezone -> UTC
#   - sysctl: IP forwarding, BBR, TCP fastopen
#   - admin user (if not exists, in sudo group)
#   - admin authorized_keys (if ADMIN_PUBKEY non-empty)
#   - sshd hardening via /etc/ssh/sshd_config.d/00-deploy.conf
#   - sudoers cleanup (remove legacy %admin)
#   - fail2ban: install + jail.local + sshd + recidive
#   - iptables-persistent + netfilter-persistent (no rules yet; phase 06 fills)

PHASE_ID="02-base"

BASE_TOOLS=(htop ncdu nano dnsutils jq curl rsync sudo ca-certificates)

run_phase() {
    load_state

    backup_init "$PHASE_ID"
    backup_file /etc/ssh/sshd_config
    backup_dir_recursive /etc/ssh/sshd_config.d
    backup_file /etc/sudoers
    backup_dir_recursive /etc/fail2ban
    backup_file /etc/sysctl.d/99-deploy.conf
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. apt update + base tools
    # ----------------------------------------------------------------
    log "1/9 apt update + base tools"
    DEBIAN_FRONTEND=noninteractive apt-get update -y -q || fail "apt update failed"

    local missing=()
    for t in "${BASE_TOOLS[@]}"; do
        dpkg -s "$t" >/dev/null 2>&1 || missing+=("$t")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        log "  installing: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${missing[@]}" \
            || fail "apt install of base tools failed"
    fi
    ok "base tools present"

    # Safe upgrade (security only — full upgrade is risky during deploy)
    DEBIAN_FRONTEND=noninteractive apt-get -y -q -o Dpkg::Options::="--force-confold" \
        upgrade --with-new-pkgs >/dev/null 2>&1 || warn "apt upgrade reported issues (continuing)"
    ok "apt upgrade pass complete"

    # ----------------------------------------------------------------
    # 2. Timezone -> UTC
    # ----------------------------------------------------------------
    log "2/9 timezone -> UTC"
    if [ "$(timedatectl show -p Timezone --value 2>/dev/null)" != "UTC" ]; then
        timedatectl set-timezone UTC || warn "timedatectl set-timezone UTC failed"
    fi
    ok "timezone: $(timedatectl show -p Timezone --value 2>/dev/null)"

    # ----------------------------------------------------------------
    # 3. sysctl
    # ----------------------------------------------------------------
    log "3/9 sysctl (IP forwarding, BBR, fastopen)"
    render_template \
        "${TEMPLATES_DIR}/configs/sysctl-deploy.conf.tpl" \
        /etc/sysctl.d/99-deploy.conf
    chmod 644 /etc/sysctl.d/99-deploy.conf

    sysctl --system >/dev/null 2>&1 || warn "sysctl --system reported issues"
    # Verify forwarding actually on
    [ "$(sysctl -n net.ipv4.ip_forward)"          = "1" ] || warn "ipv4 forwarding NOT active"
    [ "$(sysctl -n net.ipv6.conf.all.forwarding)" = "1" ] || warn "ipv6 forwarding NOT active"
    ok "sysctl applied"

    # ----------------------------------------------------------------
    # 4. admin user
    # ----------------------------------------------------------------
    log "4/9 admin user"
    [ -n "${ADMIN_USER:-}" ] || fail "ADMIN_USER not set in state"

    if id "$ADMIN_USER" >/dev/null 2>&1; then
        ok "user $ADMIN_USER already exists"
    else
        useradd -m -s /bin/bash "$ADMIN_USER" || fail "useradd failed"
        ok "created user $ADMIN_USER"
    fi

    # Ensure in sudo group
    if id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx sudo; then
        ok "$ADMIN_USER already in sudo group"
    else
        usermod -aG sudo "$ADMIN_USER" || fail "usermod failed"
        ok "added $ADMIN_USER to sudo group"
    fi

    # admin SSH key (optional)
    local admin_home
    admin_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    if [ -n "${ADMIN_PUBKEY:-}" ]; then
        log "  installing authorized_keys for $ADMIN_USER"
        mkdir -p "$admin_home/.ssh"
        chmod 700 "$admin_home/.ssh"
        # Append if not already present
        local ak="$admin_home/.ssh/authorized_keys"
        touch "$ak"
        chmod 600 "$ak"
        if ! grep -qxF "$ADMIN_PUBKEY" "$ak" 2>/dev/null; then
            echo "$ADMIN_PUBKEY" >> "$ak"
            ok "authorized_keys updated"
        else
            ok "authorized_keys already contains the key"
        fi
        chown -R "$ADMIN_USER":"$ADMIN_USER" "$admin_home/.ssh"
    else
        log "  ADMIN_PUBKEY empty, skipping key install (password auth still allowed)"
    fi

    # Lock root password (only if not already locked)
    # Skip on systems where root has explicit pw set by admin
    # passwd -l root  # COMMENTED: too aggressive for default deploy

    ok "admin user configured"

    # ----------------------------------------------------------------
    # 5. sshd hardening (drop-in)
    # ----------------------------------------------------------------
    log "5/9 sshd hardening"
    mkdir -p /etc/ssh/sshd_config.d
    render_template \
        "${TEMPLATES_DIR}/configs/sshd_config-deploy.conf.tpl" \
        /etc/ssh/sshd_config.d/00-deploy.conf
    chmod 644 /etc/ssh/sshd_config.d/00-deploy.conf

    # Validate sshd config before restart
    if ! sshd -t 2>/dev/null; then
        sshd -t  # show error
        fail "sshd config invalid after applying drop-in"
    fi

    systemctl reload ssh 2>/dev/null || systemctl restart ssh || warn "ssh reload/restart failed"
    ok "sshd reloaded"

    # ----------------------------------------------------------------
    # 6. sudoers cleanup
    # ----------------------------------------------------------------
    log "6/9 sudoers cleanup (remove legacy %admin)"
    if grep -q '^%admin ' /etc/sudoers; then
        cp /etc/sudoers /tmp/sudoers.deploy.new
        sed -i '/^%admin /d' /tmp/sudoers.deploy.new
        if visudo -c -f /tmp/sudoers.deploy.new >/dev/null 2>&1; then
            install -m 0440 -o root -g root /tmp/sudoers.deploy.new /etc/sudoers
            ok "removed legacy '%admin ALL=...' line"
        else
            warn "visudo rejected modified sudoers; left original alone"
        fi
        rm -f /tmp/sudoers.deploy.new
    else
        ok "no legacy %admin line in sudoers"
    fi

    # Sanity: admin still has sudo
    if ! sudo -nlU "$ADMIN_USER" 2>/dev/null | grep -q '(ALL'; then
        # Acceptable if admin has password sudo via group; just warn
        log "  note: $ADMIN_USER will need to provide a password for sudo"
    fi

    # ----------------------------------------------------------------
    # 7. fail2ban
    # ----------------------------------------------------------------
    log "7/9 fail2ban"
    if ! dpkg -s fail2ban >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q fail2ban \
            || fail "fail2ban install failed"
    fi

    render_template \
        "${TEMPLATES_DIR}/configs/fail2ban-jail.local.tpl" \
        /etc/fail2ban/jail.local
    chmod 644 /etc/fail2ban/jail.local

    # Validate config before restart
    if ! fail2ban-client -t 2>&1 | grep -qi 'configuration test is successful\|OK'; then
        fail2ban-client -t  # show error
        fail "fail2ban config test failed"
    fi

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban || fail "fail2ban restart failed"

    sleep 2
    if ! systemctl is-active --quiet fail2ban; then
        fail "fail2ban not active after restart"
    fi

    local jails
    jails=$(fail2ban-client status 2>/dev/null | grep 'Jail list:' | sed 's/.*://')
    ok "fail2ban active; jails:$jails"

    # ----------------------------------------------------------------
    # 8. iptables-persistent
    # ----------------------------------------------------------------
    log "8/9 iptables-persistent"
    if ! dpkg -s iptables-persistent >/dev/null 2>&1; then
        # Pre-seed answers so install doesn't prompt
        echo iptables-persistent iptables-persistent/autosave_v4 boolean false | debconf-set-selections
        echo iptables-persistent iptables-persistent/autosave_v6 boolean false | debconf-set-selections
        DEBIAN_FRONTEND=noninteractive apt-get install -y -q iptables-persistent \
            || fail "iptables-persistent install failed"
    fi
    ok "iptables-persistent present"

    # Save current rules so reboot won't drop everything
    mkdir -p /etc/iptables
    iptables-save  > /etc/iptables/rules.v4 2>/dev/null || true
    ip6tables-save > /etc/iptables/rules.v6 2>/dev/null || true
    ok "iptables rules saved (placeholder; phase 06 sets real rules)"

    # ----------------------------------------------------------------
    # 9. unattended-upgrades — minimal sanity (optional)
    # ----------------------------------------------------------------
    log "9/9 unattended-upgrades sanity"
    if dpkg -s unattended-upgrades >/dev/null 2>&1; then
        # Already installed by Ubuntu defaults; just check it's enabled
        systemctl is-enabled --quiet unattended-upgrades 2>/dev/null \
            && ok "unattended-upgrades enabled" \
            || warn "unattended-upgrades not enabled (skipping enable; not critical)"
    else
        log "  unattended-upgrades not installed; skip (admin may install later)"
    fi

    return 0
}