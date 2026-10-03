#!/system/bin/sh
# Persistent state paths and one-time migration helpers.

MODDIR="${MODDIR:-/data/adb/modules/devicespooflab}"
DATA_DIR="${DATA_DIR:-/data/adb/devicespooflab}"
CONFIG_DIR="${CONFIG_DIR:-${DATA_DIR}/config}"
MODULE_CONFIG_DIR="${MODULE_CONFIG_DIR:-${MODDIR}/config}"
PERSONA_FLAG="${PERSONA_FLAG:-${DATA_DIR}/persona_active}"
BACKUP_FILE="${BACKUP_FILE:-${DATA_DIR}/backup.conf}"
REBOOT_PENDING="${REBOOT_PENDING:-${DATA_DIR}/reboot_pending}"
APPLIED_BOOT_FILE="${APPLIED_BOOT_FILE:-${DATA_DIR}/applied_boot}"
BOOT_ATTEMPTS_FILE="${BOOT_ATTEMPTS_FILE:-${DATA_DIR}/boot_attempts}"
BOOT_WATCH_FILE="${BOOT_WATCH_FILE:-${DATA_DIR}/boot_watch_ok}"
BOOT_GUARD_OFF_FILE="${BOOT_GUARD_OFF_FILE:-${CONFIG_DIR}/boot_guard_off}"
AUTO_DISABLED_FILE="${AUTO_DISABLED_FILE:-${DATA_DIR}/auto_disabled}"
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

    # A process costs 15 to 20 ms on a phone, so nothing is made or changed that is already there.
    LOG_DIR="${LOG_FILE%/*}"
    if [ ! -d "$LOG_DIR" ]; then
        mkdir -p "$LOG_DIR" 2>/dev/null
        chmod 700 "$LOG_DIR" 2>/dev/null
    fi

    if [ -f "$LOG_FILE" ]; then
        SIZE=$(wc -c < "$LOG_FILE" 2>/dev/null | tr -d ' ')
        if [ "${SIZE:-0}" -gt "$LOG_MAX_BYTES" ]; then
            mv -f "$LOG_FILE" "${LOG_FILE}.1" 2>/dev/null
            chmod 600 "${LOG_FILE}.1" 2>/dev/null
        fi
    fi

    if [ ! -f "$LOG_FILE" ]; then
        touch "$LOG_FILE" 2>/dev/null
        chmod 600 "$LOG_FILE" 2>/dev/null
    fi
    _DEVICESPOOFLAB_LOG_READY="$LOG_FILE"
}

append_log_line() {
    prepare_private_log
    printf '%s\n' "$1" >> "$LOG_FILE"
}

copy_state_file_if_missing() {
    local SRC="$1"
    local DST="$2"

    [ -f "$SRC" ] || return 1
    [ -f "$DST" ] && return 0

    cp -p "$SRC" "$DST" 2>/dev/null || cp "$SRC" "$DST" 2>/dev/null
}

ensure_persistent_state() {
    if [ ! -d "$DATA_DIR" ] || [ ! -d "$CONFIG_DIR" ]; then
        mkdir -p "$DATA_DIR" "$CONFIG_DIR" 2>/dev/null
        chmod 700 "$DATA_DIR" "$CONFIG_DIR" 2>/dev/null
    fi
    # The log is made and trimmed by its first write (append_log_line), not here: this runs at the
    # start of every command, and most commands (status, personas, read-config) never log.

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
}
