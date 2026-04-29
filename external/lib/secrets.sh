#!/usr/bin/env bash
# secrets.sh - generation of AWG keypairs, xray UUIDs, and secret persistence
# Sourced by phases. Requires awg, uuidgen, openssl in $PATH (deps installed in phase 02/03).

# SECRETS_DIR - where generated secrets are persisted (also used by 09-finalize for export)
SECRETS_DIR="${SECRETS_DIR:-${DEPLOY_SECRETS_DIR:-/root/external-deploy-secrets}}"

# ============================================================
# Internal helpers
# ============================================================

_secrets_init_dir() {
    mkdir -p "$SECRETS_DIR"
    chmod 700 "$SECRETS_DIR"
}

# _secret_save NAME VALUE -> writes value to $SECRETS_DIR/NAME with 600 perms
_secret_save() {
    local name="$1"
    local value="$2"
    _secrets_init_dir
    local path="${SECRETS_DIR}/${name}"
    printf '%s' "$value" > "$path"
    chmod 600 "$path"
}

# _secret_load NAME -> echoes value from $SECRETS_DIR/NAME (empty if absent)
_secret_load() {
    local name="$1"
    local path="${SECRETS_DIR}/${name}"
    [ -f "$path" ] && cat "$path" || echo ""
}

# _secret_exists NAME -> returns 0 if file exists and non-empty
_secret_exists() {
    local name="$1"
    local path="${SECRETS_DIR}/${name}"
    [ -s "$path" ]
}

# ============================================================
# AmneziaWG keypair
# ============================================================

# generate_awg_keypair
# Generates a new private/public key pair (idempotent: skips if already saved).
# Saves to:
#   $SECRETS_DIR/awg_priv_external
#   $SECRETS_DIR/awg_pub_external
# Exports:
#   AWG_PRIV_EXTERNAL, AWG_PUB_EXTERNAL
generate_awg_keypair() {
    require_command awg

    if _secret_exists "awg_priv_external" && _secret_exists "awg_pub_external"; then
        AWG_PRIV_EXTERNAL=$(_secret_load "awg_priv_external")
        AWG_PUB_EXTERNAL=$(_secret_load "awg_pub_external")
        export AWG_PRIV_EXTERNAL AWG_PUB_EXTERNAL
        log_file "AWG keypair already present in $SECRETS_DIR (skip generation)"
        return 0
    fi

    log_file "Generating new AWG keypair"

    local priv pub
    priv=$(awg genkey)
    pub=$(echo "$priv" | awg pubkey)

    if ! is_valid_awg_key "$priv"; then
        fail "generated AWG private key has unexpected format"
    fi
    if ! is_valid_awg_key "$pub"; then
        fail "generated AWG public key has unexpected format"
    fi

    _secret_save "awg_priv_external" "$priv"
    _secret_save "awg_pub_external"  "$pub"

    AWG_PRIV_EXTERNAL="$priv"
    AWG_PUB_EXTERNAL="$pub"
    export AWG_PRIV_EXTERNAL AWG_PUB_EXTERNAL

    save_state AWG_PUB_EXTERNAL "$pub"
    # Note: do NOT save AWG_PRIV_EXTERNAL to state file (it's a secret).
    # State file lives in /etc/deploy/state.env (700/600). It's safe enough,
    # but secret duplication is bad hygiene. The private key only lives in
    # $SECRETS_DIR and /etc/amnezia/amneziawg/awg0.conf (rendered later).

    ok "AWG keypair generated; pub=$pub"
}

# ============================================================
# xray client UUID
# ============================================================

# generate_xray_client_uuid
# Generates a new UUID v4 (idempotent).
# Saves to: $SECRETS_DIR/xray_client_uuid
# Exports: XRAY_CLIENT_UUID
generate_xray_client_uuid() {
    if _secret_exists "xray_client_uuid"; then
        XRAY_CLIENT_UUID=$(_secret_load "xray_client_uuid")
        export XRAY_CLIENT_UUID
        log_file "xray client UUID already present (skip generation)"
        return 0
    fi

    local uuid
    if command -v uuidgen >/dev/null 2>&1; then
        uuid=$(uuidgen | tr 'A-Z' 'a-z')
    elif [ -r /proc/sys/kernel/random/uuid ]; then
        uuid=$(cat /proc/sys/kernel/random/uuid)
    else
        fail "no uuidgen and /proc/sys/kernel/random/uuid available"
    fi

    if ! is_valid_uuid "$uuid"; then
        fail "generated UUID has unexpected format: $uuid"
    fi

    _secret_save "xray_client_uuid" "$uuid"
    XRAY_CLIENT_UUID="$uuid"
    export XRAY_CLIENT_UUID
    save_state XRAY_CLIENT_UUID "$uuid"

    ok "xray client UUID generated: $uuid"
}

# ============================================================
# Generic dispatcher (used by wizard)
# ============================================================

# generate_for_placeholder NAME
# Dispatches to the right generator based on placeholder name.
# After call, the placeholder's value is in env (exported) and saved.
# Returns 0 if generator exists, 1 if no rule for NAME.
generate_for_placeholder() {
    local name="$1"
    case "$name" in
        AWG_PRIV_EXTERNAL|AWG_PUB_EXTERNAL)
            generate_awg_keypair
            ;;
        XRAY_CLIENT_UUID)
            generate_xray_client_uuid
            ;;
        *)
            warn "generate_for_placeholder: no rule for '$name'"
            return 1
            ;;
    esac
}

# ============================================================
# Auto-detection (for placeholders with 'auto' attribute)
# ============================================================

# auto_for_placeholder NAME
# Returns auto-detected value for known placeholders.
# Echoes value, returns 0 if detected, 1 if no rule.
auto_for_placeholder() {
    local name="$1"
    case "$name" in
        WAN_IFACE)
            local v; v=$(detect_wan_iface)
            [ -n "$v" ] && { echo "$v"; return 0; } || return 1
            ;;
        PUBLIC_IPV4)
            local v; v=$(detect_ipv4)
            [ -n "$v" ] && { echo "$v"; return 0; } || return 1
            ;;
        PUBLIC_IPV6)
            local v; v=$(detect_ipv6)
            [ -n "$v" ] && { echo "$v"; return 0; } || { echo ""; return 0; }
            ;;
        CURRENT_YEAR)
            date +%Y
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ============================================================
# Export bundle for offsite copy
# ============================================================

# secrets_print_summary -> prints what's in SECRETS_DIR (without revealing secrets)
secrets_print_summary() {
    if [ ! -d "$SECRETS_DIR" ]; then
        log "No secrets stored (yet) at $SECRETS_DIR"
        return 0
    fi
    log "Secrets stored at $SECRETS_DIR:"
    ls -la "$SECRETS_DIR" 2>/dev/null | awk 'NR>1 {print "  " $NF " (" $5 " bytes)"}'
}

# secrets_export_bundle TARBALL_PATH
# Creates a tar.gz of $SECRETS_DIR for safe offsite transfer.
# 600 perms on the bundle.
secrets_export_bundle() {
    local target="$1"
    [ -d "$SECRETS_DIR" ] || fail "secrets_export_bundle: nothing to export ($SECRETS_DIR not found)"
    [ -n "$target" ]      || fail "secrets_export_bundle: target path required"

    tar -czf "$target" -C "$(dirname "$SECRETS_DIR")" "$(basename "$SECRETS_DIR")"
    chmod 600 "$target"
    ok "secrets bundle: $target ($(du -sh "$target" | awk '{print $1}'))"
}

# secrets_wipe
# Removes all secret files. Use AFTER you've safely transferred them off-host.
# Idempotent; warns if already wiped.
secrets_wipe() {
    if [ -d "$SECRETS_DIR" ]; then
        # Overwrite then remove (best-effort secure delete on regular FS)
        find "$SECRETS_DIR" -type f -exec shred -u -n 1 {} \; 2>/dev/null || \
            find "$SECRETS_DIR" -type f -delete
        rmdir "$SECRETS_DIR" 2>/dev/null
        ok "secrets directory wiped: $SECRETS_DIR"
    else
        warn "secrets_wipe: $SECRETS_DIR already absent"
    fi
}