#!/system/bin/sh
# Non-interactive control layer for the WebUI bridge and devicespooflabs CLI.

SCRIPT_DIR="${0%/*}"
MODDIR="${MODDIR:-/data/adb/modules/devicespooflab}"

[ -f "${SCRIPT_DIR}/state.sh" ] && . "${SCRIPT_DIR}/state.sh"
[ -f "${SCRIPT_DIR}/utils.sh" ] && . "${SCRIPT_DIR}/utils.sh"
[ -f "${SCRIPT_DIR}/value_resolver.sh" ] && . "${SCRIPT_DIR}/value_resolver.sh"
[ -f "${SCRIPT_DIR}/android_id.sh" ] && . "${SCRIPT_DIR}/android_id.sh"
[ -f "${SCRIPT_DIR}/personas.sh" ] && . "${SCRIPT_DIR}/personas.sh"

case "$(type ensure_persona_store 2>/dev/null)" in *function*) ensure_persona_store ;; esac

MODULE_ID="devicespooflab"
MODULE_NAME="DeviceSpoofLabs"

KSUWEBUI_PKG="io.github.a13e300.ksuwebui"
KSUWEBUI_ACTIVITY="io.github.a13e300.ksuwebui/.WebUIActivity"
KSUWEBUI_APK_URL="https://github.com/5ec1cff/KsuWebUIStandalone/releases/download/v1.0/KsuWebUI-1.0-34-release.apk"
KSUWEBUI_APK_SHA256="a99e9a66c79d94db7cc5cf0c12607df1790215423e3d917c937dc16093c8135d"
KSUWEBUI_APK_SIZE="1703779"
KSUWEBUI_RELEASE_PAGE="https://github.com/5ec1cff/KsuWebUIStandalone/releases/latest"

WEBUIX_PKG="com.dergoogler.mmrl.wx"
WEBUIX_ACTIVITY="com.dergoogler.mmrl.wx/.ui.activity.webui.WebUIActivity"

__JSON_TAB=$(printf '\t')
__JSON_CR=$(printf '\r')
__JSON_NL='
'

json_set() {
    case $1 in
        *\\*|*\"*|*"$__JSON_NL"*|*"$__JSON_TAB"*|*"$__JSON_CR"*)
            JSTR=$(printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\r//g' | tr '\n\t' '  ')
            JSTR=\"$JSTR\"
            ;;
        *)
            JSTR=\"$1\"
            ;;
    esac
}

json_str() {
    json_set "$1"
    printf '%s' "$JSTR"
}

emit_ok() {
    printf '{"ok":true,"message":%s}\n' "$(json_str "$1")"
}

emit_ok_reboot() {
    printf '{"ok":true,"reboot_required":true,"message":%s}\n' "$(json_str "$1")"
}

emit_error() {
    printf '{"ok":false,"message":%s}\n' "$(json_str "$1")"
}

get_version() {
    VERSION=$(grep '^version=' "${MODDIR}/module.prop" 2>/dev/null | head -n1 | cut -d= -f2)
    [ -n "$VERSION" ] || VERSION="3.0"
}

is_persona_active() {
    [ -f "$PERSONA_FLAG" ]
}

is_unsafe_props_enabled() {
    [ -f "${CONFIG_DIR}/allow_unsafe_props" ] && return 0
    [ "$(getprop persist.devicespooflab.allow_unsafe 2>/dev/null)" = "1" ] && return 0
    return 1
}

mark_reboot() {
    touch "$REBOOT_PENDING" 2>/dev/null
}

backup_value() {
    [ -f "$BACKUP_FILE" ] || return 0
    local LINE
    LINE=$(grep -m1 "^$1=" "$BACKUP_FILE" 2>/dev/null)
    [ -n "$LINE" ] && printf '%s' "${LINE#*=}"
}

configured_value() {
    local CONF FILE LINE
    for CONF in device_identity build_info identifiers custom; do
        FILE="${CONFIG_DIR}/${CONF}.conf"
        [ -f "$FILE" ] || continue
        LINE=$(grep -m1 "^ENABLED,$1," "$FILE" 2>/dev/null)
        if [ -n "$LINE" ]; then
            LINE=${LINE#*,}
            printf '%s' "${LINE#*,}"
            return 0
        fi
    done
}

create_backup() {
    mkdir -p "$(dirname "$BACKUP_FILE")" "$CONFIG_DIR" 2>/dev/null
    {
        echo "# DeviceSpoofLabs - Original Device Backup"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "# DO NOT EDIT - This is your restore point"
        echo ""
        local CONF FILE LINE PROP SEEN=" "
        for CONF in device_identity build_info identifiers; do
            FILE="${CONFIG_DIR}/${CONF}.conf"
            [ -f "$FILE" ] || continue
            while IFS= read -r LINE || [ -n "$LINE" ]; do
                case "$LINE" in ENABLED,*) ;; *) continue ;; esac
                PROP=$(echo "$LINE" | cut -d',' -f2)
                [ -n "$PROP" ] || continue
                case "$SEEN" in *" $PROP "*) continue ;; esac
                SEEN="${SEEN}${PROP} "
                echo "${PROP}=$(getprop "$PROP")"
            done < "$FILE"
        done
    } > "$BACKUP_FILE"
    chmod 600 "$BACKUP_FILE" 2>/dev/null
    log "Backup created at $BACKUP_FILE"
}

ensure_backup() {
    [ -f "$BACKUP_FILE" ] || create_backup
}

restore_backup() {
    [ -f "$BACKUP_FILE" ] || { log "ERROR: no backup to restore"; return 1; }

    local KEY VALUE CONF FILE
    while IFS='=' read -r KEY VALUE; do
        [ -z "$KEY" ] && continue
        case "$KEY" in '#'*) continue ;; esac

        VALUE=$(echo "$VALUE" | tr -d '"')

        for CONF in device_identity build_info identifiers; do
            FILE="${CONFIG_DIR}/${CONF}.conf"
            [ -f "$FILE" ] || continue
            if grep -q ",$KEY," "$FILE" 2>/dev/null; then
                sed -i "s|^ENABLED,$KEY,.*|ENABLED,$KEY,$VALUE|" "$FILE"
                sed -i "s|^DISABLED,$KEY,.*|ENABLED,$KEY,$VALUE|" "$FILE"
            fi
        done
    done < "$BACKUP_FILE"

    log "Backup restored"
}

reboot_runtime() {
    svc power reboot 2>/dev/null || /system/bin/reboot
}

valid_config_name() {
    case "$1" in
        device_identity.conf|build_info.conf|identifiers.conf|custom.conf) return 0 ;;
        *) return 1 ;;
    esac
}

emit_status_val() {
    local LIVE JK JL JV JO JC
    LIVE=$(getprop "$1" 2>/dev/null)
    json_set "$1";    JK=$JSTR
    json_set "$2";    JL=$JSTR
    json_set "$LIVE"; JV=$JSTR
    json_set "$4";    JO=$JSTR
    json_set "$5";    JC=$JSTR
    [ "$VAL_FIRST" -eq 1 ] || printf ','
    VAL_FIRST=0
    printf '{"key":%s,"label":%s,"live":%s,"original":%s,"configured":%s,"spoofable":%s}' \
        "$JK" "$JL" "$JV" "$JO" "$JC" "$3"
}

cmd_status() {
    if [ -z "$PERSONA_FLAG" ] || [ -z "$CONFIG_DIR" ]; then
        emit_error "Module state unavailable (state.sh not loaded)"
        return 1
    fi

    get_version

    local PERSONA=false UNSAFE=false REBOOT=false BACKUP=false ACTIVE_ID ACTIVE_NAME
    is_persona_active && PERSONA=true
    is_unsafe_props_enabled && UNSAFE=true
    [ -f "$REBOOT_PENDING" ] && REBOOT=true
    [ -f "$BACKUP_FILE" ] && BACKUP=true
    ACTIVE_ID=$(persona_active_id 2>/dev/null)
    [ -n "$ACTIVE_ID" ] && ACTIVE_NAME=$(persona_get_name "$ACTIVE_ID")

    printf '{'
    printf '"version":%s,' "$(json_str "$VERSION")"
    printf '"persona_active":%s,' "$PERSONA"
    printf '"active_persona":%s,' "$( [ -n "$ACTIVE_ID" ] && json_str "$ACTIVE_ID" || printf 'null' )"
    printf '"active_persona_name":%s,' "$( [ -n "$ACTIVE_NAME" ] && json_str "$ACTIVE_NAME" || printf 'null' )"
    printf '"unsafe_props":%s,' "$UNSAFE"
    printf '"reboot_required":%s,' "$REBOOT"
    printf '"has_backup":%s,' "$BACKUP"
    printf '"values":['

    local O_model= O_brand= O_manuf= O_device= O_pname= O_fp= O_vfp= O_bid= O_patch= O_serial= O_plat= O_hw=
    local C_model= C_brand= C_manuf= C_device= C_pname= C_fp= C_vfp= C_bid= C_patch= C_serial= C_plat= C_hw=
    local _K= _V= _ST= _P=

    if [ -f "$BACKUP_FILE" ]; then
        while IFS='=' read -r _K _V || [ -n "$_K" ]; do
            case $_K in
                ro.product.model)                O_model=$_V ;;
                ro.product.brand)                O_brand=$_V ;;
                ro.product.manufacturer)         O_manuf=$_V ;;
                ro.product.device)               O_device=$_V ;;
                ro.product.name)                 O_pname=$_V ;;
                ro.build.fingerprint)            O_fp=$_V ;;
                ro.vendor.build.fingerprint)     O_vfp=$_V ;;
                ro.build.id)                     O_bid=$_V ;;
                ro.build.version.security_patch) O_patch=$_V ;;
                ro.serialno)                     O_serial=$_V ;;
                ro.board.platform)               O_plat=$_V ;;
                ro.hardware)                     O_hw=$_V ;;
            esac
        done <<EOF
$(cat "$BACKUP_FILE" 2>/dev/null)
EOF
    fi

    while IFS=, read -r _ST _P _V || [ -n "$_ST" ]; do
        [ "$_ST" = ENABLED ] || continue
        case $_P in
            ro.product.model)                [ -n "$C_model" ]  || C_model=$_V ;;
            ro.product.brand)                [ -n "$C_brand" ]  || C_brand=$_V ;;
            ro.product.manufacturer)         [ -n "$C_manuf" ]  || C_manuf=$_V ;;
            ro.product.device)               [ -n "$C_device" ] || C_device=$_V ;;
            ro.product.name)                 [ -n "$C_pname" ]  || C_pname=$_V ;;
            ro.build.fingerprint)            [ -n "$C_fp" ]     || C_fp=$_V ;;
            ro.vendor.build.fingerprint)     [ -n "$C_vfp" ]    || C_vfp=$_V ;;
            ro.build.id)                     [ -n "$C_bid" ]    || C_bid=$_V ;;
            ro.build.version.security_patch) [ -n "$C_patch" ]  || C_patch=$_V ;;
            ro.serialno)                     [ -n "$C_serial" ] || C_serial=$_V ;;
            ro.board.platform)               [ -n "$C_plat" ]   || C_plat=$_V ;;
            ro.hardware)                     [ -n "$C_hw" ]     || C_hw=$_V ;;
        esac
    done <<EOF
$(grep -h '^ENABLED,' "${CONFIG_DIR}/device_identity.conf" "${CONFIG_DIR}/build_info.conf" "${CONFIG_DIR}/identifiers.conf" "${CONFIG_DIR}/custom.conf" 2>/dev/null)
EOF

    local VAL_FIRST=1
    emit_status_val ro.product.model                "Model"              1 "$O_model"  "$C_model"
    emit_status_val ro.product.brand                "Brand"              1 "$O_brand"  "$C_brand"
    emit_status_val ro.product.manufacturer         "Manufacturer"       1 "$O_manuf"  "$C_manuf"
    emit_status_val ro.product.device               "Device"             1 "$O_device" "$C_device"
    emit_status_val ro.product.name                 "Name"               1 "$O_pname"  "$C_pname"
    emit_status_val ro.build.fingerprint            "Build fingerprint"  1 "$O_fp"     "$C_fp"
    emit_status_val ro.vendor.build.fingerprint     "Vendor fingerprint" 1 "$O_vfp"    "$C_vfp"
    emit_status_val ro.build.id                     "Build ID"           1 "$O_bid"    "$C_bid"
    emit_status_val ro.build.version.security_patch "Security patch"     1 "$O_patch"  "$C_patch"
    emit_status_val ro.serialno                     "Serial"             1 "$O_serial" "$C_serial"
    emit_status_val ro.board.platform               "SoC platform"       0 "$O_plat"   "$C_plat"
    emit_status_val ro.hardware                     "Hardware"           0 "$O_hw"     "$C_hw"

    printf ']}'
    printf '\n'
}

cmd_generate() {
    local B64="$1" NAME ID
    [ -n "$B64" ] && NAME=$(printf '%s' "$B64" | base64 -d 2>/dev/null | tr -d '\n\r')
    [ -n "$NAME" ] || NAME=$(persona_default_name)
    ID=$(persona_create "$NAME") || { emit_error "${PERSONA_ERROR:-Failed to create persona}"; return 1; }
    persona_activate "$ID" || { emit_error "${PERSONA_ERROR:-Failed to activate persona}"; return 1; }
    printf '{"ok":true,"reboot_required":true,"id":%s,"name":%s,"message":%s}\n' \
        "$(json_str "$ID")" "$(json_str "$NAME")" \
        "$(json_str "Persona \"${NAME}\" generated and activated. Reboot to apply.")"
}

cmd_activate() {
    local ID="$1"
    if [ -n "$ID" ]; then
        ID=$(printf '%s' "$ID" | tr -d ' \t\n\r')
    else
        ID=$(persona_active_id 2>/dev/null)
        [ -n "$ID" ] || ID=$(persona_list_ids | tail -n1)
    fi
    [ -n "$ID" ] || { emit_error "No persona to activate - generate one first."; return 1; }
    persona_activate "$ID" || { emit_error "${PERSONA_ERROR:-Failed to activate persona}"; return 1; }
    emit_ok_reboot "Persona activated. Reboot to apply."
}

cmd_deactivate() {
    if persona_active_id >/dev/null 2>&1 || [ -f "$PERSONA_FLAG" ]; then
        persona_deactivate
        emit_ok_reboot "Spoofing deactivated. Reboot to restore original identity."
    else
        emit_ok "No persona is active."
    fi
}

emit_persona_row() {
    local ID="$1" DIR K V LINE JI JN JC JB JM
    local NAME=Persona CREATED='' BRAND='' MODEL='' AITGT=0 AIEN=false ACT=false
    DIR="${PERSONAS_DIR}/${ID}"

    if [ -f "${DIR}/meta" ]; then
        while IFS='=' read -r K V || [ -n "$K" ]; do
            case $K in
                NAME)    [ -n "$V" ] && NAME=$V ;;
                CREATED) CREATED=$V ;;
            esac
        done < "${DIR}/meta"
    fi

    if [ -f "${DIR}/device_identity.conf" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case $LINE in
                ENABLED,ro.product.brand,*) [ -n "$BRAND" ] || BRAND=${LINE#ENABLED,ro.product.brand,} ;;
                ENABLED,ro.product.model,*) [ -n "$MODEL" ] || MODEL=${LINE#ENABLED,ro.product.model,} ;;
            esac
        done < "${DIR}/device_identity.conf"
    fi

    if [ -f "${DIR}/android_id.conf" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case $LINE in
                ENABLED) AIEN=true ;;
                PKG=*)   AITGT=$((AITGT + 1)) ;;
            esac
        done < "${DIR}/android_id.conf"
    fi

    [ "$ID" = "$PERSONA_ACTIVE_ID" ] && ACT=true

    json_set "$ID";      JI=$JSTR
    json_set "$NAME";    JN=$JSTR
    json_set "$CREATED"; JC=$JSTR
    json_set "$BRAND";   JB=$JSTR
    json_set "$MODEL";   JM=$JSTR

    [ "$PERSONA_FIRST" -eq 1 ] || printf ','
    PERSONA_FIRST=0
    printf '{"id":%s,"name":%s,"created":%s,"active":%s,"brand":%s,"model":%s,"android_id_enabled":%s,"android_id_targets":%s}' \
        "$JI" "$JN" "$JC" "$ACT" "$JB" "$JM" "$AIEN" "$AITGT"
}

cmd_personas_list() {
    local ID PERSONA_FIRST=1 PERSONA_ACTIVE_ID JA
    PERSONA_ACTIVE_ID=$(persona_active_id 2>/dev/null)
    if [ -n "$PERSONA_ACTIVE_ID" ]; then json_set "$PERSONA_ACTIVE_ID"; JA=$JSTR; else JA=null; fi
    printf '{"ok":true,"active":%s,"personas":[' "$JA"
    for ID in $(persona_list_ids); do
        emit_persona_row "$ID"
    done
    printf ']}'
    printf '\n'
}

cmd_persona_activate() {
    local ID="$1"
    [ -n "$ID" ] || { emit_error "No persona id given"; return 1; }
    persona_activate "$(printf '%s' "$ID" | tr -d ' \t\n\r')" \
        || { emit_error "${PERSONA_ERROR:-Failed to activate persona}"; return 1; }
    emit_ok_reboot "Persona activated. Reboot to apply."
}

cmd_persona_rename() {
    local ID="$1" B64="$2" NAME
    [ -n "$ID" ] || { emit_error "No persona id given"; return 1; }
    [ -n "$B64" ] && NAME=$(printf '%s' "$B64" | base64 -d 2>/dev/null | tr -d '\n\r')
    [ -n "$NAME" ] || { emit_error "Empty name"; return 1; }
    persona_rename "$(printf '%s' "$ID" | tr -d ' \t\n\r')" "$NAME" \
        || { emit_error "${PERSONA_ERROR:-Rename failed}"; return 1; }
    emit_ok "Renamed."
}

cmd_persona_delete() {
    local ID="$1" WAS_ACTIVE=0
    [ -n "$ID" ] || { emit_error "No persona id given"; return 1; }
    ID=$(printf '%s' "$ID" | tr -d ' \t\n\r')
    [ "$(persona_active_id 2>/dev/null)" = "$ID" ] && WAS_ACTIVE=1
    persona_delete "$ID" || { emit_error "${PERSONA_ERROR:-Delete failed}"; return 1; }
    if [ "$WAS_ACTIVE" -eq 1 ]; then
        emit_ok_reboot "Persona deleted. Reboot to restore original identity."
    else
        emit_ok "Persona deleted."
    fi
}

cmd_restore() {
    if restore_backup; then
        mark_reboot
        emit_ok_reboot "Original values restored. Reboot to apply."
    else
        emit_error "No backup found to restore."
    fi
}

cmd_read_config() {
    local NAME="$1"
    valid_config_name "$NAME" || { echo "ERROR: invalid config name" >&2; return 1; }
    local FILE="${CONFIG_DIR}/${NAME}"
    [ -f "$FILE" ] || { echo "ERROR: config not found" >&2; return 1; }
    cat "$FILE"
}

cmd_write_config() {
    local NAME="$1" B64="$2"
    valid_config_name "$NAME" || { emit_error "Invalid config name"; return 1; }
    [ -n "$B64" ] || { emit_error "No content provided"; return 1; }

    local FILE="${CONFIG_DIR}/${NAME}"
    local TMP="${FILE}.tmp.$$"
    if ! printf '%s' "$B64" | base64 -d > "$TMP" 2>/dev/null; then
        rm -f "$TMP"
        emit_error "Base64 decode failed"
        return 1
    fi
    chmod 600 "$TMP" 2>/dev/null
    if ! mv -f "$TMP" "$FILE" 2>/dev/null; then
        rm -f "$TMP"
        emit_error "Write failed"
        return 1
    fi
    persona_sync_file_from_config "$NAME"
    mark_reboot
    log "Config written: $NAME"
    emit_ok_reboot "Saved."
}

cmd_logs() {
    local N="${1:-200}"
    case "$N" in ''|*[!0-9]*) N=200 ;; esac
    if [ -f "$LOG_FILE" ]; then
        tail -n "$N" "$LOG_FILE"
    else
        echo "(no logs yet)"
    fi
}

cmd_clear_logs() {
    : > "$LOG_FILE" 2>/dev/null
    chmod 600 "$LOG_FILE" 2>/dev/null
    log "Logs cleared"
    emit_ok "Logs cleared."
}

cmd_open_url() {
    local B64="$1" URL
    [ -n "$B64" ] || { emit_error "No URL provided"; return 1; }
    URL=$(printf '%s' "$B64" | base64 -d 2>/dev/null | tr -d '\n\r') || { emit_error "Base64 decode failed"; return 1; }
    case "$URL" in
        http://*|https://*) ;;
        *) emit_error "Unsupported URL"; return 1 ;;
    esac

    if am start -a android.intent.action.VIEW -d "$URL" >/dev/null 2>&1; then
        emit_ok "Opened."
        return 0
    fi
    emit_error "Could not open URL."
    return 1
}

cmd_ui_log() {
    local B64="$1" MSG
    [ -n "$B64" ] || return 0
    MSG=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || return 0
    MSG=$(printf '%s' "$MSG" | tr '\n\r\t' '   ' | cut -c1-300)
    [ -n "$MSG" ] || return 0
    log "[webui] $MSG"
}

detect_root_manager() {
    if [ -n "$KSU" ] || [ -d /data/adb/ksu ]; then echo "KernelSU"; return; fi
    if [ -n "$APATCH" ] || [ -d /data/adb/ap ]; then echo "APatch"; return; fi
    if [ -n "$MAGISK_VER_CODE" ] || [ -d /data/adb/magisk ]; then echo "Magisk"; return; fi
    echo "unknown"
}

resolve_resetprop_path() {
    local P CAND
    P="$(command -v resetprop 2>/dev/null)"
    if [ -z "$P" ]; then
        for CAND in /data/adb/ksu/bin/resetprop /data/adb/ap/bin/resetprop /data/adb/magisk/resetprop; do
            [ -x "$CAND" ] && { P="$CAND"; break; }
        done
    fi
    echo "$P"
}

collect_diagnostics() {
    local VCODE RP CONF FILE EN HDR KEY LIVE CONFV ORIG ST
    get_version
    VCODE=$(grep '^versionCode=' "${MODDIR}/module.prop" 2>/dev/null | head -n1 | cut -d= -f2)
    RP=$(resolve_resetprop_path)

    echo "===== DeviceSpoofLabs diagnostics ====="
    echo "# generated : $(date '+%Y-%m-%d %H:%M:%S')"
    echo "# NOTE: contains this device's identity values (real + spoofed). Keep private."
    echo
    echo "module.version   : ${VERSION} (versionCode ${VCODE:-?})"
    echo "root.manager     : $(detect_root_manager)"
    echo "selinux          : $(getenforce 2>/dev/null || echo '?')"
    echo "android.release  : $(getprop ro.build.version.release 2>/dev/null) (sdk $(getprop ro.build.version.sdk 2>/dev/null))"
    echo "kernel           : $(uname -r 2>/dev/null)"
    echo "data.dir         : ${DATA_DIR}"
    echo "module.dir       : ${MODDIR}"
    echo "resetprop        : ${RP:-NOT FOUND}"
    echo "persona_active   : $( [ -f "$PERSONA_FLAG" ] && echo "yes ($PERSONA_FLAG)" || echo no )"
    echo "backup.conf      : $( [ -f "$BACKUP_FILE" ] && echo yes || echo no )"
    echo "reboot_pending   : $( [ -f "$REBOOT_PENDING" ] && echo yes || echo no )"
    echo "unsafe.props     : $( is_unsafe_props_enabled && echo ENABLED || echo off )"
    echo "module.disabled  : $( [ -f "${MODDIR}/disable" ] && echo yes || echo no )"
    echo
    echo "--- config files (in ${CONFIG_DIR}) ---"
    for CONF in device_identity build_info identifiers custom; do
        FILE="${CONFIG_DIR}/${CONF}.conf"
        if [ -f "$FILE" ]; then
            EN=$(grep -c '^ENABLED,' "$FILE" 2>/dev/null)
            HDR=$(head -n1 "$FILE" 2>/dev/null)
            echo "  ${CONF}.conf: present, ${EN} ENABLED entries, header=[${HDR}]"
        else
            echo "  ${CONF}.conf: MISSING"
        fi
    done
    echo
    echo "--- key identity props: live vs configured vs real ---"
    echo "    (APPLIED = spoof is live; NOT-APPLIED = configured but not live yet)"
    for KEY in ro.product.model ro.product.brand ro.product.manufacturer \
               ro.build.fingerprint ro.vendor.build.fingerprint ro.serialno \
               ro.bootloader ro.board.platform ro.hardware; do
        LIVE=$(getprop "$KEY" 2>/dev/null)
        CONFV=$(configured_value "$KEY")
        ORIG=$(backup_value "$KEY")
        if [ -n "$CONFV" ] && [ "$LIVE" = "$CONFV" ]; then ST="APPLIED"
        elif [ -n "$CONFV" ]; then ST="NOT-APPLIED"
        else ST="-"; fi
        echo "  ${KEY}: live=[${LIVE}] configured=[${CONFV}] real=[${ORIG}] -> ${ST}"
    done
    echo
    echo "--- permissions / SELinux context ---"
    ls -ldZ "$DATA_DIR" "$CONFIG_DIR" "$PERSONA_FLAG" "${MODDIR}/common/webctl.sh" 2>/dev/null \
        || ls -ld "$DATA_DIR" "$CONFIG_DIR" "$PERSONA_FLAG" "${MODDIR}/common/webctl.sh" 2>/dev/null
}

collect_logcat_snippet() {
    local TMP
    if ! command -v logcat >/dev/null 2>&1; then
        echo "(logcat not available in this context)"
        return
    fi
    TMP="${DATA_DIR}/.logcat.$$"
    if ! logcat -d -b all -v time > "$TMP" 2>/dev/null && ! logcat -d -v time > "$TMP" 2>/dev/null; then
        echo "(logcat read failed)"
        rm -f "$TMP" 2>/dev/null
        return
    fi
    chmod 600 "$TMP" 2>/dev/null
    echo "# Filtered to module / root-manager / resetprop lines + recent SELinux denials."
    echo "# General app and system log content is intentionally NOT included."
    echo
    echo "--- module / root-manager / resetprop ---"
    grep -iE 'devicespooflab|resetprop|kernelsu|ksud|apatch' "$TMP" | tail -n 250
    echo
    echo "--- recent SELinux denials (avc) ---"
    grep -iE 'avc: *denied' "$TMP" | tail -n 80
    rm -f "$TMP" 2>/dev/null
}

cmd_diagnose() {
    collect_diagnostics
}

cmd_export_logs() {
    local TS DIR DEST=""
    TS=$(date '+%Y%m%d-%H%M%S')
    for DIR in /sdcard/Download /storage/emulated/0/Download /sdcard; do
        if [ -d "$DIR" ] && touch "$DIR/.dsl_w_$$" 2>/dev/null; then
            rm -f "$DIR/.dsl_w_$$" 2>/dev/null
            DEST="$DIR/devicespooflab-log-$TS.txt"
            break
        fi
    done
    [ -n "$DEST" ] || DEST="${DATA_DIR}/devicespooflab-log-$TS.txt"

    {
        collect_diagnostics
        echo
        echo "===== module log (${LOG_FILE}) ====="
        if [ -f "$LOG_FILE" ]; then cat "$LOG_FILE"; else echo "(no logs yet)"; fi
        if [ -f "${LOG_FILE}.1" ]; then
            echo
            echo "===== previous module log (rotated) ====="
            cat "${LOG_FILE}.1"
        fi
        echo
        echo "===== logcat snapshot ====="
        collect_logcat_snippet
    } > "$DEST" 2>/dev/null

    if [ -f "$DEST" ]; then
        log "Logs exported to $DEST (with diagnostics + logcat)"
        printf '{"ok":true,"path":%s}\n' "$(json_str "$DEST")"
    else
        emit_error "Could not write log export."
    fi
}

cmd_reboot() {
    log "Reboot requested via webctl"
    reboot_runtime
}

cmd_list_apps() {
    local FILTER="${1:-all}" PKG SYS_LIST SRC FIRST=1
    if [ -z "$(command -v pm)" ]; then
        printf '{"ok":false,"apps":[],"message":%s}\n' "$(json_str "pm command unavailable")"
        return 0
    fi

    SYS_LIST=$(pm list packages -s 2>/dev/null | sed 's/^package://')
    case "$FILTER" in
        user)   SRC=$(pm list packages -3 2>/dev/null | sed 's/^package://') ;;
        system) SRC=$(pm list packages -s 2>/dev/null | sed 's/^package://') ;;
        *)      SRC=$(pm list packages 2>/dev/null | sed 's/^package://') ;;
    esac

    printf '{"ok":true,"apps":['
    printf '%s\n' "$SRC" | sort | while IFS= read -r PKG; do
        [ -n "$PKG" ] || continue
        local SYS=false
        printf '%s\n' "$SYS_LIST" | grep -qxF "$PKG" && SYS=true
        [ "$FIRST" -eq 1 ] || printf ','
        FIRST=0
        printf '{"pkg":%s,"label":%s,"system":%s}' "$(json_str "$PKG")" "$(json_str "$PKG")" "$SYS"
    done
    printf ']}'
    printf '\n'
}

cmd_android_id_config() {
    local ENABLED=false VALUE USER PKG FIRST=1
    ai_is_enabled && ENABLED=true
    VALUE=$(ai_get_value)
    USER=$(ai_get_user)
    printf '{"ok":true,"enabled":%s,"value":%s,"user_id":%s,"targets":[' \
        "$ENABLED" "$(json_str "$VALUE")" "$(json_str "$USER")"
    ai_get_targets | while IFS= read -r PKG; do
        [ -n "$PKG" ] || continue
        [ "$FIRST" -eq 1 ] || printf ','
        FIRST=0
        printf '%s' "$(json_str "$PKG")"
    done
    printf ']}'
    printf '\n'
}

cmd_set_android_id() {
    local B64="$1" PAYLOAD LINE EN=0 VAL="" USR=0 PKGS=""
    [ -n "$B64" ] || { emit_error "No data provided"; return 1; }
    PAYLOAD=$(printf '%s' "$B64" | base64 -d 2>/dev/null) || { emit_error "Base64 decode failed"; return 1; }

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            ENABLED=1) EN=1 ;;
            ENABLED=0) EN=0 ;;
            VALUE=*)   VAL=${LINE#VALUE=} ;;
            USER=*)    USR=${LINE#USER=} ;;
            PKG=*)     PKGS="${PKGS} ${LINE#PKG=}" ;;
        esac
    done <<EOF
$PAYLOAD
EOF

    ai_valid_value "$VAL" || { emit_error "Invalid Android ID (need 16 hex chars)"; return 1; }
    ai_valid_user "$USR" || USR=0
    if [ "$EN" = "1" ]; then
        if ! is_persona_active || ! persona_active_id >/dev/null 2>&1; then
            emit_error "Activate a persona before enabling Android ID spoofing."
            return 1
        fi
    fi

    if ai_write_config "$EN" "$VAL" "$USR" $PKGS; then
        persona_sync_file_from_config "android_id.conf"
        mark_reboot
        log "Android ID config saved (enabled=$EN user=$USR targets=$(ai_target_count))"
        emit_ok_reboot "Android ID settings saved."
    else
        emit_error "${AI_ERROR:-Could not save Android ID settings}"
        return 1
    fi
}

cmd_apply_android_id() {
    local CNT SKIP TARGETS MSG
    if ! is_persona_active || ! persona_active_id >/dev/null 2>&1; then
        emit_error "Activate a persona before applying Android ID spoofing."
        return 1
    fi
    TARGETS=$(ai_target_count)
    if [ "${TARGETS:-0}" -le 0 ]; then
        emit_error "No target apps selected."
        return 1
    fi
    ai_is_enabled || ai_write_config 1 "$(ai_get_value)" "$(ai_get_user)" $(ai_get_targets) >/dev/null 2>&1
    persona_sync_file_from_config "android_id.conf"

    if ai_apply_config; then
        CNT=${AI_APPLIED_COUNT:-0}
        SKIP="$AI_SKIPPED_PKGS"
        log "Android ID applied: count=$CNT skipped=[$SKIP]"

        if [ "${CNT:-0}" -gt 0 ]; then
            mark_reboot
            MSG="Android ID applied to ${CNT} app(s). Reboot to take effect."
            [ -n "$SKIP" ] && MSG="${MSG} No SSAID entry yet (open the app once): ${SKIP}."
            printf '{"ok":true,"reboot_required":true,"applied":%s,"skipped":%s,"message":%s}\n' \
                "$CNT" "$(json_str "$SKIP")" "$(json_str "$MSG")"
        else
            MSG="Android ID was not applied yet. No SSAID entry exists for the selected app(s); open each app once, then apply again."
            [ -n "$SKIP" ] && MSG="${MSG} Skipped: ${SKIP}."
            printf '{"ok":true,"reboot_required":false,"applied":0,"skipped":%s,"message":%s}\n' \
                "$(json_str "$SKIP")" "$(json_str "$MSG")"
        fi
    else
        emit_error "${AI_ERROR:-Failed to apply Android ID}"
        return 1
    fi
}

cmd_restore_android_id() {
    local USER
    USER=$(ai_get_user)
    if ai_restore_targets "$USER" $(ai_get_targets); then
        ai_set_enabled 0
        rm -f "$AI_APPLIED_STATE" 2>/dev/null
        persona_sync_file_from_config "android_id.conf"
        mark_reboot
        log "Android ID restored to original for user $USER"
        emit_ok_reboot "Original Android IDs restored. Reboot to take effect."
    else
        emit_error "${AI_ERROR:-Could not restore Android IDs.}"
        return 1
    fi
}

find_busybox() {
    local C P
    P="$(command -v busybox 2>/dev/null)"
    [ -x "$P" ] && { echo "$P"; return; }
    for C in /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
        [ -x "$C" ] && { echo "$C"; return; }
    done
}

download_url() {
    local URL="$1" DEST="$2" BB
    if command -v curl >/dev/null 2>&1; then
        curl -L --fail --connect-timeout 20 -o "$DEST" "$URL" 2>/dev/null && [ -s "$DEST" ] && return 0
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -O "$DEST" "$URL" 2>/dev/null && [ -s "$DEST" ] && return 0
    fi
    BB="$(find_busybox)"
    [ -n "$BB" ] && "$BB" wget --no-check-certificate -O "$DEST" "$URL" 2>/dev/null && [ -s "$DEST" ] && return 0
    return 1
}

sha256_of() {
    local F="$1" BB
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$F" 2>/dev/null | awk '{print $1}'
        return
    fi
    BB="$(find_busybox)"
    [ -n "$BB" ] && "$BB" sha256sum "$F" 2>/dev/null | awk '{print $1}'
}

size_of() {
    stat -c %s "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null | tr -d ' '
}

ksuwebui_installed() {
    pm path "$KSUWEBUI_PKG" >/dev/null 2>&1
}

launch_ksuwebui() {
    log "[webui] launch $KSUWEBUI_ACTIVITY id=$MODULE_ID"
    am start -n "$KSUWEBUI_ACTIVITY" -e id "$MODULE_ID" -e name "$MODULE_NAME" >/dev/null 2>&1
}

webuix_installed() {
    pm path "$WEBUIX_PKG" >/dev/null 2>&1
}

launch_webuix() {
    log "[webui] launch $WEBUIX_ACTIVITY MOD_ID=$MODULE_ID"
    am start -n "$WEBUIX_ACTIVITY" -e MOD_ID "$MODULE_ID" >/dev/null 2>&1
}

pkg_installed() {
    pm path "$1" >/dev/null 2>&1
}

launch_native_webui_component() {
    local PKG="$1" CLASS="$2" SCHEME="$3"
    log "[webui] launch native $PKG/$CLASS id=$MODULE_ID"
    am start -a android.intent.action.VIEW \
        -n "${PKG}/${CLASS}" \
        -d "${SCHEME}://webui/${MODULE_ID}" \
        -e id "$MODULE_ID" \
        -e name "$MODULE_NAME" >/dev/null 2>&1
}

launch_native_manager_webui() {
    local MGR="$1" PKG

    case "$MGR" in
        KernelSU)
            for PKG in me.weishu.kernelsu me.weishu.kernelsu.dev; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "me.weishu.kernelsu.ui.webui.WebUIActivity" kernelsu; then
                    return 0
                fi
            done
            for PKG in com.rifsxd.ksunext; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "com.rifsxd.ksunext.ui.webui.WebUIActivity" kernelsu; then
                    return 0
                fi
            done
            ;;
        APatch)
            for PKG in me.bmax.apatch me.garfieldhan.apatch.next; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "me.bmax.apatch.ui.WebUIActivity" apatch; then
                    return 0
                fi
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "me.garfieldhan.apatch.next.ui.WebUIActivity" apatch; then
                    return 0
                fi
            done
            ;;
    esac

    return 1
}

open_release_page() {
    echo "  Opening the KsuWebUI download page so you can install it manually:"
    echo "    $KSUWEBUI_RELEASE_PAGE"
    am start -a android.intent.action.VIEW -d "$KSUWEBUI_RELEASE_PAGE" >/dev/null 2>&1
}

install_ksuwebui() {
    local APK="${DSL_WEBUI_APK:-/data/local/tmp/dsl-ksuwebui.apk}" GOT_SHA GOT_SIZE
    rm -f "$APK" 2>/dev/null

    echo "  Downloading KsuWebUI host app (~1.7 MB)..."
    log "[webui] download $KSUWEBUI_APK_URL"
    if ! download_url "$KSUWEBUI_APK_URL" "$APK"; then
        echo "  ! Download failed - no network, or no curl/wget/busybox available."
        log "[webui] download FAILED"
        rm -f "$APK" 2>/dev/null
        return 1
    fi

    GOT_SIZE=$(size_of "$APK")
    GOT_SHA=$(sha256_of "$APK")
    if [ "$GOT_SIZE" != "$KSUWEBUI_APK_SIZE" ] || [ "$GOT_SHA" != "$KSUWEBUI_APK_SHA256" ]; then
        echo "  ! Verification failed - the downloaded file does not match the pinned APK."
        echo "      expected: sha256=$KSUWEBUI_APK_SHA256 size=$KSUWEBUI_APK_SIZE"
        echo "      got:      sha256=${GOT_SHA:-?} size=${GOT_SIZE:-?}"
        log "[webui] verify FAILED got sha=$GOT_SHA size=$GOT_SIZE"
        rm -f "$APK" 2>/dev/null
        return 1
    fi
    echo "  Verified (SHA-256 + size). Installing..."
    log "[webui] verified OK; pm install"

    chmod 644 "$APK" 2>/dev/null
    if ! pm install -r -S "$GOT_SIZE" < "$APK" >/dev/null 2>&1; then
        pm install -r "$APK" >/dev/null 2>&1
    fi
    rm -f "$APK" 2>/dev/null

    if ksuwebui_installed; then
        echo "  KsuWebUI installed."
        log "[webui] install OK"
        return 0
    fi
    echo "  ! Install did not register the package."
    log "[webui] install FAILED (pm path empty)"
    return 1
}

cmd_open_webui() {
    local MGR
    get_version
    MGR=$(detect_root_manager)
    echo "DeviceSpoofLabs WebUI launcher (v${VERSION})"

    if [ "$MGR" = "KernelSU" ] || [ "$MGR" = "APatch" ]; then
        echo "  Opening DeviceSpoofLabs in the native $MGR WebUI..."
        if launch_native_manager_webui "$MGR"; then
            echo "  Opened."
            return 0
        fi
        echo "  ! Could not start the native $MGR WebUI activity."
        log "[webui] native $MGR launch FAILED"
        return 1
    fi

    if webuix_installed; then
        echo "  WebUI X found - opening the DeviceSpoofLabs WebUI..."
        if launch_webuix; then
            echo "  Opened in WebUI X. Grant it root access if prompted."
            return 0
        fi
        echo "  ! Could not start the WebUI X activity."
        open_release_page
        return 1
    fi

    if ksuwebui_installed; then
        echo "  KsuWebUI found - opening the DeviceSpoofLabs WebUI..."
    else
        echo "  No WebUI host found (KsuWebUI or WebUI X)."
        if ! install_ksuwebui; then
            open_release_page
            echo
            echo "  Once a WebUI host is installed, tap Action again, or run:"
            echo "      su -c 'devicespooflabs webui'"
            return 1
        fi
    fi

    if launch_ksuwebui; then
        echo "  Opened. On first launch, grant the WebUI host root access when prompted."
        return 0
    fi
    echo "  ! Could not start the WebUI activity."
    open_release_page
    return 1
}

print_help() {
    cat <<EOF
DeviceSpoofLabs control (webctl) - non-interactive

Usage: devicespooflabs <command> [args]

  status                        JSON status (persona, live/original values, reboot state)
  personas                      List saved personas as JSON (id, name, active flag, summary)
  generate-persona [base64name] Create a new persona (optional name), activate it, mark reboot
  activate [id]                 Activate a persona by id (or the current/most-recent one)
  persona-activate <id>         Activate the persona with this id (deactivates any other)
  persona-rename <id> <base64>  Rename a persona
  persona-delete <id>           Delete a persona (deactivates first if it was active)
  deactivate                    Deactivate the active persona (nothing is spoofed)
  restore-backup                Restore original device values from backup
  read-config <file>            Print a config file
  write-config <file> <base64>  Replace a config file (content is base64-encoded)
  list-apps [all|user|system]   List installed packages as JSON (fallback app list)
  android-id-config             Print the saved Android ID (SSAID) config as JSON
  set-android-id <base64>       Save Android ID config (ENABLED/VALUE/USER/PKG payload)
  apply-android-id              Apply saved Android ID to the SSAID store, mark reboot
  restore-android-id            Restore original per-user Android IDs from backup
  logs [n]                      Print last n log lines (default 200)
  clear-logs                    Truncate the log file
  export-logs                   Export diagnostics + log + filtered logcat to /sdcard/Download
  diagnose                      Print a diagnostic snapshot (state, props, perms, SELinux)
  open-url <base64url>          Open an http(s) URL through Android's external handler
  ui-log <base64>               Append a [webui] line to the log (used by the WebUI client)
  reboot                        Reboot the device
  webui                         Open the WebUI (native manager on KernelSU/APatch; WebUI X/KsuWebUI on Magisk)

Config files: device_identity.conf, build_info.conf, identifiers.conf, custom.conf
Most actions require a reboot to take effect.
EOF
}

case "${1:-status}" in
    status)                     cmd_status ;;
    personas|personas-list)     cmd_personas_list ;;
    generate-persona|generate)  cmd_generate "$2" ;;
    activate)                   cmd_activate "$2" ;;
    persona-activate)           cmd_persona_activate "$2" ;;
    persona-rename)             cmd_persona_rename "$2" "$3" ;;
    persona-delete)             cmd_persona_delete "$2" ;;
    deactivate)                 cmd_deactivate ;;
    restore-backup|restore)     cmd_restore ;;
    read-config)                cmd_read_config "$2" ;;
    write-config)               cmd_write_config "$2" "$3" ;;
    list-apps)                  cmd_list_apps "$2" ;;
    android-id-config)          cmd_android_id_config ;;
    set-android-id)             cmd_set_android_id "$2" ;;
    apply-android-id)           cmd_apply_android_id ;;
    restore-android-id)         cmd_restore_android_id ;;
    logs)                       cmd_logs "$2" ;;
    clear-logs)                 cmd_clear_logs ;;
    export-logs)                cmd_export_logs ;;
    diagnose|diagnostics)       cmd_diagnose ;;
    open-url)                   cmd_open_url "$2" ;;
    ui-log)                     cmd_ui_log "$2" ;;
    reboot)                     cmd_reboot ;;
    webui|open-webui)           cmd_open_webui ;;
    version)                    get_version; printf '{"version":%s}\n' "$(json_str "$VERSION")" ;;
    help|-h|--help)             print_help ;;
    *)                          emit_error "Unknown command: ${1}"; exit 1 ;;
esac
