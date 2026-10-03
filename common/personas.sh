#!/system/bin/sh
# Named multi-persona store; one persona active at a time.

PERSONAS_DIR="${PERSONAS_DIR:-${DATA_DIR}/personas}"
ACTIVE_PERSONA_FILE="${ACTIVE_PERSONA_FILE:-${DATA_DIR}/active_persona}"
MODULE_CONFIG_DIR="${MODULE_CONFIG_DIR:-${MODDIR}/config}"

PERSONA_CONF_FILES="device_identity.conf build_info.conf identifiers.conf custom.conf android_id.conf"

PERSONA_ERROR=""

# echo, not printf: that is a process on Android's mksh. An id is [a-z0-9_] by the time it gets here.
persona_dir() { echo "${PERSONAS_DIR}/${1}"; }

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

# Control characters never reach a stored name (they would break the meta file and the JSON).
# A character class: toybox's tr does not expand a range written with escapes, and building the set
# with printf is a process at every start.
persona_clean_name() {
    LC_ALL=C tr -d '[:cntrl:]'
}

persona_write_meta() {
    local ID="$1" NAME="$2" CREATED="$3" DIR
    DIR=$(persona_dir "$ID")
    NAME=$(printf '%s' "$NAME" | persona_clean_name | cut -c1-64)
    [ -n "$NAME" ] || NAME="Persona"
    case "$CREATED" in '' | *[!0-9]*) CREATED=$(date +%s) ;; esac
    {
        printf 'NAME=%s\n' "$NAME"
        printf 'CREATED=%s\n' "$CREATED"
    } > "${DIR}/meta" 2>/dev/null
    chmod 600 "${DIR}/meta" 2>/dev/null
}

# Read with the shell, not grep: toybox grep answers "Binary file ... matches" for odd bytes.
persona_meta_value() {
    local FILE LINE
    FILE="$(persona_dir "$1")/meta"
    [ -f "$FILE" ] || return 0
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            "$2="*)
                printf '%s' "${LINE#"$2="}"
                return 0
                ;;
        esac
    done < "$FILE"
}

persona_get_name() {
    local NAME
    NAME=$(persona_meta_value "$1" NAME | persona_clean_name)
    [ -n "$NAME" ] || NAME="Persona"
    printf '%s' "$NAME"
}

persona_get_created() {
    persona_meta_value "$1" CREATED
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
            persona_valid_id "$ID" && echo "$ID"
        done
    } | sort
}

persona_count() { persona_list_ids | grep -c .; }

persona_regen_identifiers() {
    local DIR="$1" FILE SER
    FILE="${DIR}/identifiers.conf"
    [ -f "$FILE" ] || return 0
    SER=$(generate_serial)
    sed -i \
        -e "s|^ENABLED,ro.serialno,.*|ENABLED,ro.serialno,${SER}|" \
        -e "s|^DISABLED,ro.serialno,.*|DISABLED,ro.serialno,${SER}|" \
        "$FILE" 2>/dev/null
}

persona_freeze() {
    local DIR="$1" CONF
    for CONF in device_identity.conf build_info.conf identifiers.conf custom.conf; do
        [ -f "${DIR}/${CONF}" ] && freeze_config_generators "${DIR}/${CONF}"
    done
}

persona_write_ai_default() {
    local DIR="$1"
    {
        echo "# DeviceSpoofLabs - Android ID (SSAID) spoof config"
        echo "# Managed by the WebUI. value is applied to each PKG's settings_ssaid.xml entry."
        echo "DISABLED"
        echo "VALUE=$(generate_hex 16)"
        echo "USER=0"
    } > "${DIR}/android_id.conf" 2>/dev/null
    chmod 600 "${DIR}/android_id.conf" 2>/dev/null
}

persona_copy_template() {
    local DIR="$1" CONF="$2"
    if [ -f "${MODULE_CONFIG_DIR}/${CONF}" ]; then
        cp "${MODULE_CONFIG_DIR}/${CONF}" "${DIR}/${CONF}" 2>/dev/null
    elif [ -f "${CONFIG_DIR}/${CONF}" ]; then
        cp "${CONFIG_DIR}/${CONF}" "${DIR}/${CONF}" 2>/dev/null
    else
        : > "${DIR}/${CONF}"
    fi
    chmod 600 "${DIR}/${CONF}" 2>/dev/null
}

persona_seed_defaults() {
    local DIR="$1" KEY="$2" CONF
    [ -n "$DIR" ] || { PERSONA_ERROR="No persona directory"; return 1; }
    device_load "$KEY" || { PERSONA_ERROR="Unknown device: ${KEY}"; return 1; }
    mkdir -p "$DIR" 2>/dev/null || { PERSONA_ERROR="Could not create persona directory"; return 1; }
    chmod 700 "$DIR" 2>/dev/null

    for CONF in device_identity.conf build_info.conf identifiers.conf custom.conf; do
        persona_copy_template "$DIR" "$CONF"
    done

    device_render "${DIR}/device_identity.conf" && device_render "${DIR}/build_info.conf" \
        || { PERSONA_ERROR="Could not write device values"; return 1; }
    persona_write_ai_default "$DIR"
    persona_regen_identifiers "$DIR"
    persona_freeze "$DIR"
    return 0
}

persona_create() {
    local NAME="$1" KEY="$2" ID DIR TRY=0
    [ -n "$KEY" ] || KEY=$(device_resolve_key "")
    while :; do
        ID=$(persona_new_id)
        DIR=$(persona_dir "$ID")
        [ -e "$DIR" ] || break
        # The id is the second plus four hex digits: a script that makes several in one second can
        # draw the same one twice. Draw again.
        TRY=$((TRY + 1))
        [ "$TRY" -lt 5 ] || { PERSONA_ERROR="Persona id collision, try again"; return 1; }
    done
    persona_seed_defaults "$DIR" "$KEY" || { rm -rf "$DIR" 2>/dev/null; return 1; }
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
    local ID LINE N=0
    [ -f "$ACTIVE_PERSONA_FILE" ] || return 1
    ID=""
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        ID="${ID}${LINE}"
        N=$((N + 1))
        # The file holds just the id. Many more lines than that is not an id (and joining them is
        # quadratic in mksh).
        [ "$N" -le 8 ] || return 1
    done < "$ACTIVE_PERSONA_FILE"
    # Blanks or a carriage return around it are dropped, as before.
    case "$ID" in
        *[!a-z0-9_]*) ID=$(printf '%s' "$ID" | tr -d ' \t\n\r') ;;
    esac
    persona_valid_id "$ID" || return 1
    persona_exists "$ID" || return 1
    echo "$ID"
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
    # A persona switched on by hand starts with a clean count of unfinished boots.
    rm -f "$BOOT_ATTEMPTS_FILE" "$AUTO_DISABLED_FILE" 2>/dev/null
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
    if [ -f "$AUTO_DISABLED_FILE" ] && [ "$(tr -d ' \t\n\r' < "$AUTO_DISABLED_FILE")" = "$ID" ]; then
        rm -f "$AUTO_DISABLED_FILE" 2>/dev/null
    fi
    log "Persona deleted: $ID"
    return 0
}

persona_slug() {
    local S
    S=$(printf '%s' "$1" | LC_ALL=C tr 'A-Z' 'a-z' | LC_ALL=C tr -c 'a-z0-9' '-' | tr -s '-' | cut -c1-40)
    S=${S#-}
    S=${S%-}
    [ -n "$S" ] || S="persona"
    printf '%s' "$S"
}

persona_export() {
    local ID="$1" DEST="$2" DIR NAME FILE TMP CONF LINE BODY NL='
'
    PERSONA_EXPORTED=""
    persona_valid_id "$ID" && persona_exists "$ID" || { PERSONA_ERROR="No such persona: ${ID}"; return 1; }
    DIR=$(persona_dir "$ID")
    NAME=$(persona_get_name "$ID")
    FILE="${DEST}/$(persona_slug "$NAME")-${ID#"${ID%????}"}.persona"
    TMP="${FILE}.tmp.$$"

    {
        echo "# DeviceSpoofLabs persona. Import: WebUI Personas > Import, or devicespooflabs persona-import <file>"
        echo "DSL_PERSONA=1"
        echo "ID=${ID}"
        printf 'NAME=%s\n' "$NAME"
        printf 'CREATED=%s\n' "$(persona_get_created "$ID")"
        for CONF in $PERSONA_CONF_FILES; do
            echo "[${CONF}]"
            [ -f "${DIR}/${CONF}" ] || continue
            BODY=""
            while IFS= read -r LINE || [ -n "$LINE" ]; do
                BODY="${BODY}${LINE}${NL}"
            done < "${DIR}/${CONF}"
            printf '%s' "$BODY"
        done
    } > "$TMP" 2>/dev/null && mv -f "$TMP" "$FILE" 2>/dev/null || {
        rm -f "$TMP" 2>/dev/null
        PERSONA_ERROR="Could not write ${FILE}"
        return 1
    }

    PERSONA_EXPORTED="$FILE"
    log "Persona exported: $ID -> $FILE"
    return 0
}

persona_import_ai_valid() {
    local LINE STATES=0 VALUES=0
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            '' | '#'*) ;;
            ENABLED | DISABLED) STATES=$((STATES + 1)) ;;
            VALUE=*) ai_valid_value "${LINE#VALUE=}" || return 1; VALUES=$((VALUES + 1)) ;;
            USER=*) ai_valid_user "${LINE#USER=}" || return 1 ;;
            PKG=*) ai_valid_pkg "${LINE#PKG=}" || return 1 ;;
            *) return 1 ;;
        esac
    done < "$1"
    [ "$STATES" -eq 1 ] && [ "$VALUES" -eq 1 ]
}

persona_import() {
    local FILE="$1" STAGE SRC SIZE LINE CONF DIR SECTION="" HEADER=0 ERR="" ID="" NAME="" CREATED="" REL=""
    PERSONA_IMPORTED_ID=""
    PERSONA_IMPORTED_NAME=""
    PERSONA_IMPORTED_RELEASE=""

    if [ -L "$FILE" ] || [ ! -f "$FILE" ]; then PERSONA_ERROR="Not a regular file: ${FILE}"; return 1; fi
    SIZE=$(wc -c < "$FILE" 2>/dev/null | tr -d ' ')
    case "$SIZE" in '' | *[!0-9]*) PERSONA_ERROR="Could not read ${FILE}"; return 1 ;; esac
    [ "$SIZE" -le 65536 ] || { PERSONA_ERROR="File is larger than 64 KiB"; return 1; }

    mkdir -p "$PERSONAS_DIR" 2>/dev/null
    STAGE="${PERSONAS_DIR}/.import.$$"
    rm -rf "$STAGE" 2>/dev/null
    mkdir "$STAGE" 2>/dev/null || { PERSONA_ERROR="Could not create staging directory"; return 1; }
    chmod 700 "$STAGE" 2>/dev/null
    SRC="${STAGE}/.source"

    tr -d '\r' < "$FILE" > "$SRC" 2>/dev/null || ERR="Could not read ${FILE}"
    if [ -z "$ERR" ] && LC_ALL=C grep -q "$(printf '[\001-\010\013\014\016-\037]')" "$SRC" 2>/dev/null; then
        ERR="File contains control characters"
    fi

    if [ -z "$ERR" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            [ "${#LINE}" -le 512 ] || { ERR="A line is longer than 512 bytes"; break; }
            case "$LINE" in
                '['*']')
                    [ "$HEADER" -eq 1 ] || { ERR="Not a DeviceSpoofLabs persona file"; break; }
                    case "$LINE" in
                        '[device_identity.conf]') CONF=device_identity.conf ;;
                        '[build_info.conf]')      CONF=build_info.conf ;;
                        '[identifiers.conf]')     CONF=identifiers.conf ;;
                        '[custom.conf]')          CONF=custom.conf ;;
                        '[android_id.conf]')      CONF=android_id.conf ;;
                        *) ERR="Unknown section ${LINE}"; break ;;
                    esac
                    [ ! -e "${STAGE}/${CONF}" ] || { ERR="Duplicate section ${LINE}"; break; }
                    : > "${STAGE}/${CONF}"
                    SECTION=$CONF
                    continue
                    ;;
            esac
            if [ -n "$SECTION" ]; then
                printf '%s\n' "$LINE" >> "${STAGE}/${SECTION}"
                case "${SECTION}:${LINE}" in
                    build_info.conf:ENABLED,ro.build.fingerprint,*:*/*)
                        [ -n "$REL" ] || { REL=${LINE#*:}; REL=${REL%%/*}; }
                        ;;
                esac
                continue
            fi
            case "$LINE" in
                '' | '#'*) ;;
                DSL_PERSONA=1) HEADER=1 ;;
                *)
                    [ "$HEADER" -eq 1 ] || { ERR="Not a DeviceSpoofLabs persona file"; break; }
                    case "$LINE" in
                        ID=*)      ID=${LINE#ID=} ;;
                        NAME=*)    NAME=${LINE#NAME=} ;;
                        CREATED=*) CREATED=${LINE#CREATED=} ;;
                    esac
                    ;;
            esac
        done < "$SRC"
    fi
    rm -f "$SRC" 2>/dev/null

    if [ -z "$ERR" ]; then
        if [ "$HEADER" -ne 1 ]; then
            ERR="Not a DeviceSpoofLabs persona file"
        elif [ ! -f "${STAGE}/device_identity.conf" ] || [ ! -f "${STAGE}/build_info.conf" ]; then
            ERR="Missing [device_identity.conf] or [build_info.conf] section"
        elif [ -f "${STAGE}/android_id.conf" ] && ! persona_import_ai_valid "${STAGE}/android_id.conf"; then
            ERR="Invalid [android_id.conf] section"
        fi
    fi
    if [ -n "$ERR" ]; then
        rm -rf "$STAGE" 2>/dev/null
        PERSONA_ERROR="$ERR"
        return 1
    fi

    persona_valid_id "$ID" && [ "${#ID}" -le 40 ] || ID=""
    if [ -n "$ID" ] && persona_exists "$ID"; then
        rm -rf "$STAGE" 2>/dev/null
        PERSONA_IMPORTED_ID="$ID"
        PERSONA_IMPORTED_NAME=$(persona_get_name "$ID")
        return 2
    fi
    [ -n "$ID" ] || ID=$(persona_new_id)

    for CONF in identifiers.conf custom.conf; do
        [ -f "${STAGE}/${CONF}" ] || persona_copy_template "$STAGE" "$CONF"
    done
    [ -f "${STAGE}/android_id.conf" ] || persona_write_ai_default "$STAGE"
    chmod 600 "$STAGE"/*.conf 2>/dev/null

    DIR=$(persona_dir "$ID")
    if [ -e "$DIR" ] || ! mv "$STAGE" "$DIR" 2>/dev/null; then
        rm -rf "$STAGE" 2>/dev/null
        PERSONA_ERROR="Could not save the imported persona"
        return 1
    fi
    case "$CREATED" in '' | *[!0-9]*) CREATED="" ;; esac
    persona_write_meta "$ID" "$NAME" "$CREATED"
    persona_freeze "$DIR"

    PERSONA_IMPORTED_ID="$ID"
    PERSONA_IMPORTED_NAME=$(persona_get_name "$ID")
    # The Android release of the imported build, for the "made for another version" notice.
    case "$REL" in '' | *[!0-9.]*) REL="" ;; esac
    PERSONA_IMPORTED_RELEASE="$REL"
    log "Persona imported: $ID ($PERSONA_IMPORTED_NAME) from $FILE"
    return 0
}

ensure_persona_store() {
    local FIRST_RUN=0
    if [ ! -d "$PERSONAS_DIR" ]; then
        FIRST_RUN=1
        mkdir -p "$PERSONAS_DIR" 2>/dev/null
        chmod 700 "$PERSONAS_DIR" 2>/dev/null
    fi

    # The pre-persona config is migrated once, when the store is created. Later an empty
    # store means the user deleted every persona, so nothing is recreated.
    [ "$FIRST_RUN" -eq 1 ] || return 0

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
