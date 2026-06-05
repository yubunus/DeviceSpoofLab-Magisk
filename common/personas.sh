#!/system/bin/sh
# Named multi-persona store; one persona active at a time.

PERSONAS_DIR="${PERSONAS_DIR:-${DATA_DIR}/personas}"
ACTIVE_PERSONA_FILE="${ACTIVE_PERSONA_FILE:-${DATA_DIR}/active_persona}"
MODULE_CONFIG_DIR="${MODULE_CONFIG_DIR:-${MODDIR}/config}"

PERSONA_CONF_FILES="device_identity.conf build_info.conf identifiers.conf custom.conf android_id.conf"

PERSONA_ERROR=""

persona_dir() { printf '%s/%s' "$PERSONAS_DIR" "$1"; }

persona_valid_id() {
    case "$1" in
        '' | *[!a-z0-9_]*) return 1 ;;
    esac
    case "$1" in
        p*) return 0 ;;
        *) return 1 ;;
    esac
}

persona_exists() { [ -d "$(persona_dir "$1")" ]; }

persona_new_id() { printf 'p%s_%s' "$(date +%s)" "$(generate_hex 4)"; }

persona_write_meta() {
    local ID="$1" NAME="$2" CREATED="$3" DIR
    DIR=$(persona_dir "$ID")
    NAME=$(printf '%s' "$NAME" | tr -d '\n\r' | cut -c1-64)
    [ -n "$NAME" ] || NAME="Persona"
    [ -n "$CREATED" ] || CREATED=$(date +%s)
    {
        echo "NAME=${NAME}"
        echo "CREATED=${CREATED}"
    } > "${DIR}/meta" 2>/dev/null
    chmod 600 "${DIR}/meta" 2>/dev/null
}

persona_get_name() {
    local DIR NAME
    DIR=$(persona_dir "$1")
    NAME=$(grep -m1 '^NAME=' "${DIR}/meta" 2>/dev/null)
    NAME=${NAME#NAME=}
    [ -n "$NAME" ] || NAME="Persona"
    printf '%s' "$NAME"
}

persona_get_created() {
    local DIR C
    DIR=$(persona_dir "$1")
    C=$(grep -m1 '^CREATED=' "${DIR}/meta" 2>/dev/null)
    printf '%s' "${C#CREATED=}"
}

persona_field() {
    local ID="$1" FILE="$2" PROP="$3" DIR LINE
    DIR=$(persona_dir "$ID")
    LINE=$(grep -m1 "^ENABLED,${PROP}," "${DIR}/${FILE}" 2>/dev/null) || return 0
    [ -n "$LINE" ] || return 0
    LINE=${LINE#*,}
    printf '%s' "${LINE#*,}"
}

persona_ai_target_count() {
    local N
    N=$(grep -c '^PKG=' "$(persona_dir "$1")/android_id.conf" 2>/dev/null)
    printf '%s' "${N:-0}"
}

persona_ai_enabled() {
    grep -q '^ENABLED$' "$(persona_dir "$1")/android_id.conf" 2>/dev/null
}

persona_list_ids() {
    [ -d "$PERSONAS_DIR" ] || return 0
    local ID
    {
        for ID in "$PERSONAS_DIR"/*; do
            [ -d "$ID" ] || continue
            ID=${ID##*/}
            persona_valid_id "$ID" && printf '%s\n' "$ID"
        done
    } | sort
}

persona_count() { persona_list_ids | grep -c .; }

persona_default_name() {
    local N
    N=$(persona_list_ids | grep -c .)
    printf 'Persona %s' "$((N + 1))"
}

persona_regen_identifiers() {
    local DIR="$1" FILE SER BL
    FILE="${DIR}/identifiers.conf"
    [ -f "$FILE" ] || return 0
    SER=$(generate_serial)
    BL="cheetah-1.2-$(generate_hex 8)"
    sed -i \
        -e "s|^ENABLED,ro.serialno,.*|ENABLED,ro.serialno,${SER}|" \
        -e "s|^ENABLED,ro.boot.serialno,.*|ENABLED,ro.boot.serialno,${SER}|" \
        -e "s|^ENABLED,ro.bootloader,.*|ENABLED,ro.bootloader,${BL}|" \
        -e "s|^DISABLED,ro.serialno,.*|DISABLED,ro.serialno,${SER}|" \
        -e "s|^DISABLED,ro.boot.serialno,.*|DISABLED,ro.boot.serialno,${SER}|" \
        -e "s|^DISABLED,ro.bootloader,.*|DISABLED,ro.bootloader,${BL}|" \
        "$FILE" 2>/dev/null
}

persona_freeze() {
    local DIR="$1" CONF
    for CONF in device_identity.conf build_info.conf identifiers.conf custom.conf; do
        [ -f "${DIR}/${CONF}" ] && freeze_config_generators "${DIR}/${CONF}"
    done
}

persona_seed_defaults() {
    local DIR="$1" CONF
    [ -n "$DIR" ] || { PERSONA_ERROR="No persona directory"; return 1; }
    mkdir -p "$DIR" 2>/dev/null || { PERSONA_ERROR="Could not create persona directory"; return 1; }
    chmod 700 "$DIR" 2>/dev/null

    for CONF in device_identity.conf build_info.conf identifiers.conf custom.conf; do
        if [ -f "${MODULE_CONFIG_DIR}/${CONF}" ]; then
            cp "${MODULE_CONFIG_DIR}/${CONF}" "${DIR}/${CONF}" 2>/dev/null
        elif [ -f "${CONFIG_DIR}/${CONF}" ]; then
            cp "${CONFIG_DIR}/${CONF}" "${DIR}/${CONF}" 2>/dev/null
        else
            : > "${DIR}/${CONF}"
        fi
        chmod 600 "${DIR}/${CONF}" 2>/dev/null
    done

    {
        echo "# DeviceSpoofLabs - Android ID (SSAID) spoof config"
        echo "# Managed by the WebUI. value is applied to each PKG's settings_ssaid.xml entry."
        echo "DISABLED"
        echo "VALUE=$(generate_hex 16)"
        echo "USER=0"
    } > "${DIR}/android_id.conf" 2>/dev/null
    chmod 600 "${DIR}/android_id.conf" 2>/dev/null

    persona_regen_identifiers "$DIR"
    persona_freeze "$DIR"
    return 0
}

persona_create() {
    local NAME="$1" ID DIR
    ID=$(persona_new_id)
    DIR=$(persona_dir "$ID")
    if [ -e "$DIR" ]; then PERSONA_ERROR="Persona id collision, try again"; return 1; fi
    persona_seed_defaults "$DIR" || return 1
    persona_write_meta "$ID" "$NAME" "$(date +%s)"
    printf '%s' "$ID"
}

persona_mirror_to_config() {
    local ID="$1" DIR CONF
    DIR=$(persona_dir "$ID")
    [ -d "$DIR" ] || { PERSONA_ERROR="Persona not found"; return 1; }
    mkdir -p "$CONFIG_DIR" 2>/dev/null
    for CONF in $PERSONA_CONF_FILES; do
        if [ -f "${DIR}/${CONF}" ]; then
            cp "${DIR}/${CONF}" "${CONFIG_DIR}/${CONF}" 2>/dev/null
            chmod 600 "${CONFIG_DIR}/${CONF}" 2>/dev/null
        fi
    done
    return 0
}

persona_sync_file_from_config() {
    local NAME="$1" ID DIR
    ID=$(persona_active_id) || return 0
    DIR=$(persona_dir "$ID")
    [ -d "$DIR" ] || return 0
    [ -f "${CONFIG_DIR}/${NAME}" ] || return 0
    cp "${CONFIG_DIR}/${NAME}" "${DIR}/${NAME}" 2>/dev/null
    chmod 600 "${DIR}/${NAME}" 2>/dev/null
}

persona_active_id() {
    local ID
    [ -f "$ACTIVE_PERSONA_FILE" ] || return 1
    ID=$(cat "$ACTIVE_PERSONA_FILE" 2>/dev/null)
    ID=$(printf '%s' "$ID" | tr -d ' \t\n\r')
    persona_valid_id "$ID" || return 1
    persona_exists "$ID" || return 1
    printf '%s' "$ID"
}

persona_activate() {
    local ID="$1" DIR
    persona_valid_id "$ID" && persona_exists "$ID" || { PERSONA_ERROR="No such persona"; return 1; }
    DIR=$(persona_dir "$ID")

    ensure_backup || { PERSONA_ERROR="Could not capture device backup"; return 1; }
    persona_freeze "$DIR"
    persona_mirror_to_config "$ID" || return 1

    printf '%s' "$ID" > "$ACTIVE_PERSONA_FILE" 2>/dev/null
    chmod 600 "$ACTIVE_PERSONA_FILE" 2>/dev/null
    touch "$PERSONA_FLAG" 2>/dev/null
    mark_reboot
    log "Persona activated: $ID ($(persona_get_name "$ID"))"
    return 0
}

persona_deactivate() {
    local ID
    ID=$(persona_active_id 2>/dev/null)
    ai_set_enabled 0
    rm -f "$PERSONA_FLAG" 2>/dev/null
    rm -f "$ACTIVE_PERSONA_FILE" 2>/dev/null
    mark_reboot
    [ -n "$ID" ] && log "Persona deactivated: $ID"
    return 0
}

persona_rename() {
    local ID="$1" NAME="$2"
    persona_valid_id "$ID" && persona_exists "$ID" || { PERSONA_ERROR="No such persona"; return 1; }
    persona_write_meta "$ID" "$NAME" "$(persona_get_created "$ID")"
    log "Persona renamed: $ID"
    return 0
}

persona_delete() {
    local ID="$1"
    persona_valid_id "$ID" && persona_exists "$ID" || { PERSONA_ERROR="No such persona"; return 1; }
    if [ "$(persona_active_id 2>/dev/null)" = "$ID" ]; then
        persona_deactivate
    fi
    rm -rf "$(persona_dir "$ID")" 2>/dev/null
    log "Persona deleted: $ID"
    return 0
}

ensure_persona_store() {
    mkdir -p "$PERSONAS_DIR" 2>/dev/null
    chmod 700 "$PERSONAS_DIR" 2>/dev/null

    case "$(persona_list_ids)" in
        ?*) return 0 ;;
    esac

    if [ ! -f "$PERSONA_FLAG" ] && [ ! -f "$BACKUP_FILE" ]; then
        return 0
    fi
    [ -f "${CONFIG_DIR}/device_identity.conf" ] || return 0

    local ID DIR CONF
    ID=$(persona_new_id)
    DIR=$(persona_dir "$ID")
    mkdir -p "$DIR" 2>/dev/null || return 0
    chmod 700 "$DIR" 2>/dev/null
    for CONF in $PERSONA_CONF_FILES; do
        if [ -f "${CONFIG_DIR}/${CONF}" ]; then
            cp "${CONFIG_DIR}/${CONF}" "${DIR}/${CONF}" 2>/dev/null
            chmod 600 "${DIR}/${CONF}" 2>/dev/null
        fi
    done
    if [ ! -f "${DIR}/android_id.conf" ]; then
        {
            echo "# DeviceSpoofLabs - Android ID (SSAID) spoof config"
            echo "DISABLED"
            echo "VALUE=$(generate_hex 16)"
            echo "USER=0"
        } > "${DIR}/android_id.conf" 2>/dev/null
        chmod 600 "${DIR}/android_id.conf" 2>/dev/null
    fi
    persona_write_meta "$ID" "Default" "$(date +%s)"

    if [ -f "$PERSONA_FLAG" ]; then
        printf '%s' "$ID" > "$ACTIVE_PERSONA_FILE" 2>/dev/null
        chmod 600 "$ACTIVE_PERSONA_FILE" 2>/dev/null
    fi
    log "Migrated existing config into persona $ID (Default)"
    return 0
}
