#!/bin/bash
DB="/etc/x-ui/x-ui.db"
LOG="/var/log/xray-routing-update.log"
SP_CONFIG="/etc/smart-proxy/config.json"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

# read filtered keyword from smart-proxy config
FILTERED_KW=$(python3 -c "import json; print(json.load(open('$SP_CONFIG')).get('filtered_keyword','filtered'))")

python3 - <<PYEOF
import json, sqlite3, sys

FILTERED_KW = "$FILTERED_KW"
db_path = '/etc/x-ui/x-ui.db'
conn = sqlite3.connect(db_path)
cur = conn.cursor()

cur.execute("SELECT tag, settings FROM inbounds")
rows = cur.fetchall()
filtered_emails = []
for tag, s in rows:
    try:
        for c in json.loads(s).get('clients', []):
            e = c.get('email', '')
            if FILTERED_KW in e:
                filtered_emails.append(e)
    except Exception:
        pass
filtered_emails = sorted(set(filtered_emails))

filtered_tags = ["vless-reality-filtered", "vless-ws-filtered"]

new_rules = [
    {"type":"field","inboundTag":["api"],"outboundTag":"api"},
    {"type":"field","inboundTag":["smart-proxy-in"],"outboundTag":"external-proxy"},
    {"type":"field","outboundTag":"blocked","ip":["geoip:private"]},
    {"type":"field","outboundTag":"blocked","protocol":["bittorrent"]},
    {"type":"field","network":"tcp,udp","port":"53","outboundTag":"direct"},
    {"type":"field","user":filtered_emails,"network":"tcp,udp","outboundTag":"smart-proxy-out"},
    {"type":"field","inboundTag":filtered_tags,"network":"tcp,udp","outboundTag":"smart-proxy-out"},
    {"type":"field","inboundTag":["inbound-10443","inbound-127.0.0.1:10444"],"outboundTag":"external-proxy"},
    {"type":"field","network":"tcp,udp","outboundTag":"external-proxy"}
]

cur.execute("SELECT value FROM settings WHERE key='xrayTemplateConfig'")
template = json.loads(cur.fetchone()[0])
template["routing"]["rules"] = new_rules
cur.execute("UPDATE settings SET value=? WHERE key='xrayTemplateConfig'",
    (json.dumps(template, indent=2, ensure_ascii=False),))
conn.commit()
conn.close()
print("Rules: " + str(len(new_rules)) + ", filtered users: " + str(len(filtered_emails)))
PYEOF

if [ $? -eq 0 ]; then
    systemctl restart x-ui
    log "x-ui restarted with updated routing (keyword=$FILTERED_KW)"
else
    log "ERROR: routing update failed"
fi
