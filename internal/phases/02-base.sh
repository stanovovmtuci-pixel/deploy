#!/usr/bin/env bash
# 02-base.sh - base system setup: packages, user, sshd, UFW, fail2ban, backups
# First phase that actually modifies the system. Extensively backed up.

PHASE_ID="02-base"

run_phase() {
    load_state

    [ -n "${ADMIN_USER:-}" ]      || fail "ADMIN_USER not set (run 00-init first)"
    [ -n "${F2B_IGNORE_IPS:-}" ]  || warn "F2B_IGNORE_IPS is empty"
    [ -n "${TEMPLATES_DIR:-}" ]   || fail "TEMPLATES_DIR not set"

    # ----------------------------------------------------------------
    # Backup
    # ----------------------------------------------------------------
    backup_init "$PHASE_ID"
    backup_file /etc/ssh/sshd_config
    backup_file /etc/fail2ban/jail.local
    backup_dir_recursive /etc/ufw
    backup_dir_recursive /etc/fail2ban
    backup_file /etc/default/ufw
    backup_file /etc/sysctl.conf
    backup_systemd_state
    backup_iptables
    ok "backup taken"

    # Ensure any partial change in this phase triggers rollback via outer deploy.sh
    # (deploy.sh handles failure of run_phase by calling rollback_phase)

    # ----------------------------------------------------------------
    # 1. apt update & base packages
    # ----------------------------------------------------------------
    log "Updating apt cache..."
    DEBIAN_FRONTEND=noninteractive apt-get update -y -q \
        || fail "apt update failed"

    log "Installing base packages..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
        curl wget rsync tar xz-utils \
        sqlite3 \
        python3 python3-pip python3-venv python3-bcrypt \
        nginx \
        sslh \
        certbot python3-certbot-nginx \
        fail2ban \
        ufw \
        openssh-server \
        sshpass \
        openssl \
        iptables \
        dnsutils \
        net-tools iproute2 \
        jq uuid-runtime \
        || fail "apt install failed"
    ok "base packages installed"

    # ----------------------------------------------------------------
    # 2. Admin user
    # ----------------------------------------------------------------
    log "Ensuring admin user $ADMIN_USER..."
    if id "$ADMIN_USER" >/dev/null 2>&1; then
        ok "user $ADMIN_USER already exists"
    else
        # Create user with a random password (home + bash + sudo)
        local user_pass
        user_pass=$(random_string 32)
        useradd -m -s /bin/bash -U "$ADMIN_USER" \
            || fail "useradd failed"
        echo "${ADMIN_USER}:${user_pass}" | chpasswd \
            || fail "failed to set password for $ADMIN_USER"
        usermod -aG sudo "$ADMIN_USER" \
            || fail "failed to add $ADMIN_USER to sudo"

        # Save generated password to state (will be shown in phase 09)
        save_state ADMIN_USER_INITIAL_PASSWORD "$user_pass"
        export ADMIN_USER_INITIAL_PASSWORD="$user_pass"

        ok "created $ADMIN_USER with generated password (shown at end)"
    fi

    # Ensure .ssh dir exists with correct perms (even if user existed before)
    local user_home
    user_home=$(getent passwd "$ADMIN_USER" | cut -d: -f6)
    install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "${user_home}/.ssh"
    touch "${user_home}/.ssh/authorized_keys"
    chmod 600 "${user_home}/.ssh/authorized_keys"
    chown "$ADMIN_USER:$ADMIN_USER" "${user_home}/.ssh/authorized_keys"

    # If current SSH session's root has authorized_keys, copy them over so
    # admin user can log in with the same keys (common expectation).
    if [ -f /root/.ssh/authorized_keys ] && [ -s /root/.ssh/authorized_keys ]; then
        cat /root/.ssh/authorized_keys >> "${user_home}/.ssh/authorized_keys"
        sort -u "${user_home}/.ssh/authorized_keys" -o "${user_home}/.ssh/authorized_keys"
        chown "$ADMIN_USER:$ADMIN_USER" "${user_home}/.ssh/authorized_keys"
        ok "copied root's authorized_keys to $ADMIN_USER"
    fi

    # ----------------------------------------------------------------
    # 3. sshd hardening
    # ----------------------------------------------------------------
    log "Hardening sshd..."
    render_template "${TEMPLATES_DIR}/configs/sshd_config.tpl" /etc/ssh/sshd_config
    chmod 644 /etc/ssh/sshd_config

    # Validate before applying
    if ! sshd -t 2>/dev/null; then
        warn "sshd config invalid, restoring backup"
        cp "${dir:-/var/backups/deploy/${RUN_ID}/${PHASE_ID}}/files/etc_ssh_sshd_config" /etc/ssh/sshd_config 2>/dev/null || true
        fail "sshd config validation failed"
    fi

    # BEFORE restarting ssh, make sure user is warned
    warn "About to restart sshd. Keep a second SSH session open as safety."
    ask_yn "Continue?" "y" || fail "Aborted by user"

    systemctl restart ssh \
        || fail "failed to restart ssh"
    ok "sshd restarted with hardened config"

    # ----------------------------------------------------------------
    # 4. UFW
    # ----------------------------------------------------------------
    log "Configuring UFW..."

    # Reset to known state
    ufw --force reset >/dev/null

    ufw default deny incoming
    ufw default allow outgoing
    ufw default allow routed

    # CRUCIAL: allow SSH BEFORE enabling, or we lose connection
    ufw allow 22/tcp comment 'SSH'
    ufw allow 80/tcp comment 'HTTP/ACME'
    ufw allow 443/tcp comment 'HTTPS (sslh mux)'
    ufw allow in on lo

    # Deny direct access to internal service ports (they are reached via nginx/sslh)
    ufw deny in on "$WAN_IFACE" to any port 2053  comment 'x-ui direct'
    ufw deny in on "$WAN_IFACE" to any port 10443 comment 'xray Reality'
    ufw deny in on "$WAN_IFACE" to any port 10444 comment 'xray WS'
    ufw deny in on "$WAN_IFACE" to any port 7070  comment 'smart-proxy'
    ufw deny in on "$WAN_IFACE" to any port 5001  comment 'prxy-panel'

    # Final safety check + enable
    warn "Enabling UFW now. SSH (22) is allowed."
    ask_yn "Enable UFW?" "y" || fail "Aborted by user"

    ufw --force enable \
        || fail "ufw enable failed"

    ok "UFW enabled"
    ufw status verbose | head -20

    # ----------------------------------------------------------------
    # 5. fail2ban
    # ----------------------------------------------------------------
    log "Configuring fail2ban..."
    render_template "${TEMPLATES_DIR}/configs/fail2ban-jail.local.tpl" /etc/fail2ban/jail.local
    chmod 644 /etc/fail2ban/jail.local

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban \
        || fail "fail2ban restart failed"

    sleep 2
    if fail2ban-client status sshd >/dev/null 2>&1; then
        ok "fail2ban active with sshd jail"
    else
        warn "fail2ban sshd jail not active (check logs)"
    fi

    # ----------------------------------------------------------------
    # 6. Sysctl hardening (conservative -- only enable what we need)
    # ----------------------------------------------------------------
    log "Tuning sysctl..."
    cat > /etc/sysctl.d/99-deploy.conf <<'SYSCTL'
# IP forwarding for AWG tunnel
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# TCP tuning
net.ipv4.tcp_fastopen = 3
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
SYSCTL
    sysctl --system >/dev/null 2>&1 || warn "sysctl reload had warnings"
    ok "sysctl applied"

    # ----------------------------------------------------------------
    # 7. Create deploy log + state dirs
    # ----------------------------------------------------------------
    mkdir -p /var/log /etc/deploy
    chmod 700 /etc/deploy
    touch "$DEPLOY_LOG"
    chmod 600 "$DEPLOY_LOG"
    ok "log and state dirs ready"

    return 0
}