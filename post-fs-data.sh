#!/system/bin/sh
# Pre-zygote stage: apply spoofed identity props and reconcile the Android ID.

MODDIR=${0%/*}
LOG_FILE="${LOG_FILE:-/data/adb/devicespooflab/devicespooflab.log}"

log() {
    case "$(type append_log_line 2>/dev/null)" in
        *function*)
            append_log_line "[$(date '+%Y-%m-%d %H:%M:%S')] [post-fs-data] $1"
            ;;
        *)
            mkdir -p "${LOG_FILE%/*}" 2>/dev/null
            chmod 700 "${LOG_FILE%/*}" 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [post-fs-data] $1" >> "$LOG_FILE"
            chmod 600 "$LOG_FILE" 2>/dev/null
            ;;
    esac
}

if [ -f "${MODDIR}/common/state.sh" ]; then
    . "${MODDIR}/common/state.sh"
    ensure_persistent_state
else
    CONFIG_DIR="${CONFIG_DIR:-${MODDIR}/config}"
    PERSONA_FLAG="${PERSONA_FLAG:-${CONFIG_DIR}/persona_active}"
    BACKUP_FILE="${BACKUP_FILE:-${CONFIG_DIR}/backup.conf}"
    REBOOT_PENDING="${REBOOT_PENDING:-${CONFIG_DIR}/reboot_pending}"
fi

rm -f "$REBOOT_PENDING" 2>/dev/null

if [ -f "${MODDIR}/common/android_id.sh" ]; then
    . "${MODDIR}/common/android_id.sh"
    if [ -f "${MODDIR}/disable" ]; then
        if ai_boot_revert; then
            log "Android ID reverted (module disabled)"
        else
            log "ERROR: Android ID revert failed: ${AI_ERROR:-unknown}"
        fi
    elif ai_boot_reconcile; then
        [ "${AI_APPLIED_COUNT:-0}" -gt 0 ] && \
            log "Android ID applied to ${AI_APPLIED_COUNT} app(s)${AI_SKIPPED_PKGS:+; no SSAID yet: ${AI_SKIPPED_PKGS}}"
    else
        log "ERROR: Android ID reconcile failed: ${AI_ERROR:-unknown}"
    fi
fi

fail_closed_should_apply_prop() {
    local PROP="$1"
    local VALUE="$2"
    local STAGE="$3"
    local SOURCE="$4"

    log "ERROR: Safety guard unavailable (${STAGE}/${SOURCE}) - refusing prop: $PROP"
    return 1
}

should_apply_prop() {
    fail_closed_should_apply_prop "$@"
}

if [ -f "${MODDIR}/common/prop_safety.sh" ]; then
    if ! . "${MODDIR}/common/prop_safety.sh"; then
        log "ERROR: prop_safety.sh failed to load - refusing all props"
        should_apply_prop() {
            fail_closed_should_apply_prop "$@"
        }
    fi
else
    log "ERROR: prop_safety.sh missing - refusing all props"
fi

if [ -f "${MODDIR}/common/value_resolver.sh" ]; then
    . "${MODDIR}/common/value_resolver.sh"
else
    log "ERROR: value_resolver.sh missing - aborting spoof"
    exit 0
fi

apply_prop() {
    local PROP="$1"
    local VALUE="$2"

    [ -z "$VALUE" ] && return 1

    if "$RESETPROP" -n "$PROP" "$VALUE" 2>/dev/null; then
        log "Prop set: $PROP"
        return 0
    else
        log "ERROR: Failed to set prop: $PROP"
        return 1
    fi
}

apply_config_file() {
    local FILE="$1"
    local NAME=$(basename "$FILE")

    [ ! -f "$FILE" ] && return

    if grep -q '^FILE_DISABLED' "$FILE" 2>/dev/null; then
        log "Skipping (disabled): $NAME"
        return
    fi

    log "Applying: $NAME"

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in ''|'#'*) continue ;; esac
        [ "$LINE" = "FILE_ENABLED" ] && continue

        local STATUS=$(echo "$LINE" | cut -d',' -f1)
        local PROP=$(echo "$LINE" | cut -d',' -f2)
        local RAW=$(echo "$LINE" | cut -d',' -f3-)

        [ "$STATUS" != "ENABLED" ] && continue

        if has_generator_token "$RAW"; then
            log "ERROR: Unresolved generator token for $PROP in $NAME - activate persona from CLI to freeze it"
            continue
        fi

        local VALUE="$RAW"
        [ -n "$VALUE" ] || continue
        should_apply_prop "$PROP" "$VALUE" "post-fs-data" "$NAME" || continue
        apply_prop "$PROP" "$VALUE"

    done < "$FILE"
}

apply_all_props() {
    for CONF in \
        device_identity.conf \
        build_info.conf \
        identifiers.conf \
        custom.conf; do

        [ -f "${CONFIG_DIR}/${CONF}" ] && apply_config_file "${CONFIG_DIR}/${CONF}"
    done
}

log "============================================"
log "DeviceSpoofLabs post-fs-data - pre-zygote spoof stage"

if [ -f "${MODDIR}/disable" ]; then
    log "Module disabled - skipping"
    exit 0
fi

if [ ! -f "$PERSONA_FLAG" ]; then
    log "No active persona - skipping"
    exit 0
fi

RESETPROP="$(command -v resetprop 2>/dev/null)"
if [ -z "$RESETPROP" ]; then
    for CAND in /data/adb/ksu/bin/resetprop \
                /data/adb/ap/bin/resetprop \
                /data/adb/magisk/resetprop; do
        [ -x "$CAND" ] && { RESETPROP="$CAND"; break; }
    done
fi

if [ -n "$RESETPROP" ]; then
    log "resetprop ready: $RESETPROP"
else
    log "resetprop not found (checked PATH, /data/adb/{ksu,ap}/bin, /data/adb/magisk) - aborting spoof"
    exit 0
fi

apply_all_props

log "Pre-zygote spoof complete"
