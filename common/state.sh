#!/system/bin/sh
# Persistent state paths and one-time migration helpers.

MODDIR="${MODDIR:-/data/adb/modules/devicespooflab}"
DATA_DIR="${DATA_DIR:-/data/adb/devicespooflab}"
CONFIG_DIR="${CONFIG_DIR:-${DATA_DIR}/config}"
MODULE_CONFIG_DIR="${MODULE_CONFIG_DIR:-${MODDIR}/config}"
PERSONA_FLAG="${PERSONA_FLAG:-${DATA_DIR}/persona_active}"
BACKUP_FILE="${BACKUP_FILE:-${DATA_DIR}/backup.conf}"
REBOOT_PENDING="${REBOOT_PENDING:-${DATA_DIR}/reboot_pending}"
PERSONAS_DIR="${PERSONAS_DIR:-${DATA_DIR}/personas}"
ACTIVE_PERSONA_FILE="${ACTIVE_PERSONA_FILE:-${DATA_DIR}/active_persona}"
LOG_FILE="${LOG_FILE:-${DATA_DIR}/devicespooflab.log}"
LOG_MAX_BYTES="${LOG_MAX_BYTES:-131072}"
_DEVICESPOOFLAB_LOG_READY=""

LEGACY_CONFIG_DIR="${LEGACY_CONFIG_DIR:-${MODDIR}/config}"
LEGACY_PERSONA_FLAG="${LEGACY_PERSONA_FLAG:-${LEGACY_CONFIG_DIR}/persona_active}"
LEGACY_BACKUP_FILE="${LEGACY_BACKUP_FILE:-${LEGACY_CONFIG_DIR}/backup.conf}"

STATE_CONFIG_FILES="
device_identity.conf
build_info.conf
identifiers.conf
custom.conf
"

state_log() {
    case "$(type log 2>/dev/null)" in
        *function*)
            log "$1"
            ;;
    esac
}

prepare_private_log() {
    local LOG_DIR SIZE

    [ "$_DEVICESPOOFLAB_LOG_READY" = "$LOG_FILE" ] && return 0

    LOG_DIR="${LOG_FILE%/*}"
    mkdir -p "$LOG_DIR" 2>/dev/null
    chmod 700 "$LOG_DIR" 2>/dev/null

    if [ -f "$LOG_FILE" ]; then
        SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
        if [ "${SIZE:-0}" -gt "$LOG_MAX_BYTES" ]; then
            mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
            chmod 600 "${LOG_FILE}.1" 2>/dev/null
        fi
    fi

    touch "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null
    _DEVICESPOOFLAB_LOG_READY="$LOG_FILE"
}

append_log_line() {
    prepare_private_log
    echo "$1" >> "$LOG_FILE"
}

copy_state_file_if_missing() {
    local SRC="$1"
    local DST="$2"

    [ -f "$SRC" ] || return 1
    [ -f "$DST" ] && return 0

    cp -p "$SRC" "$DST" 2>/dev/null || cp "$SRC" "$DST" 2>/dev/null
}

upgrade_default_build_info_config() {
    local FILE="${CONFIG_DIR}/build_info.conf"
    local TMP

    [ -f "$FILE" ] || return 0
    grep -q 'google/cheetah/cheetah:15/AP4A\.241205\.013/12621605:user/release-keys' "$FILE" 2>/dev/null || return 0

    TMP="${FILE}.tmp.$$"
    if ! sed \
        -e 's/Android 15 build fingerprint/Android 16 build fingerprint/g' \
        -e 's/":15\/"/":16\/"/g' \
        -e 's/cheetah:15\/AP4A\.241205\.013\/12621605/cheetah:16\/CP1A.260405.005\/15001963/g' \
        -e 's/google\/cheetah\/cheetah:15\/AP4A\.241205\.013\/12621605:user\/release-keys/google\/cheetah\/cheetah:16\/CP1A.260405.005\/15001963:user\/release-keys/g' \
        -e 's/AP4A\.241205\.013/CP1A.260405.005/g' \
        -e 's/12621605/15001963/g' \
        -e 's/cheetah-user 15 CP1A.260405.005 15001963 release-keys/generic_system_google-user 16 CP1A.260405.005 15001963 release-keys/g' \
        -e 's/2024-12-05/2026-04-05/g' \
        -e 's/cheetah-user/generic_system_google-user/g' \
        "$FILE" > "$TMP" 2>/dev/null; then
        rm -f "$TMP" 2>/dev/null
        return 0
    fi

    mv -f "$TMP" "$FILE" 2>/dev/null || {
        rm -f "$TMP" 2>/dev/null
        return 0
    }

    chmod 600 "$FILE" 2>/dev/null
    state_log "Upgraded default build_info.conf fingerprint to Android 16"
}

ensure_persistent_state() {
    mkdir -p "$DATA_DIR" "$CONFIG_DIR" 2>/dev/null
    chmod 700 "$DATA_DIR" "$CONFIG_DIR" 2>/dev/null
    prepare_private_log

    if [ -f "$LEGACY_PERSONA_FLAG" ] && [ ! -f "$PERSONA_FLAG" ]; then
        touch "$PERSONA_FLAG" 2>/dev/null && state_log "Migrated persona_active to $PERSONA_FLAG"
    fi

    if [ -f "$LEGACY_BACKUP_FILE" ] && [ ! -f "$BACKUP_FILE" ]; then
        if copy_state_file_if_missing "$LEGACY_BACKUP_FILE" "$BACKUP_FILE"; then
            chmod 600 "$BACKUP_FILE" 2>/dev/null
            state_log "Migrated backup.conf to $BACKUP_FILE"
        fi
    fi

    if [ -f "${LEGACY_CONFIG_DIR}/allow_unsafe_props" ] && [ ! -f "${CONFIG_DIR}/allow_unsafe_props" ]; then
        copy_state_file_if_missing "${LEGACY_CONFIG_DIR}/allow_unsafe_props" "${CONFIG_DIR}/allow_unsafe_props" && \
            chmod 600 "${CONFIG_DIR}/allow_unsafe_props" 2>/dev/null
    fi

    local CONF
    for CONF in $STATE_CONFIG_FILES; do
        if [ ! -f "${CONFIG_DIR}/${CONF}" ]; then
            if copy_state_file_if_missing "${LEGACY_CONFIG_DIR}/${CONF}" "${CONFIG_DIR}/${CONF}"; then
                chmod 600 "${CONFIG_DIR}/${CONF}" 2>/dev/null
                state_log "Seeded persistent config: $CONF"
            elif copy_state_file_if_missing "${MODULE_CONFIG_DIR}/${CONF}" "${CONFIG_DIR}/${CONF}"; then
                chmod 600 "${CONFIG_DIR}/${CONF}" 2>/dev/null
                state_log "Seeded persistent config: $CONF"
            fi
        fi
    done

    upgrade_default_build_info_config
}
