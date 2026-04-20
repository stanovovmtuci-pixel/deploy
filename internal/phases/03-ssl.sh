#!/usr/bin/env bash
# 03-ssl.sh - obtain Let's Encrypt certificate for NODE_FQDN
# Uses certbot --nginx plugin. Requires nginx installed (done in 02-base).

PHASE_ID="03-ssl"

run_phase() {
    load_state

    [ -n "${NODE_FQDN:-}" ]    || fail "NODE_FQDN not set"
    [ -n "${BASE_DOMAIN:-}" ]  || fail "BASE_DOMAIN not set"

    command -v certbot >/dev/null 2>&1 || fail "certbot not installed (phase 02?)"
    command -v nginx   >/dev/null 2>&1 || fail "nginx not installed (phase 02?)"

    # ----------------------------------------------------------------
    # Backup
    # ----------------------------------------------------------------
    backup_init "$PHASE_ID"
    backup_dir_recursive /etc/nginx
    backup_dir_recursive /etc/letsencrypt
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # ACME email
    # ----------------------------------------------------------------
    local acme_email="${ACME_EMAIL:-}"
    if [ -z "$acme_email" ]; then
        local default_email="admin@${BASE_DOMAIN}"
        log "Let's Encrypt needs an email for renewal notifications."
        acme_email=$(ask_default "Email for Let's Encrypt" "$default_email")
        save_state ACME_EMAIL "$acme_email"
    fi

    # ----------------------------------------------------------------
    # Minimal nginx config for ACME http-01 challenge
    # ----------------------------------------------------------------
    log "Deploying minimal nginx for ACME challenge..."

    # Remove any default site that may conflict
    rm -f /etc/nginx/sites-enabled/default

    cat > /etc/nginx/sites-available/acme-bootstrap <<NGINX
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name ${NODE_FQDN};

    root /var/www/html;

    location /.well-known/acme-challenge/ {
        default_type "text/plain";
        root /var/www/certbot;
    }

    location / {
        return 200 'ok';
        add_header Content-Type text/plain;
    }
}
NGINX

    ln -sf /etc/nginx/sites-available/acme-bootstrap /etc/nginx/sites-enabled/acme-bootstrap
    mkdir -p /var/www/certbot

    if ! nginx -t 2>/dev/null; then
        nginx -t
        fail "nginx config test failed (bootstrap)"
    fi

    systemctl reload nginx || systemctl restart nginx || fail "nginx reload failed"
    ok "bootstrap nginx running on :80"

    # ----------------------------------------------------------------
    # Run certbot
    # ----------------------------------------------------------------
    log "Requesting certificate for $NODE_FQDN..."

    local attempts=0
    local max_attempts=3
    local success=0

    while [ "$attempts" -lt "$max_attempts" ]; do
        attempts=$((attempts + 1))
        log "Attempt $attempts/$max_attempts"

        if certbot certonly \
            --nginx \
            --non-interactive \
            --agree-tos \
            --email "$acme_email" \
            --domain "$NODE_FQDN" \
            --rsa-key-size 2048 \
            --no-eff-email \
            --keep-until-expiring 2>&1 | tee -a "$DEPLOY_LOG"
        then
            success=1
            break
        fi

        warn "certbot failed on attempt $attempts"
        if [ "$attempts" -lt "$max_attempts" ]; then
            log "Waiting 15s before retry (DNS propagation etc)..."
            sleep 15
        fi
    done

    if [ "$success" -ne 1 ]; then
        warn "certbot failed $max_attempts times."
        warn "Likely causes:"
        warn "  - DNS A record for $NODE_FQDN not yet propagated"
        warn "  - Port 80 not reachable from Let's Encrypt servers"
        warn "  - Domain already requested too many times (LE rate limit)"
        if ask_yn "Continue WITHOUT SSL cert (phase 06 will fail until cert exists)?" "n"; then
            warn "Proceeding without cert. Run 'sudo ./deploy.sh --from-phase 03-ssl' later."
            return 0
        fi
        fail "certbot failed, deployment aborted"
    fi

    # ----------------------------------------------------------------
    # Verify
    # ----------------------------------------------------------------
    local cert_path="/etc/letsencrypt/live/${NODE_FQDN}/fullchain.pem"
    if [ ! -f "$cert_path" ]; then
        fail "cert file missing at $cert_path after successful certbot?!"
    fi

    local expiry
    expiry=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
    ok "certificate valid, expires: ${expiry:-unknown}"

    # ----------------------------------------------------------------
    # Enable auto-renewal (certbot.timer should already be installed)
    # ----------------------------------------------------------------
    systemctl enable certbot.timer >/dev/null 2>&1 || true
    systemctl start  certbot.timer >/dev/null 2>&1 || true
    if systemctl is-active --quiet certbot.timer; then
        ok "certbot.timer active (auto-renewal enabled)"
    else
        warn "certbot.timer not active -- check manually"
    fi

    # ----------------------------------------------------------------
    # Clean bootstrap nginx (phase 06 writes the real config)
    # ----------------------------------------------------------------
    rm -f /etc/nginx/sites-enabled/acme-bootstrap
    # We keep sites-available/acme-bootstrap for reference but do not enable.

    systemctl reload nginx >/dev/null 2>&1 || true
    ok "bootstrap nginx cleaned; cert ready at $cert_path"

    return 0
}