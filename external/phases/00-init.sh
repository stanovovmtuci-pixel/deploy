#!/usr/bin/env bash
# 00-init.sh - interactive wizard to populate state.env from manifest.json
#
# Iterates over all placeholders in manifest.json and fills them according to
# their classification (asked / auto / generated / random / derived / default).
# Result: every placeholder lands in /etc/deploy/state.env, ready for phases.
#
# Re-running this phase is safe: existing values in state are kept (unless
# user opts to re-enter via prompt).

PHASE_ID="00-init"

run_phase() {
    require_command jq

    backup_init "$PHASE_ID"
    backup_file "$DEPLOY_STATE_FILE"
    ok "backup taken"

    # Load any existing state into env (so re-runs see prior values)
    load_state

    log "Wizard: filling placeholders from manifest"
    log "Manifest: $MANIFEST_FILE"
    log "Total placeholders: $(manifest_count)"
    echo

    # First pass: non-derived (we need their values before derived can resolve)
    local total_done=0
    local total_skipped=0
    while IFS= read -r ph; do
        # Skip derived in pass 1 — they need other placeholders set first
        if manifest_is_derived "$ph"; then
            continue
        fi

        if _ph_already_set "$ph"; then
            total_skipped=$((total_skipped+1))
            log "  [skip] $ph (already set in state)"
            continue
        fi

        _ph_fill "$ph" || fail "Failed to fill placeholder: $ph"
        total_done=$((total_done+1))
    done < <(manifest_list_placeholders)

    # Second pass: derived placeholders
    while IFS= read -r ph; do
        if ! manifest_is_derived "$ph"; then
            continue
        fi

        if _ph_already_set "$ph"; then
            total_skipped=$((total_skipped+1))
            log "  [skip] $ph (already set in state)"
            continue
        fi

        _ph_fill_derived "$ph" || fail "Failed to resolve derived: $ph"
        total_done=$((total_done+1))
    done < <(manifest_list_placeholders)

    echo
    ok "filled: $total_done placeholders, skipped (already set): $total_skipped"

    # Show non-secret summary
    _ph_show_summary

    # Confirm before proceeding
    echo
    if ! ask_yn "Proceed with deploy using these values?" "y"; then
        fail "User cancelled at 00-init"
    fi

    return 0
}

# ============================================================
# Helpers (private to this phase)
# ============================================================

# _ph_already_set NAME -> 0 if state has non-empty value
_ph_already_set() {
    local name="$1"
    load_state
    [ -n "${!name:-}" ]
}

# _ph_fill NAME -> dispatches based on classification
_ph_fill() {
    local name="$1"
    local cls
    cls=$(manifest_classify "$name")
    local value=""

    case "$cls" in
        asked)     value=$(_ph_ask "$name")          ;;
        auto)      value=$(_ph_auto "$name")          ;;
        generated) _ph_generate "$name"; value="${!name:-}" ;;
        random)    value=$(_ph_random "$name")        ;;
        default)   value=$(manifest_get_default "$name") ;;
        unknown)
            warn "Placeholder $name has no fillable rule; will set to empty"
            value=""
            ;;
        derived)
            # handled in second pass
            return 0
            ;;
        *)
            warn "Unknown classification '$cls' for $name"
            value=""
            ;;
    esac

    # Save to state and export to current env
    save_state "$name" "$value"
    export "$name"="$value"
    return 0
}

# _ph_fill_derived NAME -> resolves {{...}} expression with current env
_ph_fill_derived() {
    local name="$1"
    local value
    value=$(manifest_resolve_derived "$name") || return 1
    save_state "$name" "$value"
    export "$name"="$value"
    log "  derived: $name = $value"
    return 0
}

# _ph_ask NAME -> interactive prompt with default and validator
_ph_ask() {
    local name="$1"
    local default validator example comment optional
    default=$(manifest_get_default "$name")
    validator=$(manifest_get_validator "$name")
    example=$(manifest_get_example "$name")
    comment=$(manifest_get_comment "$name")

    # Build prompt
    local prompt="$name"
    [ -n "$comment" ] && prompt="$prompt — $comment"
    [ -n "$example" ] && prompt="$prompt (e.g. $example)"

    local value
    if manifest_is_optional "$name"; then
        # Optional: empty allowed
        if [ -n "$default" ]; then
            value=$(ask_default "$prompt" "$default")
        else
            value=$(ask "$prompt")
        fi
        # Optional + validator + non-empty: still validate
        if [ -n "$value" ] && [ -n "$validator" ]; then
            if ! "$validator" "$value"; then
                warn "Validation failed for $name; keeping empty"
                value=""
            fi
        fi
    else
        # Required: loop with validator
        value=$(ask_with_confirm "$prompt" "$default" "$validator")
    fi

    echo "$value"
}

# _ph_auto NAME -> auto-detect via secrets.sh dispatcher
_ph_auto() {
    local name="$1"
    local v
    v=$(auto_for_placeholder "$name")
    if [ -z "$v" ] && ! manifest_is_optional "$name"; then
        warn "Auto-detect failed for $name; falling back to ask"
        v=$(ask "$name (auto-detect failed; enter manually)")
    fi
    echo "$v"
}

# _ph_generate NAME -> calls generator from secrets.sh; sets variable in env
_ph_generate() {
    local name="$1"
    generate_for_placeholder "$name" || fail "generator failed for $name"
}

# _ph_random NAME -> pick random value from range
_ph_random() {
    local name="$1"
    local range
    range=$(manifest_get_random_range "$name")
    [ -n "$range" ] || { warn "no range for $name"; echo ""; return; }

    local min max
    min=$(echo "$range" | cut -d- -f1)
    max=$(echo "$range" | cut -d- -f2)

    # If validator wants port, use random_port; otherwise generic
    local validator
    validator=$(manifest_get_validator "$name")
    if [ "$validator" = "is_valid_port" ]; then
        random_port "$min" "$max"
    else
        echo $((min + RANDOM % (max - min + 1)))
    fi
}

# _ph_show_summary -> prints placeholders and their values, redacting secrets
_ph_show_summary() {
    echo
    log "Resolved values (secrets redacted):"
    while IFS= read -r ph; do
        local val="${!ph:-}"
        if manifest_is_secret "$ph"; then
            if [ -n "$val" ]; then
                printf "  %-32s = %s\n" "$ph" "<REDACTED ${#val} bytes>"
            else
                printf "  %-32s = %s\n" "$ph" "<unset>"
            fi
        else
            printf "  %-32s = %s\n" "$ph" "${val:-<unset>}"
        fi
    done < <(manifest_list_placeholders)
}