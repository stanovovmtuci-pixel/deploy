#!/usr/bin/env bash
# manifest.sh - parser for external/manifest.json
# Sourced by phases. Provides functions to iterate placeholders
# and look up their attributes (asked, default, generated, secret, etc.)

# MANIFEST_FILE is exported by deploy.sh; default for direct sourcing.
MANIFEST_FILE="${MANIFEST_FILE:-${DEPLOY_ROOT}/manifest.json}"

# ============================================================
# Internal helpers
# ============================================================

_manifest_check() {
    [ -f "$MANIFEST_FILE" ] || fail "manifest not found: $MANIFEST_FILE"
    command -v jq >/dev/null 2>&1 || fail "jq is required for manifest parsing"
}

# ============================================================
# Listing placeholders
# ============================================================

# manifest_list_placeholders -> echoes all placeholder names, one per line
# (preserves manifest order)
manifest_list_placeholders() {
    _manifest_check
    jq -r '.placeholders | keys_unsorted[]' "$MANIFEST_FILE"
}

# manifest_count -> echoes total number of placeholders
manifest_count() {
    _manifest_check
    jq -r '.placeholders | length' "$MANIFEST_FILE"
}

# ============================================================
# Per-placeholder attribute lookup
# ============================================================

# manifest_get_attr NAME ATTR -> echoes attribute value (or empty if not set)
# Example: manifest_get_attr NODE_ID asked  -> "true"
# Example: manifest_get_attr NODE_ID default -> "" (no default for NODE_ID)
manifest_get_attr() {
    local name="$1"
    local attr="$2"
    _manifest_check
    jq -r --arg n "$name" --arg a "$attr" \
        '.placeholders[$n][$a] // empty' "$MANIFEST_FILE"
}

# manifest_has_attr NAME ATTR -> returns 0 if attr is set (and truthy)
manifest_has_attr() {
    local name="$1"
    local attr="$2"
    local val
    val=$(manifest_get_attr "$name" "$attr")
    [ -n "$val" ] && [ "$val" != "false" ] && [ "$val" != "null" ]
}

# manifest_get_default NAME -> echoes default value or empty
manifest_get_default() {
    manifest_get_attr "$1" "default"
}

# manifest_get_validator NAME -> echoes validator function name or empty
manifest_get_validator() {
    manifest_get_attr "$1" "validator"
}

# manifest_get_example NAME -> echoes example string or empty
manifest_get_example() {
    manifest_get_attr "$1" "example"
}

# manifest_get_comment NAME -> echoes comment string or empty
manifest_get_comment() {
    manifest_get_attr "$1" "comment"
}

# manifest_get_random_range NAME -> echoes "MIN-MAX" or empty
manifest_get_random_range() {
    manifest_get_attr "$1" "random_range"
}

# manifest_get_derived NAME -> echoes derivation expression (e.g. "{{AWG_TUN_IPV6}}") or empty
manifest_get_derived() {
    manifest_get_attr "$1" "derived"
}

# ============================================================
# Boolean attributes
# ============================================================

# manifest_is_asked NAME -> returns 0 if placeholder is asked from user
manifest_is_asked() {
    [ "$(manifest_get_attr "$1" "asked")" = "true" ]
}

# manifest_is_auto NAME -> returns 0 if value is auto-detected
# (the 'auto' attribute is a description string, not boolean — non-empty means yes)
manifest_is_auto() {
    [ -n "$(manifest_get_attr "$1" "auto")" ]
}

# manifest_is_generated NAME -> returns 0 if value is generated
manifest_is_generated() {
    [ -n "$(manifest_get_attr "$1" "generated")" ]
}

# manifest_is_derived NAME -> returns 0 if value is derived from others
manifest_is_derived() {
    [ -n "$(manifest_get_attr "$1" "derived")" ]
}

# manifest_is_random NAME -> returns 0 if value is random in range
manifest_is_random() {
    [ -n "$(manifest_get_attr "$1" "random_range")" ]
}

# manifest_is_secret NAME -> returns 0 if value should NOT be logged
manifest_is_secret() {
    [ "$(manifest_get_attr "$1" "secret")" = "true" ]
}

# manifest_is_optional NAME -> returns 0 if empty value is acceptable
manifest_is_optional() {
    [ "$(manifest_get_attr "$1" "optional")" = "true" ]
}

# manifest_is_expose_to_peer NAME -> returns 0 if value is shown in deploy summary
# (used to print AWG pubkey, xray UUID etc. that internal-side needs)
manifest_is_expose_to_peer() {
    [ "$(manifest_get_attr "$1" "expose_to_peer")" = "true" ]
}

# ============================================================
# High-level: how to fill a placeholder
# ============================================================

# manifest_classify NAME -> echoes one of:
#   asked | auto | generated | derived | random | default | unknown
# Useful for the wizard to dispatch to the right filler.
manifest_classify() {
    local name="$1"
    if manifest_is_asked      "$name"; then echo "asked";     return; fi
    if manifest_is_generated  "$name"; then echo "generated"; return; fi
    if manifest_is_random     "$name"; then echo "random";    return; fi
    if manifest_is_derived    "$name"; then echo "derived";   return; fi
    if manifest_is_auto       "$name"; then echo "auto";      return; fi
    if [ -n "$(manifest_get_default "$name")" ]; then
        echo "default"
        return
    fi
    echo "unknown"
}

# ============================================================
# Documentation helpers
# ============================================================

# manifest_print_summary -> prints all placeholders with their classification
# (useful for debugging / docs)
manifest_print_summary() {
    _manifest_check
    log "Manifest summary: $MANIFEST_FILE"
    local total
    total=$(manifest_count)
    echo "  Total placeholders: $total"
    echo
    while IFS= read -r name; do
        local cls
        cls=$(manifest_classify "$name")
        local extras=""
        manifest_is_secret         "$name" && extras="${extras} [SECRET]"
        manifest_is_optional       "$name" && extras="${extras} [OPTIONAL]"
        manifest_is_expose_to_peer "$name" && extras="${extras} [EXPOSE]"
        local val=""
        case "$cls" in
            asked)     val=$(manifest_get_attr "$name" "default")
                       [ -n "$val" ] && val=" (default: $val)"
                       ;;
            default)   val=" = $(manifest_get_default "$name")"
                       ;;
            random)    val=" (range: $(manifest_get_random_range "$name"))"
                       ;;
            derived)   val=" -> $(manifest_get_derived "$name")"
                       ;;
            generated) val=" via $(manifest_get_attr "$name" "generated")"
                       ;;
            auto)      val=" via $(manifest_get_attr "$name" "auto")"
                       ;;
        esac
        printf "  %-32s [%s]%s%s\n" "$name" "$cls" "$val" "$extras"
    done < <(manifest_list_placeholders)
}

# manifest_print_exposed -> prints placeholders marked expose_to_peer with their VALUES
# (read from current env). Used by 09-finalize to give user info to register the peer.
manifest_print_exposed() {
    _manifest_check
    log "Values to share with peer side (e.g. internal node):"
    while IFS= read -r name; do
        if manifest_is_expose_to_peer "$name"; then
            local val="${!name:-<UNSET>}"
            printf "  %-32s = %s\n" "$name" "$val"
        fi
    done < <(manifest_list_placeholders)
}

# ============================================================
# Validation
# ============================================================

# manifest_validate_value NAME VALUE -> returns 0 if VALUE passes the validator
# (or if no validator is set). 1 if validation fails.
manifest_validate_value() {
    local name="$1"
    local value="$2"
    local validator
    validator=$(manifest_get_validator "$name")

    # No validator -> always ok
    [ -z "$validator" ] && return 0

    # Empty value + optional -> ok
    if [ -z "$value" ] && manifest_is_optional "$name"; then
        return 0
    fi

    # Invoke validator function (must be defined in validation.sh)
    if ! command -v "$validator" >/dev/null 2>&1; then
        warn "manifest_validate_value: validator $validator not defined"
        return 1
    fi

    "$validator" "$value"
}

# manifest_resolve_derived NAME -> echoes the derived value with all
# {{OTHER}} substituted from current env. Returns 1 if any substitution fails.
manifest_resolve_derived() {
    local name="$1"
    local expr
    expr=$(manifest_get_derived "$name")
    [ -n "$expr" ] || { warn "manifest_resolve_derived: $name is not derived"; return 1; }

    # Use python for substitution (same engine as render.sh)
    local result
    result=$(python3 - "$expr" <<'PYEOF'
import os, re, sys
expr = sys.argv[1]
def sub_var(m):
    name = m.group(1)
    return os.environ.get(name, "{{UNRESOLVED:" + name + "}}")
print(re.sub(r'\{\{([A-Z_0-9]+)\}\}', sub_var, expr), end="")
PYEOF
)
    if [[ "$result" == *"{{UNRESOLVED:"* ]]; then
        warn "manifest_resolve_derived: $name has unresolved deps in '$result'"
        return 1
    fi
    echo "$result"
}