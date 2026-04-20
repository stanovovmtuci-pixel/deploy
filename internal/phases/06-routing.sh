#!/usr/bin/env bash
# 06-routing.sh - sslh + nginx + xray inbounds + routing rules
# The longest phase. Assembles the full traffic chain.

PHASE_ID="06-routing"

run_phase() {
    load_state

    [ -n "${NODE_FQDN:-}" ]    || fail "NODE_FQDN not set"
    [ -n "${SSLH_CAMO_SNI:-}" ]|| fail "SSLH_CAMO_SNI not set"
    [ -n "${TEMPLATES_DIR:-}" ]|| fail "TEMPLATES_DIR not set"

    # Reality needs pub/priv derived from xray
    local xray_bin=/usr/local/x-ui/bin/xray-linux-amd64
    [ -x "$xray_bin" ] || xray_bin=$(command -v xray)
    [ -n "$xray_bin" ] && [ -x "$xray_bin" ] || fail "xray binary not found"

    # ----------------------------------------------------------------
    # Backup
    # ----------------------------------------------------------------
    backup_init "$PHASE_ID"
    backup_file /etc/sslh/sslh.cfg
    backup_file /etc/default/sslh
    backup_dir_recursive /etc/nginx
    backup_file /etc/x-ui/x-ui.db
    backup_dir_recursive /var/www
    backup_systemd_state
    ok "backup taken"

    # ----------------------------------------------------------------
    # 1. sslh (TLS multiplexer on :443)
    # ----------------------------------------------------------------
    log "Configuring sslh..."

    # Make sure sslh runs as daemon, not inetd
    sed -i 's/^RUN=.*/RUN=yes/' /etc/default/sslh 2>/dev/null || true

    render_template "${TEMPLATES_DIR}/configs/sslh.cfg.tpl" /etc/sslh/sslh.cfg
    chmod 644 /etc/sslh/sslh.cfg

    # sslh needs to listen on 443, but we run it only after nginx is up on 8443/8444
    systemctl enable sslh >/dev/null 2>&1 || true
    ok "sslh config written"

    # ----------------------------------------------------------------
    # 2. Webroot for NTP camo page
    # ----------------------------------------------------------------
    log "Setting up webroot..."
    mkdir -p "/var/www/${NODE_FQDN}"
    render_template \
        "${TEMPLATES_DIR}/webroot/node-home/index.html" \
        "/var/www/${NODE_FQDN}/index.html"
    chown -R www-data:www-data "/var/www/${NODE_FQDN}"
    ok "webroot at /var/www/${NODE_FQDN}"

    # ----------------------------------------------------------------
    # 3. Full nginx config (replaces bootstrap from 03-ssl)
    # ----------------------------------------------------------------
    log "Rendering full nginx config..."

    # Remove any bootstrap sites
    rm -f /etc/nginx/sites-enabled/acme-bootstrap
    rm -f /etc/nginx/sites-enabled/default

    render_template \
        "${TEMPLATES_DIR}/configs/nginx.conf.tpl" \
        /etc/nginx/nginx.conf

    if ! nginx -t 2>&1; then
        fail "nginx config test failed"
    fi

    systemctl reload nginx || systemctl restart nginx \
        || fail "nginx reload/restart failed"
    ok "nginx running with full config"

    # ----------------------------------------------------------------
    # 4. Generate Reality keypair and fill xrayTemplateConfig
    # ----------------------------------------------------------------
    log "Generating Reality keypair..."

    local reality_out
    reality_out=$("$xray_bin" x25519 2>/dev/null)
    local REALITY_PRIV
    local REALITY_PUB
    REALITY_PRIV=$(echo "$reality_out" | awk '/Private/{print $NF}')
    REALITY_PUB=$(echo  "$reality_out" | awk '/Public/{print $NF}')

    [ -n "$REALITY_PRIV" ] || fail "failed to generate Reality private key"
    [ -n "$REALITY_PUB" ]  || fail "failed to generate Reality public key"

    local REALITY_SHORTID
    REALITY_SHORTID=$(openssl rand -hex 8)

    export REALITY_PRIV REALITY_PUB REALITY_SHORTID
    save_state REALITY_PRIV    "$REALITY_PRIV"
    save_state REALITY_PUB     "$REALITY_PUB"
    save_state REALITY_SHORTID "$REALITY_SHORTID"

    ok "Reality pubkey:  $REALITY_PUB"
    ok "Reality shortid: $REALITY_SHORTID"

    # ----------------------------------------------------------------
    # 5. xrayTemplateConfig.json -> DB
    # ----------------------------------------------------------------
    log "Rendering xrayTemplateConfig..."

    # On first install there are no filtered users yet; use empty array
    export FILTERED_USERS_JSON_ARRAY='[]'

    local rendered_template=/tmp/xrayTemplateConfig.rendered.json
    render_template \
        "${TEMPLATES_DIR}/xray/xrayTemplateConfig.json.tpl" \
        "$rendered_template"

    # Validate JSON
    if ! python3 -c "import json; json.load(open('$rendered_template'))" 2>/dev/null; then
        fail "rendered xrayTemplateConfig is not valid JSON"
    fi

    # Stop x-ui before modifying DB
    systemctl stop x-ui
    sleep 1

    python3 <<PYEOF
import sqlite3, json
db = '/etc/x-ui/x-ui.db'
with open('$rendered_template') as f:
    cfg = f.read()
conn = sqlite3.connect(db)
cur = conn.cursor()
cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'", (cfg,))
if cur.rowcount == 0:
    cur.execute("INSERT INTO settings (key, value) VALUES ('xrayTemplateConfig', ?)", (cfg,))
conn.commit()
conn.close()
print("xrayTemplateConfig written to DB")
PYEOF

    rm -f "$rendered_template"

    # ----------------------------------------------------------------
    # 6. Create standard inbounds (vless-reality, vless-ws, filtered variants)
    # ----------------------------------------------------------------
    log "Creating inbounds..."

    # Default test clients (one per inbound) - admins will add real ones via 3x-ui UI
    local TEST_UUID_RE
    TEST_UUID_RE=$(cat /proc/sys/kernel/random/uuid)
    local TEST_UUID_RF
    TEST_UUID_RF=$(cat /proc/sys/kernel/random/uuid)
    local TEST_UUID_WS
    TEST_UUID_WS=$(cat /proc/sys/kernel/random/uuid)
    local TEST_UUID_WF
    TEST_UUID_WF=$(cat /proc/sys/kernel/random/uuid)

    python3 <<PYEOF
import sqlite3, json, time
db = '/etc/x-ui/x-ui.db'
NODE_FQDN = "$NODE_FQDN"
CAMO = "$SSLH_CAMO_SNI"
REALITY_PRIV = "$REALITY_PRIV"
REALITY_PUB = "$REALITY_PUB"
SHORTID = "$REALITY_SHORTID"
FILTERED_KW = "${FILTERED_KEYWORD}"

conn = sqlite3.connect(db)
cur = conn.cursor()

def ensure_inbound(tag, listen, port, protocol, settings, stream, sniffing):
    row = cur.execute("SELECT id FROM inbounds WHERE tag=?", (tag,)).fetchone()
    now = int(time.time())
    if row:
        cur.execute("""UPDATE inbounds SET listen=?, port=?, protocol=?,
                       settings=?, stream_settings=?, sniffing=?, enable=1
                       WHERE tag=?""",
                    (listen, port, protocol, json.dumps(settings),
                     json.dumps(stream), json.dumps(sniffing), tag))
    else:
        cur.execute("""INSERT INTO inbounds
                       (user_id, up, down, total, remark, enable, expiry_time,
                        listen, port, protocol, settings, stream_settings,
                        tag, sniffing)
                       VALUES (1, 0, 0, 0, ?, 1, 0, ?, ?, ?, ?, ?, ?, ?)""",
                    (tag, listen, port, protocol,
                     json.dumps(settings), json.dumps(stream),
                     tag, json.dumps(sniffing)))

# Reality
reality_settings = {
    "clients": [
        {"id": "$TEST_UUID_RE", "flow": "xtls-rprx-vision", "email": "test-reality"}
    ],
    "decryption": "none"
}
reality_stream = {
    "network": "tcp",
    "security": "reality",
    "realitySettings": {
        "show": False,
        "dest": "${REALITY_DEST}",
        "xver": 0,
        "serverNames": [CAMO, "www."+CAMO],
        "privateKey": REALITY_PRIV,
        "shortIds": [SHORTID]
    }
}
sniffing = {"enabled": True, "destOverride": ["http","tls","quic"]}

ensure_inbound("vless-reality", "0.0.0.0", 10443, "vless", reality_settings, reality_stream, sniffing)

# Reality filtered
reality_settings_f = json.loads(json.dumps(reality_settings))
reality_settings_f["clients"] = [{"id": "$TEST_UUID_RF", "flow": "xtls-rprx-vision",
                                    "email": "test-"+FILTERED_KW+"-reality"}]
ensure_inbound("vless-reality-filtered", "0.0.0.0", 10445, "vless",
               reality_settings_f, reality_stream, sniffing)

# WS
ws_settings = {
    "clients": [{"id": "$TEST_UUID_WS", "email": "test-ws"}],
    "decryption": "none"
}
ws_stream = {"network": "ws", "security": "none",
             "wsSettings": {"path": "/p4n3l2", "headers": {"Host": NODE_FQDN}}}
ensure_inbound("vless-ws", "127.0.0.1", 10444, "vless", ws_settings, ws_stream, sniffing)

# WS filtered
ws_settings_f = json.loads(json.dumps(ws_settings))
ws_settings_f["clients"] = [{"id": "$TEST_UUID_WF", "email": "test-"+FILTERED_KW+"-ws"}]
ensure_inbound("vless-ws-filtered", "127.0.0.1", 10448, "vless",
               ws_settings_f, ws_stream, sniffing)

conn.commit()
conn.close()
print("inbounds created/updated")
PYEOF

    # ----------------------------------------------------------------
    # 7. Install update-xray-routing.sh (discovers filtered clients at runtime)
    # ----------------------------------------------------------------
    log "Installing update-xray-routing.sh..."
    render_template \
        "${TEMPLATES_DIR}/xray/update-xray-routing.sh.tpl" \
        /usr/local/bin/update-xray-routing.sh
    chmod +x /usr/local/bin/update-xray-routing.sh

    # smart-proxy config.json (needed by update-xray-routing.sh for FILTERED_KW)
    mkdir -p /etc/smart-proxy
    render_template \
        "${TEMPLATES_DIR}/configs/smart-proxy-config.json.tpl" \
        /etc/smart-proxy/config.json
    chmod 644 /etc/smart-proxy/config.json

    # Run once to bake initial rules
    /usr/local/bin/update-xray-routing.sh || warn "initial update-xray-routing had issues"

    # ----------------------------------------------------------------
    # 8. Start services in order: x-ui, sslh
    # ----------------------------------------------------------------
    log "Starting services..."

    systemctl start x-ui || fail "x-ui start failed"
    sleep 2
    systemctl is-active --quiet x-ui || fail "x-ui not active"
    ok "x-ui running"

    systemctl restart sslh \
        || { journalctl -u sslh --no-pager -n 20; fail "sslh start failed"; }
    sleep 1
    systemctl is-active --quiet sslh || fail "sslh not active"
    ok "sslh running on :443"

    ok "routing assembled: client -> sslh:443 -> nginx -> xray -> awg -> external"
    return 0
}