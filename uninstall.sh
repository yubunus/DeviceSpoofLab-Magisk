#!/system/bin/sh
# Uninstall cleanup: restore original props/Android IDs, remove state.

MODDIR=${0%/*}
DATA_DIR="${DATA_DIR:-/data/adb/devicespooflab}"
CONFIG_DIR="${CONFIG_DIR:-${DATA_DIR}/config}"
BACKUP_FILE="${BACKUP_FILE:-${DATA_DIR}/backup.conf}"
ANDROID_ID_RESTORE_FAILED=0
RESETPROP_BIN=""

log() {
    local LOG_FILE="${DATA_DIR}/devicespooflab.log"
    mkdir -p "${LOG_FILE%/*}" 2>/dev/null
    chmod 700 "${LOG_FILE%/*}" 2>/dev/null
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [uninstall] $1" >> "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null
}

remove_cli_symlink() {
    local LINK="$1"
    local TARGET

    [ -L "$LINK" ] || return 0

    TARGET=$(readlink "$LINK" 2>/dev/null)
    case "$TARGET" in
        "${MODDIR}/system/bin/devicespooflabs"|\
        /data/adb/modules/devicespooflab/system/bin/devicespooflabs)
            rm -f "$LINK" 2>/dev/null
            ;;
    esac
}

remove_cli_symlink /data/adb/ksu/bin/devicespooflabs
remove_cli_symlink /data/adb/ap/bin/devicespooflabs

find_resetprop() {
    local CAND

    [ -n "$RESETPROP_BIN" ] && [ -x "$RESETPROP_BIN" ] && {
        printf '%s' "$RESETPROP_BIN"
        return 0
    }

    CAND="$(command -v resetprop 2>/dev/null)"
    if [ -x "$CAND" ]; then
        RESETPROP_BIN="$CAND"
        printf '%s' "$RESETPROP_BIN"
        return 0
    fi

    for CAND in /data/adb/ksu/bin/resetprop \
                /data/adb/ap/bin/resetprop \
                /data/adb/magisk/resetprop; do
        if [ -x "$CAND" ]; then
            RESETPROP_BIN="$CAND"
            printf '%s' "$RESETPROP_BIN"
            return 0
        fi
    done

    return 1
}

restore_android_id_config() {
    local CONF="$1" USER TGTS
    [ -f "$CONF" ] || return 0

    ANDROID_ID_CONF="$CONF"
    USER=$(ai_get_user)
    TGTS=$(ai_get_targets)
    [ -n "$TGTS" ] || return 0

    if ai_restore_targets "$USER" $TGTS; then
        log "Android ID targets restored from $CONF"
    else
        ANDROID_ID_RESTORE_FAILED=1
        log "ERROR: Android ID restore failed for $CONF: ${AI_ERROR:-unknown}"
    fi
}

restore_android_id_state() {
    local PREV_USER PREV_TGTS

    [ -f "${MODDIR}/common/state.sh" ] && . "${MODDIR}/common/state.sh"
    [ -f "${MODDIR}/common/android_id.sh" ] || return 0
    . "${MODDIR}/common/android_id.sh"

    if [ -f "$AI_APPLIED_STATE" ]; then
        PREV_USER=$(ai_applied_user)
        PREV_TGTS=$(ai_applied_targets)
        if [ -n "$PREV_TGTS" ]; then
            if ai_restore_targets "$PREV_USER" $PREV_TGTS; then
                log "Android ID last-applied targets restored"
                rm -f "$AI_APPLIED_STATE" 2>/dev/null
            else
                ANDROID_ID_RESTORE_FAILED=1
                log "ERROR: Android ID applied-state restore failed: ${AI_ERROR:-unknown}"
            fi
        fi
    fi

    restore_android_id_config "${CONFIG_DIR}/android_id.conf"
}

remove_module_persistent_prop() {
    local RESETPROP
    RESETPROP=$(find_resetprop) || return 0

    "$RESETPROP" --delete persist.devicespooflab.allow_unsafe 2>/dev/null || \
        "$RESETPROP" -p --delete persist.devicespooflab.allow_unsafe 2>/dev/null || \
        "$RESETPROP" -n persist.devicespooflab.allow_unsafe "" 2>/dev/null
}

restore_runtime_props() {
    local RESETPROP LINE KEY VALUE COUNT=0
    [ -f "$BACKUP_FILE" ] || return 0
    RESETPROP=$(find_resetprop) || return 0

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in ''|'#'*) continue ;; esac
        KEY=${LINE%%=*}
        VALUE=${LINE#*=}
        [ "$KEY" != "$LINE" ] || continue
        [ -n "$KEY" ] || continue

        if "$RESETPROP" -n "$KEY" "$VALUE" 2>/dev/null; then
            COUNT=$((COUNT + 1))
        fi
    done < "$BACKUP_FILE"

    [ "$COUNT" -gt 0 ] && log "Runtime props restored from backup ($COUNT)"
}

restore_android_id_state
restore_runtime_props
remove_module_persistent_prop
rm -f /data/local/tmp/dsl-ksuwebui.apk 2>/dev/null

if [ "$ANDROID_ID_RESTORE_FAILED" -eq 0 ]; then
    rm -rf "$DATA_DIR" 2>/dev/null
else
    log "Keeping $DATA_DIR because Android ID restore failed; SSAID backup preserved for recovery"
fi
