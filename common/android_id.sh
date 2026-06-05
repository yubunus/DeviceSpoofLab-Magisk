#!/system/bin/sh
# Android ID (SSAID) spoofing for selected packages.

DATA_DIR="${DATA_DIR:-/data/adb/devicespooflab}"
CONFIG_DIR="${CONFIG_DIR:-${DATA_DIR}/config}"
ANDROID_ID_CONF="${ANDROID_ID_CONF:-${CONFIG_DIR}/android_id.conf}"
SSAID_BACKUP_DIR="${SSAID_BACKUP_DIR:-${DATA_DIR}/ssaid_backup}"
AI_APPLIED_STATE="${AI_APPLIED_STATE:-${DATA_DIR}/ssaid_applied.conf}"

AI_APPLIED_COUNT=0
AI_SKIPPED_PKGS=""
AI_TARGET_COUNT=0
AI_ERROR=""
AI_ABX2XML=""
AI_XML2ABX=""

ai_log() {
    case "$(type log 2>/dev/null)" in
        *function*) log "$1" ;;
    esac
}

ai_valid_value() {
    case "$1" in
        '' | *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 16 ]
}

ai_valid_pkg() {
    case "$1" in
        '' | *[!A-Za-z0-9._]*) return 1 ;;
        *) return 0 ;;
    esac
}

ai_valid_user() {
    case "$1" in
        '' | *[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

ai_is_enabled() {
    [ -f "$ANDROID_ID_CONF" ] || return 1
    grep -q '^ENABLED$' "$ANDROID_ID_CONF" 2>/dev/null
}

ai_get_value() {
    [ -f "$ANDROID_ID_CONF" ] || return 1
    local V
    V=$(grep -m1 '^VALUE=' "$ANDROID_ID_CONF" 2>/dev/null)
    V=${V#VALUE=}
    printf '%s' "$V"
}

ai_get_user() {
    local U=""
    [ -f "$ANDROID_ID_CONF" ] && U=$(grep -m1 '^USER=' "$ANDROID_ID_CONF" 2>/dev/null)
    U=${U#USER=}
    ai_valid_user "$U" || U=0
    printf '%s' "$U"
}

ai_get_targets() {
    [ -f "$ANDROID_ID_CONF" ] || return 0
    local LINE PKG
    grep '^PKG=' "$ANDROID_ID_CONF" 2>/dev/null | while IFS= read -r LINE; do
        PKG=${LINE#PKG=}
        ai_valid_pkg "$PKG" && printf '%s\n' "$PKG"
    done
}

ai_target_count() {
    ai_get_targets | grep -c . 2>/dev/null
}

ai_write_config() {
    local ENABLED="$1" VALUE="$2" USER="$3"
    shift 3
    ai_valid_value "$VALUE" || { AI_ERROR="Invalid Android ID (need 16 hex chars)"; return 1; }
    ai_valid_user "$USER" || USER=0

    mkdir -p "$CONFIG_DIR" 2>/dev/null
    local TMP="${ANDROID_ID_CONF}.tmp.$$"
    {
        echo "# DeviceSpoofLabs - Android ID (SSAID) spoof config"
        echo "# Managed by the WebUI. value is applied to each PKG's settings_ssaid.xml entry."
        [ "$ENABLED" = "1" ] && echo "ENABLED" || echo "DISABLED"
        echo "VALUE=${VALUE}"
        echo "USER=${USER}"
        local P
        for P in "$@"; do
            ai_valid_pkg "$P" && echo "PKG=${P}"
        done
        :
    } > "$TMP" 2>/dev/null || { rm -f "$TMP"; AI_ERROR="Could not write config"; return 1; }
    chmod 600 "$TMP" 2>/dev/null
    mv -f "$TMP" "$ANDROID_ID_CONF" 2>/dev/null || { rm -f "$TMP"; AI_ERROR="Could not save config"; return 1; }
    return 0
}

ai_set_enabled() {
    [ -f "$ANDROID_ID_CONF" ] || return 0
    if [ "$1" = "1" ]; then
        sed -i 's/^DISABLED$/ENABLED/' "$ANDROID_ID_CONF" 2>/dev/null
    else
        sed -i 's/^ENABLED$/DISABLED/' "$ANDROID_ID_CONF" 2>/dev/null
    fi
}

ai_ssaid_path() {
    printf '/data/system/users/%s/settings_ssaid.xml' "$1"
}

ai_is_abx() {
    local FILE="$1" MAGIC
    MAGIC=$(dd if="$FILE" bs=1 count=3 2>/dev/null)
    if [ -n "$MAGIC" ]; then
        [ "$MAGIC" = "ABX" ]
        return
    fi
    case "$(file "$FILE" 2>/dev/null)" in
        *ABX* | *"Android Binary XML"* | *binary*) return 0 ;;
        *) return 1 ;;
    esac
}

ai_backup_ssaid() {
    local AUSER="$1" FILE="$2" DEST
    DEST="${SSAID_BACKUP_DIR}/user${AUSER}_settings_ssaid.xml.orig"
    [ -f "$DEST" ] && return 0
    mkdir -p "$SSAID_BACKUP_DIR" 2>/dev/null
    chmod 700 "$SSAID_BACKUP_DIR" 2>/dev/null
    if cp "$FILE" "$DEST" 2>/dev/null; then
        chmod 600 "$DEST" 2>/dev/null
        ai_log "[android-id] backed up original SSAID for user ${AUSER}"
    fi
}

ai_rewrite_plain() {
    local XML="$1" NEW="$2" PKG ESC TMP
    TMP="${XML}.r.$$"
    AI_APPLIED_COUNT=0
    AI_SKIPPED_PKGS=""
    while IFS= read -r PKG; do
        [ -n "$PKG" ] || continue
        if grep -qF "package=\"${PKG}\"" "$XML" 2>/dev/null; then
            ESC=$(printf '%s' "$PKG" | sed 's/\./\\./g')
            if sed "/package=\"${ESC}\"/ s/ value=\"[^\"]*\"/ value=\"${NEW}\"/" "$XML" > "$TMP" 2>/dev/null; then
                mv -f "$TMP" "$XML" 2>/dev/null
                AI_APPLIED_COUNT=$((AI_APPLIED_COUNT + 1))
            else
                rm -f "$TMP"
                AI_SKIPPED_PKGS="${AI_SKIPPED_PKGS} ${PKG}"
            fi
        else
            AI_SKIPPED_PKGS="${AI_SKIPPED_PKGS} ${PKG}"
        fi
    done
    AI_SKIPPED_PKGS="${AI_SKIPPED_PKGS# }"
}

ai_resolve_abx_tools() {
    AI_ABX2XML="$(command -v abx2xml 2>/dev/null)"
    AI_XML2ABX="$(command -v xml2abx 2>/dev/null)"
    [ -n "$AI_ABX2XML" ] || { [ -x /system/bin/abx2xml ] && AI_ABX2XML=/system/bin/abx2xml; }
    [ -n "$AI_XML2ABX" ] || { [ -x /system/bin/xml2abx ] && AI_XML2ABX=/system/bin/xml2abx; }
    [ -n "$AI_ABX2XML" ] && [ -n "$AI_XML2ABX" ]
}

ai_apply_user() {
    local AUSER="$1" VALUE="$2"
    local FILE PLAIN ABX_OUT IS_ABX=0 TGT_FILE
    AI_APPLIED_COUNT=0
    AI_SKIPPED_PKGS=""
    AI_ERROR=""

    ai_valid_value "$VALUE" || { AI_ERROR="Invalid Android ID value"; return 1; }
    ai_valid_user "$AUSER"   || { AI_ERROR="Invalid user id"; return 1; }

    FILE=$(ai_ssaid_path "$AUSER")
    if [ ! -f "$FILE" ]; then
        AI_ERROR="No SSAID store for user ${AUSER} (${FILE})"
        return 1
    fi

    ai_backup_ssaid "$AUSER" "$FILE"

    mkdir -p "$DATA_DIR" 2>/dev/null
    PLAIN="${DATA_DIR}/.ssaid_${AUSER}.$$.xml"

    if ai_is_abx "$FILE"; then
        IS_ABX=1
        ai_resolve_abx_tools || { AI_ERROR="SSAID file is ABX but abx2xml/xml2abx are unavailable"; return 1; }
        if ! "$AI_ABX2XML" "$FILE" "$PLAIN" 2>/dev/null; then
            rm -f "$PLAIN"
            AI_ERROR="abx2xml conversion failed"
            return 1
        fi
    else
        if ! cp "$FILE" "$PLAIN" 2>/dev/null; then
            rm -f "$PLAIN"
            AI_ERROR="Could not read SSAID file"
            return 1
        fi
    fi
    chmod 600 "$PLAIN" 2>/dev/null

    TGT_FILE="${DATA_DIR}/.ssaid_tgt.$$"
    ai_get_targets > "$TGT_FILE" 2>/dev/null
    ai_rewrite_plain "$PLAIN" "$VALUE" < "$TGT_FILE"
    rm -f "$TGT_FILE"

    if [ "$AI_APPLIED_COUNT" -eq 0 ]; then
        rm -f "$PLAIN"
        ai_log "[android-id] user ${AUSER}: no matching packages (skipped:${AI_SKIPPED_PKGS:-none})"
        return 0
    fi

    if [ "$IS_ABX" -eq 1 ]; then
        ABX_OUT="${DATA_DIR}/.ssaid_${AUSER}.$$.abx"
        if ! "$AI_XML2ABX" "$PLAIN" "$ABX_OUT" 2>/dev/null; then
            rm -f "$PLAIN" "$ABX_OUT"
            AI_ERROR="xml2abx conversion failed"
            return 1
        fi
        if [ ! -s "$ABX_OUT" ]; then
            rm -f "$PLAIN" "$ABX_OUT"
            AI_ERROR="xml2abx produced an empty file; not writing"
            return 1
        fi
        if ! cat "$ABX_OUT" > "$FILE" 2>/dev/null; then
            rm -f "$PLAIN" "$ABX_OUT"
            AI_ERROR="Could not write SSAID file"
            return 1
        fi
        rm -f "$ABX_OUT"
    else
        if [ ! -s "$PLAIN" ]; then
            rm -f "$PLAIN"
            AI_ERROR="Refusing to write an empty SSAID file"
            return 1
        fi
        if ! cat "$PLAIN" > "$FILE" 2>/dev/null; then
            rm -f "$PLAIN"
            AI_ERROR="Could not write SSAID file"
            return 1
        fi
    fi
    rm -f "$PLAIN"

    chmod 600 "$FILE" 2>/dev/null
    chown 1000:1000 "$FILE" 2>/dev/null
    restorecon "$FILE" 2>/dev/null || chcon u:object_r:system_data_file:s0 "$FILE" 2>/dev/null

    ai_log "[android-id] user ${AUSER}: set ${AI_APPLIED_COUNT} package(s) to ${VALUE}${IS_ABX:+ (abx)}${AI_SKIPPED_PKGS:+ skipped:${AI_SKIPPED_PKGS}}"
    return 0
}

ai_apply_config() {
    local VALUE USER RC
    AI_TARGET_COUNT=$(ai_target_count)
    [ "${AI_TARGET_COUNT:-0}" -gt 0 ] || { ai_log "[android-id] no targets configured"; return 0; }

    VALUE=$(ai_get_value)
    if ! ai_valid_value "$VALUE"; then
        AI_ERROR="Configured Android ID is invalid"
        return 1
    fi
    USER=$(ai_get_user)
    ai_apply_user "$USER" "$VALUE"
    RC=$?
    if [ "$RC" -eq 0 ] && [ "${AI_APPLIED_COUNT:-0}" -gt 0 ]; then
        ai_record_applied "$USER" $(ai_get_targets)
    fi
    return "$RC"
}

ai_record_applied() {
    local USER="$1" P
    shift
    {
        echo "USER=${USER}"
        for P in "$@"; do
            ai_valid_pkg "$P" && echo "PKG=${P}"
        done
        :
    } > "$AI_APPLIED_STATE" 2>/dev/null
    chmod 600 "$AI_APPLIED_STATE" 2>/dev/null
}

ai_applied_user() {
    local U=""
    [ -f "$AI_APPLIED_STATE" ] && U=$(grep -m1 '^USER=' "$AI_APPLIED_STATE" 2>/dev/null)
    U=${U#USER=}
    ai_valid_user "$U" || U=0
    printf '%s' "$U"
}

ai_applied_targets() {
    [ -f "$AI_APPLIED_STATE" ] || return 0
    local LINE PKG
    grep '^PKG=' "$AI_APPLIED_STATE" 2>/dev/null | while IFS= read -r LINE; do
        PKG=${LINE#PKG=}
        ai_valid_pkg "$PKG" && printf '%s\n' "$PKG"
    done
}

ai_value_for_pkg() {
    local F="$1" PKG="$2" LINE
    LINE=$(grep -m1 "package=\"${PKG}\"" "$F" 2>/dev/null) || return 1
    [ -n "$LINE" ] || return 1
    printf '%s' "$LINE" | sed -n 's/.* value="\([^"]*\)".*/\1/p'
}

ai_set_pkg_value() {
    local XML="$1" PKG="$2" VAL="$3" ESC TMP
    TMP="${XML}.s.$$"
    ESC=$(printf '%s' "$PKG" | sed 's/\./\\./g')
    if sed "/package=\"${ESC}\"/ s/ value=\"[^\"]*\"/ value=\"${VAL}\"/" "$XML" > "$TMP" 2>/dev/null; then
        mv -f "$TMP" "$XML" 2>/dev/null
    else
        rm -f "$TMP"
    fi
}

ai_restore_targets() {
    local AUSER="$1"
    shift
    ai_valid_user "$AUSER" || return 1
    [ "$#" -gt 0 ] || return 0

    local FILE DEST PLAIN BPLAIN ABX_OUT IS_ABX=0 PKG ORIG CHANGED=0
    FILE=$(ai_ssaid_path "$AUSER")
    DEST="${SSAID_BACKUP_DIR}/user${AUSER}_settings_ssaid.xml.orig"
    [ -f "$DEST" ] || return 0
    [ -f "$FILE" ] || return 0

    mkdir -p "$DATA_DIR" 2>/dev/null
    PLAIN="${DATA_DIR}/.ssaid_rv_${AUSER}.$$.xml"
    BPLAIN="${DATA_DIR}/.ssaid_bk_${AUSER}.$$.xml"

    if ai_is_abx "$FILE"; then
        IS_ABX=1
        ai_resolve_abx_tools || { rm -f "$PLAIN" "$BPLAIN"; AI_ERROR="abx tools unavailable"; return 1; }
        "$AI_ABX2XML" "$FILE" "$PLAIN" 2>/dev/null || { rm -f "$PLAIN" "$BPLAIN"; AI_ERROR="abx2xml failed"; return 1; }
    else
        cp "$FILE" "$PLAIN" 2>/dev/null || { rm -f "$PLAIN" "$BPLAIN"; return 1; }
    fi
    if ai_is_abx "$DEST"; then
        ai_resolve_abx_tools || { rm -f "$PLAIN" "$BPLAIN"; AI_ERROR="abx tools unavailable"; return 1; }
        "$AI_ABX2XML" "$DEST" "$BPLAIN" 2>/dev/null || { rm -f "$PLAIN" "$BPLAIN"; AI_ERROR="abx2xml failed"; return 1; }
    else
        cp "$DEST" "$BPLAIN" 2>/dev/null || { rm -f "$PLAIN" "$BPLAIN"; return 1; }
    fi
    chmod 600 "$PLAIN" "$BPLAIN" 2>/dev/null

    for PKG in "$@"; do
        ai_valid_pkg "$PKG" || continue
        ORIG=$(ai_value_for_pkg "$BPLAIN" "$PKG") || continue
        ai_valid_value "$ORIG" || continue
        if grep -qF "package=\"${PKG}\"" "$PLAIN" 2>/dev/null; then
            ai_set_pkg_value "$PLAIN" "$PKG" "$ORIG"
            CHANGED=1
        fi
    done

    if [ "$CHANGED" -eq 0 ]; then
        rm -f "$PLAIN" "$BPLAIN"
        return 0
    fi

    if [ "$IS_ABX" -eq 1 ]; then
        ABX_OUT="${DATA_DIR}/.ssaid_rv_${AUSER}.$$.abx"
        if ! "$AI_XML2ABX" "$PLAIN" "$ABX_OUT" 2>/dev/null || [ ! -s "$ABX_OUT" ]; then
            rm -f "$PLAIN" "$BPLAIN" "$ABX_OUT"; AI_ERROR="xml2abx failed"; return 1
        fi
        if ! cat "$ABX_OUT" > "$FILE" 2>/dev/null; then
            rm -f "$PLAIN" "$BPLAIN" "$ABX_OUT"; AI_ERROR="Could not write SSAID file"; return 1
        fi
        rm -f "$ABX_OUT"
    else
        if [ ! -s "$PLAIN" ] || ! cat "$PLAIN" > "$FILE" 2>/dev/null; then
            rm -f "$PLAIN" "$BPLAIN"; AI_ERROR="Could not write SSAID file"; return 1
        fi
    fi
    rm -f "$PLAIN" "$BPLAIN"

    chmod 600 "$FILE" 2>/dev/null
    chown 1000:1000 "$FILE" 2>/dev/null
    restorecon "$FILE" 2>/dev/null || chcon u:object_r:system_data_file:s0 "$FILE" 2>/dev/null
    ai_log "[android-id] reverted previously-spoofed package(s) to original for user ${AUSER}"
    return 0
}

ai_revert_last_applied() {
    [ -f "$AI_APPLIED_STATE" ] || return 0
    local PREV_USER PREV_TGTS
    PREV_USER=$(ai_applied_user)
    PREV_TGTS=$(ai_applied_targets)
    if [ -n "$PREV_TGTS" ] && ! ai_restore_targets "$PREV_USER" $PREV_TGTS; then
        return 1
    fi
    rm -f "$AI_APPLIED_STATE" 2>/dev/null
    return 0
}

ai_revert_current() {
    local CUR_USER CUR_TGTS
    CUR_TGTS=$(ai_get_targets)
    [ -n "$CUR_TGTS" ] || return 0
    CUR_USER=$(ai_get_user)
    ai_restore_targets "$CUR_USER" $CUR_TGTS
}

ai_boot_reconcile() {
    ai_revert_last_applied || return 1
    if [ -z "$PERSONA_FLAG" ] || [ ! -f "$PERSONA_FLAG" ]; then
        ai_revert_current || return 1
        ai_log "[android-id] no active persona - not applying Android ID"
        return 0
    fi
    if ai_is_enabled && [ "$(ai_target_count)" -gt 0 ]; then
        ai_apply_config
    fi
}

ai_boot_revert() {
    ai_revert_last_applied || return 1
    ai_revert_current || return 1
    ai_log "[android-id] module disabled - reverted Android ID to original"
    return 0
}
