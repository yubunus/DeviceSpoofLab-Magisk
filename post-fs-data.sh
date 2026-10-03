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

# Sourcing a file with a syntax error ends the script, and the Android ID step at the end
# would never run. Try the file in a subshell first.
loads_cleanly() {
    ( . "$1" ) >/dev/null 2>&1
}

if [ -f "${MODDIR}/common/prop_safety.sh" ]; then
    if ! loads_cleanly "${MODDIR}/common/prop_safety.sh" || ! . "${MODDIR}/common/prop_safety.sh"; then
        log "ERROR: prop_safety.sh failed to load - refusing all props"
        should_apply_prop() {
            fail_closed_should_apply_prop "$@"
        }
    fi
else
    log "ERROR: prop_safety.sh missing - refusing all props"
fi

SPOOF_READY=1
if [ ! -f "${MODDIR}/common/value_resolver.sh" ]; then
    log "ERROR: value_resolver.sh missing - aborting spoof"
    SPOOF_READY=0
elif ! loads_cleanly "${MODDIR}/common/value_resolver.sh" || ! . "${MODDIR}/common/value_resolver.sh"; then
    log "ERROR: value_resolver.sh failed to load - aborting spoof"
    SPOOF_READY=0
else
    case "$(type has_generator_token 2>/dev/null)" in
        *function*) ;;
        *)
            log "ERROR: value_resolver.sh is incomplete - aborting spoof"
            SPOOF_READY=0
            ;;
    esac
fi

apply_prop() {
    local PROP="$1"
    local VALUE="$2"
    local CURRENT

    [ -z "$VALUE" ] && return 1

    CURRENT=$(getprop "$PROP" 2>/dev/null)
    if [ -z "$CURRENT" ]; then
        log "Prop skipped (not on this device): $PROP"
        return 0
    fi
    [ "$CURRENT" = "$VALUE" ] && return 0

    # Read the prop back: resetprop in Magisk 30.3+ exits 0 even when the write failed.
    if "$RESETPROP" -n "$PROP" "$VALUE" 2>/dev/null && \
        [ "$(getprop "$PROP" 2>/dev/null)" = "$VALUE" ]; then
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
    local REST PROP RAW VALUE

    [ ! -f "$FILE" ] && return

    if grep -q '^FILE_DISABLED' "$FILE" 2>/dev/null; then
        log "Skipping (disabled): $NAME"
        return
    fi

    log "Applying: $NAME"

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in ''|'#'*) continue ;; esac
        [ "$LINE" = "FILE_ENABLED" ] && continue

        case "$LINE" in ENABLED,*,*) ;; *) continue ;; esac
        REST=${LINE#ENABLED,}
        PROP=${REST%%,*}
        RAW=${REST#*,}

        if has_generator_token "$RAW"; then
            log "ERROR: Unresolved generator token for $PROP in $NAME - activate persona from CLI to freeze it"
            continue
        fi

        VALUE="$RAW"
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

# Counts the boots that apply a persona. service.sh removes the count once the phone is up
# and stays up; two boots in a row that never got that far switch the persona off, so the
# next boot comes up with the real identity. Nothing is counted until service.sh has shown,
# on this phone, that its check runs (BOOT_WATCH_FILE), nor when the user has switched the
# guard off (BOOT_GUARD_OFF_FILE).
boot_guard() {
    local COUNT=""

    [ -n "$BOOT_ATTEMPTS_FILE" ] && [ -f "$BOOT_WATCH_FILE" ] || return 0
    [ ! -f "$BOOT_GUARD_OFF_FILE" ] || return 0

    # Anything but a plain file there is not ours; reading or writing a pipe would hang the boot.
    if [ -f "$BOOT_ATTEMPTS_FILE" ]; then
        COUNT=$(cat "$BOOT_ATTEMPTS_FILE" 2>/dev/null)
    elif [ -e "$BOOT_ATTEMPTS_FILE" ]; then
        return 0
    fi
    case "$COUNT" in ''|*[!0-9]*|0?*|???*) COUNT=0 ;; esac

    if [ "$COUNT" -ge 2 ]; then
        : > "$AUTO_DISABLED_FILE" 2>/dev/null
        [ -f "$ACTIVE_PERSONA_FILE" ] && cat "$ACTIVE_PERSONA_FILE" > "$AUTO_DISABLED_FILE" 2>/dev/null
        rm -f "$PERSONA_FLAG" "$ACTIVE_PERSONA_FILE" "$BOOT_ATTEMPTS_FILE" 2>/dev/null
        log "Persona switched off: the phone did not finish starting up $COUNT times in a row with it on"
        return 1
    fi

    echo $((COUNT + 1)) > "$BOOT_ATTEMPTS_FILE" 2>/dev/null
    # A forced reset within the next minute would otherwise lose the count.
    fsync "$BOOT_ATTEMPTS_FILE" 2>/dev/null || sync
    return 0
}

spoof_props() {
    [ "$SPOOF_READY" -eq 1 ] || return 0

    if [ -f "${MODDIR}/disable" ]; then
        log "Module disabled - skipping"
        return 0
    fi

    if [ ! -f "$PERSONA_FLAG" ]; then
        log "No active persona - skipping"
        return 0
    fi

    boot_guard || return 0

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
        return 0
    fi

    # Tells uninstall.sh that props were applied in this kernel boot (see restore_runtime_props).
    [ -n "$APPLIED_BOOT_FILE" ] && cat /proc/sys/kernel/random/boot_id > "$APPLIED_BOOT_FILE" 2>/dev/null

    apply_all_props

    log "Pre-zygote spoof complete"
}

log "============================================"
log "DeviceSpoofLabs post-fs-data - pre-zygote spoof stage"

# Props first: they must be in place before zygote, and KernelSU and APatch put no time limit
# on this stage. The Android ID step starts app_process (abx2xml / xml2abx) and can be slow.
spoof_props

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

exit 0
