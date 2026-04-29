#!/usr/bin/env bash
# add-peer.sh - register a new AmneziaWG peer on this external node.
#
# Usage:
#   sudo ./add-peer.sh \
#       --pubkey   '<base64-public-key>' \
#       --allowed  'fd10::2/128'
#
# Optional:
#   --name           NAME        Comment label for the peer (default: peer-N)
#   --keepalive      SECONDS     PersistentKeepalive (default: 25)
#   --conf           PATH        AWG config path (default: from state.env)
#   --iface          NAME        AWG interface name (default: awg0)
#   --no-reload                  Skip awg syncconf (you'll need to reload manually)
#
# Idempotent: if a peer with the same PublicKey already exists, the script
# replaces its [Peer] block. Backup of original config goes to /var/backups/deploy/.

set -u

# ============================================================
# Locate self / load libs
# ============================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEPLOY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LIB_DIR="${DEPLOY_ROOT}/lib"

# shellcheck source=../lib/common.sh
source "${LIB_DIR}/common.sh"
# shellcheck source=../lib/validation.sh
source "${LIB_DIR}/validation.sh"

# ============================================================
# Defaults
# ============================================================
PEER_PUBKEY=""
PEER_ALLOWED=""
PEER_NAME=""
PEER_KEEPALIVE="25"
AWG_CONF=""
AWG_IFACE_OVERRIDE=""
DO_RELOAD="1"

# ============================================================
# CLI parse
# ============================================================
usage() {
    sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pubkey)         shift; PEER_PUBKEY="${1:-}"     ;;
        --allowed|--allowed-ips) shift; PEER_ALLOWED="${1:-}" ;;
        --name)           shift; PEER_NAME="${1:-}"       ;;
        --keepalive|--persistent-keepalive) shift; PEER_KEEPALIVE="${1:-}" ;;
        --conf)           shift; AWG_CONF="${1:-}"        ;;
        --iface)          shift; AWG_IFACE_OVERRIDE="${1:-}" ;;
        --no-reload)      DO_RELOAD="0"                   ;;
        -h|--help)        usage 0                         ;;
        *)
            echo "ERROR: unknown argument: $1" >&2
            usage 2
            ;;
    esac
    shift
done

# ============================================================
# Validate inputs
# ============================================================
require_root

[ -n "$PEER_PUBKEY"  ] || { echo "ERROR: --pubkey required" >&2; usage 2; }
[ -n "$PEER_ALLOWED" ] || { echo "ERROR: --allowed required" >&2; usage 2; }

if ! is_valid_awg_key "$PEER_PUBKEY"; then
    fail "invalid AWG public key (expected 44-char base64 ending with =)"
fi

if ! [[ "$PEER_KEEPALIVE" =~ ^[0-9]+$ ]]; then
    fail "keepalive must be integer seconds (got: $PEER_KEEPALIVE)"
fi

# ============================================================
# Resolve interface + config path
# ============================================================
load_state

AWG_IFACE_RESOLVED="${AWG_IFACE_OVERRIDE:-${AWG_IFACE:-awg0}}"
AWG_CONF_RESOLVED="${AWG_CONF:-/etc/amnezia/amneziawg/${AWG_IFACE_RESOLVED}.conf}"

[ -f "$AWG_CONF_RESOLVED" ] || fail "AWG config not found: $AWG_CONF_RESOLVED"

# Determine peer name (auto-incremented if not given)
if [ -z "$PEER_NAME" ]; then
    local_n=$(grep -cE '^\[Peer\]' "$AWG_CONF_RESOLVED" 2>/dev/null || echo 0)
    PEER_NAME="peer-$((local_n + 1))"
fi

# ============================================================
# Backup
# ============================================================
BACKUP_DIR="${BACKUP_ROOT:-/var/backups/deploy}/add-peer"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/$(basename "$AWG_CONF_RESOLVED").$(date +%Y%m%d-%H%M%S).bak"
cp -a "$AWG_CONF_RESOLVED" "$BACKUP_FILE"
chmod 600 "$BACKUP_FILE"
ok "backup: $BACKUP_FILE"

# ============================================================
# Idempotency: drop any existing block with same PublicKey
# ============================================================
log "checking for existing peer with this PublicKey..."
if grep -qF "PublicKey = ${PEER_PUBKEY}" "$AWG_CONF_RESOLVED"; then
    warn "peer with same PublicKey already exists; replacing block"
    # Remove from the [Peer] line that contains this PublicKey, until next blank
    # line or end of file. We use awk for clarity.
    awk -v key="$PEER_PUBKEY" '
        BEGIN { in_block = 0 }
        /^\[Peer\]/ {
            # Look ahead to see whether this block contains our key
            block_start_line = NR
            block = $0
            in_peer = 1
            this_key = ""
            next
        }
        in_peer == 1 {
            block = block "\n" $0
            if ($1 == "PublicKey" && $3 == key) this_key = key
            if ($0 ~ /^\[Peer\]/ || $0 ~ /^\[Interface\]/ || NR == 0) {
                in_peer = 0
            }
            # Empty line ends the block
            if ($0 ~ /^[[:space:]]*$/) {
                if (this_key != key) print block
                in_peer = 0
                this_key = ""
                block = ""
            }
            next
        }
        { print }
        END {
            # Flush trailing block if any
            if (in_peer == 1 && this_key != key && block != "") print block
        }
    ' "$AWG_CONF_RESOLVED" > "${AWG_CONF_RESOLVED}.tmp"
    mv "${AWG_CONF_RESOLVED}.tmp" "$AWG_CONF_RESOLVED"
    chmod 600 "$AWG_CONF_RESOLVED"
fi

# ============================================================
# Append new [Peer] block
# ============================================================
log "appending [Peer] block to $AWG_CONF_RESOLVED"

# Ensure trailing newline
[ -n "$(tail -c1 "$AWG_CONF_RESOLVED")" ] && echo "" >> "$AWG_CONF_RESOLVED"

cat >> "$AWG_CONF_RESOLVED" <<EOF

[Peer]
# ${PEER_NAME} (added $(date -u +'%Y-%m-%dT%H:%M:%SZ'))
PublicKey = ${PEER_PUBKEY}
AllowedIPs = ${PEER_ALLOWED}
PersistentKeepalive = ${PEER_KEEPALIVE}
EOF

chmod 600 "$AWG_CONF_RESOLVED"
ok "peer block written"

# ============================================================
# Hot reload via awg syncconf
# ============================================================
if [ "$DO_RELOAD" = "1" ]; then
    log "hot reload via awg syncconf"
    require_command awg
    require_command awg-quick

    # awg syncconf requires a stripped config (no PostUp/PostDown)
    if awg syncconf "$AWG_IFACE_RESOLVED" \
        <(awg-quick strip "$AWG_IFACE_RESOLVED") 2>&1 | grep -vqE '^$'; then
        warn "awg syncconf returned output (probably warning, check above)"
    fi
    ok "config reloaded"
else
    warn "skipped reload (--no-reload); to apply manually:"
    warn "  sudo awg syncconf ${AWG_IFACE_RESOLVED} <(sudo awg-quick strip ${AWG_IFACE_RESOLVED})"
fi

# ============================================================
# Verify peer is registered
# ============================================================
log "verifying peer registration"
if awg show "$AWG_IFACE_RESOLVED" peers 2>/dev/null | grep -qF "$PEER_PUBKEY"; then
    ok "peer ${PEER_NAME} (${PEER_PUBKEY}) registered on ${AWG_IFACE_RESOLVED}"
    log "  AllowedIPs: ${PEER_ALLOWED}"
    log "  Keepalive:  ${PEER_KEEPALIVE}s"
    log ""
    log "  Wait up to 30s, then on the peer side verify handshake:"
    log "    awg show ${AWG_IFACE_RESOLVED} latest-handshakes"
else
    warn "peer not visible in 'awg show $AWG_IFACE_RESOLVED peers' yet"
    warn "  config was updated; reload may be needed:"
    warn "    sudo systemctl restart awg-quick@${AWG_IFACE_RESOLVED}"
fi

exit 0