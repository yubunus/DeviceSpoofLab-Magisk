#!/system/bin/sh
# Non-interactive control layer for the WebUI bridge and devicespooflabs CLI.

# "--b64" before a command: the command runs unchanged in a second copy of this script. What it
# wrote to stdout comes back as "b64:" followed by its base64, and what it wrote to stderr comes
# back the same way on stderr (nothing there when it wrote nothing). The exit status is the
# command's. The WebUI calls every command this way: KernelSU, SukiSU and APatch hand the output
# to the page inside a javascript: URL, where "%" plus two hex digits is decoded, and base64 has
# no "%". A reply whose stdout does not start with "b64:" did not get through.
# fd 3 carries the exit status into RC; 4 and 5 are this script's own stdout and stderr. Both
# pipes are read to their end, so a job the command leaves behind must not keep them open.
if [ "$1" = "--b64" ]; then
    shift
    command -v base64 >/dev/null 2>&1 || { echo "ERROR: base64 not found" >&2; exit 127; }
    {
        RC=$(
            {
                {
                    { "$0" "$@" 3>&- 4>&- 5>&-; echo "$?" >&3; } |
                        { B=$(base64) && echo "b64:$B" >&4; }
                } 2>&1 | { B=$(base64) && [ -n "$B" ] && echo "b64:$B" >&5; }
            } 3>&1
        )
    } 4>&1 5>&2
    exit "${RC:-1}"
fi

SCRIPT_DIR="${0%/*}"
MODDIR="${MODDIR:-/data/adb/modules/devicespooflab}"

[ -f "${SCRIPT_DIR}/state.sh" ] && . "${SCRIPT_DIR}/state.sh"
[ -f "${SCRIPT_DIR}/utils.sh" ] && . "${SCRIPT_DIR}/utils.sh"
[ -f "${SCRIPT_DIR}/value_resolver.sh" ] && . "${SCRIPT_DIR}/value_resolver.sh"
[ -f "${SCRIPT_DIR}/android_id.sh" ] && . "${SCRIPT_DIR}/android_id.sh"
[ -f "${SCRIPT_DIR}/personas.sh" ] && . "${SCRIPT_DIR}/personas.sh"
[ -f "${SCRIPT_DIR}/devices.sh" ] && . "${SCRIPT_DIR}/devices.sh"

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
WEBUIX_ACTIVITY="com.dergoogler.mmrl.wx/.ui.webui.WebUIActivity"
WEBUIX_ACTIVITY_OLD="com.dergoogler.mmrl.wx/.ui.activity.webui.WebUIActivity"

PERSONA_EXPORT_DIR="${PERSONA_EXPORT_DIR:-/storage/emulated/0/Download/DeviceSpoofLabs}"

# One printf defines both (it is a process on Android's mksh): the control characters, then a tab.
__JSON_CTRL=$(printf '\001-\037\t')
__JSON_TAB=${__JSON_CTRL#"${__JSON_CTRL%?}"}
__JSON_CTRL=${__JSON_CTRL%?}
__JSON_NL='
'

# Shell-only on purpose, so the result does not depend on sed, tr or the libc: \ and " are
# escaped, a newline or tab becomes a space, and every other control character is dropped.
json_set() {
    local S="$1" OUT="" HEAD REST
    case $S in
        *[\\\"$__JSON_CTRL]*) ;;
        *) JSTR=\"$S\"; return 0 ;;
    esac
    # The loop below is quadratic in the string length. Nothing legitimate is this long.
    [ "${#S}" -le 4096 ] || S=$(printf '%s' "$S" | dd bs=4096 count=1 2>/dev/null)
    while :; do
        HEAD=${S%%[\\\"$__JSON_CTRL]*}
        OUT="${OUT}${HEAD}"
        S=${S#"$HEAD"}
        case $S in
            '')                           break ;;
            \\*)                          OUT="${OUT}\\\\" ;;
            \"*)                          OUT="${OUT}\\\"" ;;
            "$__JSON_NL"*|"$__JSON_TAB"*) OUT="${OUT} " ;;
        esac
        REST=${S#?}
        [ "$REST" != "$S" ] || break
        S=$REST
    done
    JSTR=\"$OUT\"
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
    local LINE
    VERSION=""
    if [ -f "${MODDIR}/module.prop" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case $LINE in
                version=*) VERSION=${LINE#version=}; break ;;
            esac
        done < "${MODDIR}/module.prop"
    fi
    [ -n "$VERSION" ] || VERSION="3.1"
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
                PROP=${LINE#*,}
                PROP=${PROP%%,*}
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

# Appends one value's JSON to STATUS_JSON. $1 = prop, $2 = label, $3 = 1 when the module can
# spoof it, $4 = live value, $5 = original (from the backup), $6 = configured.
emit_status_val() {
    local JK JL JV JO JC
    json_set "$1"; JK=$JSTR
    json_set "$2"; JL=$JSTR
    json_set "$4"; JV=$JSTR
    json_set "$5"; JO=$JSTR
    json_set "$6"; JC=$JSTR
    [ "$VAL_FIRST" -eq 1 ] || STATUS_JSON="${STATUS_JSON},"
    VAL_FIRST=0
    STATUS_JSON="${STATUS_JSON}{\"key\":${JK},\"label\":${JL},\"live\":${JV},\"original\":${JO},\"configured\":${JC},\"spoofable\":${3}}"
}

cmd_status() {
    if [ -z "$PERSONA_FLAG" ] || [ -z "$CONFIG_DIR" ]; then
        emit_error "Module state unavailable (state.sh not loaded)"
        return 1
    fi

    get_version

    local PERSONA=false UNSAFE=false REBOOT=false BACKUP=false AUTO_OFF=false
    local ACTIVE_ID ACTIVE_NAME AUTO_OFF_ID AUTO_OFF_NAME JV STATUS_JSON
    is_persona_active && PERSONA=true
    is_unsafe_props_enabled && UNSAFE=true
    [ -f "$REBOOT_PENDING" ] && REBOOT=true
    [ -f "$BACKUP_FILE" ] && BACKUP=true
    ACTIVE_ID=$(persona_active_id 2>/dev/null)
    [ -n "$ACTIVE_ID" ] && ACTIVE_NAME=$(persona_get_name "$ACTIVE_ID")
    # post-fs-data.sh leaves this file when it switched the persona off after two unfinished boots.
    if [ -f "$AUTO_DISABLED_FILE" ]; then
        AUTO_OFF=true
        AUTO_OFF_ID=$(tr -d ' \t\n\r' < "$AUTO_DISABLED_FILE" 2>/dev/null)
        persona_valid_id "$AUTO_OFF_ID" && persona_exists "$AUTO_OFF_ID" && \
            AUTO_OFF_NAME=$(persona_get_name "$AUTO_OFF_ID")
    fi

    # The reply is put together here and printed once. On Android's mksh printf is a process, and
    # a process costs 15 to 20 ms on a phone; the page asks for the status after every action.
    STATUS_JSON='{'
    json_set "$VERSION"
    STATUS_JSON="${STATUS_JSON}\"version\":${JSTR},"
    STATUS_JSON="${STATUS_JSON}\"persona_active\":${PERSONA},"
    if [ -n "$ACTIVE_ID" ]; then json_set "$ACTIVE_ID"; JV=$JSTR; else JV=null; fi
    STATUS_JSON="${STATUS_JSON}\"active_persona\":${JV},"
    if [ -n "$ACTIVE_NAME" ]; then json_set "$ACTIVE_NAME"; JV=$JSTR; else JV=null; fi
    STATUS_JSON="${STATUS_JSON}\"active_persona_name\":${JV},"
    STATUS_JSON="${STATUS_JSON}\"unsafe_props\":${UNSAFE},"
    STATUS_JSON="${STATUS_JSON}\"reboot_required\":${REBOOT},"
    STATUS_JSON="${STATUS_JSON}\"has_backup\":${BACKUP},"
    STATUS_JSON="${STATUS_JSON}\"auto_disabled\":${AUTO_OFF},"
    if [ -n "$AUTO_OFF_NAME" ]; then json_set "$AUTO_OFF_NAME"; JV=$JSTR; else JV=null; fi
    STATUS_JSON="${STATUS_JSON}\"auto_disabled_name\":${JV},"
    STATUS_JSON="${STATUS_JSON}\"values\":["

    local O_model= O_brand= O_manuf= O_device= O_pname= O_fp= O_vfp= O_bid= O_patch= O_serial= O_plat= O_hw=
    local C_model= C_brand= C_manuf= C_device= C_pname= C_fp= C_vfp= C_bid= C_patch= C_serial= C_plat= C_hw=
    local L_model= L_brand= L_manuf= L_device= L_pname= L_fp= L_vfp= L_bid= L_patch= L_serial= L_plat= L_hw=
    local _K= _V= _ST= _P= _F= _L=

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
        done < "$BACKUP_FILE"
    fi

    for _F in device_identity build_info identifiers custom; do
        [ -f "${CONFIG_DIR}/${_F}.conf" ] || continue
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
        done < "${CONFIG_DIR}/${_F}.conf"
    done

    # The live values come from one getprop that lists every prop, as "[name]: [value]". One
    # getprop per value is twelve processes.
    while IFS= read -r _L; do
        case $_L in
            "[ro.product.model]: ["*"]")                L_model=${_L#*": ["};  L_model=${L_model%"]"} ;;
            "[ro.product.brand]: ["*"]")                L_brand=${_L#*": ["};  L_brand=${L_brand%"]"} ;;
            "[ro.product.manufacturer]: ["*"]")         L_manuf=${_L#*": ["};  L_manuf=${L_manuf%"]"} ;;
            "[ro.product.device]: ["*"]")               L_device=${_L#*": ["}; L_device=${L_device%"]"} ;;
            "[ro.product.name]: ["*"]")                 L_pname=${_L#*": ["};  L_pname=${L_pname%"]"} ;;
            "[ro.build.fingerprint]: ["*"]")            L_fp=${_L#*": ["};     L_fp=${L_fp%"]"} ;;
            "[ro.vendor.build.fingerprint]: ["*"]")     L_vfp=${_L#*": ["};    L_vfp=${L_vfp%"]"} ;;
            "[ro.build.id]: ["*"]")                     L_bid=${_L#*": ["};    L_bid=${L_bid%"]"} ;;
            "[ro.build.version.security_patch]: ["*"]") L_patch=${_L#*": ["};  L_patch=${L_patch%"]"} ;;
            "[ro.serialno]: ["*"]")                     L_serial=${_L#*": ["}; L_serial=${L_serial%"]"} ;;
            "[ro.board.platform]: ["*"]")               L_plat=${_L#*": ["};   L_plat=${L_plat%"]"} ;;
            "[ro.hardware]: ["*"]")                     L_hw=${_L#*": ["};     L_hw=${L_hw%"]"} ;;
        esac
    done <<EOF
$(getprop 2>/dev/null)
EOF

    local VAL_FIRST=1
    emit_status_val ro.product.model                "Model"              1 "$L_model"  "$O_model"  "$C_model"
    emit_status_val ro.product.brand                "Brand"              1 "$L_brand"  "$O_brand"  "$C_brand"
    emit_status_val ro.product.manufacturer         "Manufacturer"       1 "$L_manuf"  "$O_manuf"  "$C_manuf"
    emit_status_val ro.product.device               "Device"             0 "$L_device" "$O_device" "$C_device"
    emit_status_val ro.product.name                 "Name"               0 "$L_pname"  "$O_pname"  "$C_pname"
    emit_status_val ro.build.fingerprint            "Build fingerprint"  1 "$L_fp"     "$O_fp"     "$C_fp"
    emit_status_val ro.vendor.build.fingerprint     "Vendor fingerprint" 1 "$L_vfp"    "$O_vfp"    "$C_vfp"
    emit_status_val ro.build.id                     "Build ID"           1 "$L_bid"    "$O_bid"    "$C_bid"
    emit_status_val ro.build.version.security_patch "Security patch"     0 "$L_patch"  "$O_patch"  "$C_patch"
    emit_status_val ro.serialno                     "Serial"             1 "$L_serial" "$O_serial" "$C_serial"
    emit_status_val ro.board.platform               "SoC platform"       0 "$L_plat"   "$O_plat"   "$C_plat"
    emit_status_val ro.hardware                     "Hardware"           0 "$L_hw"     "$O_hw"     "$C_hw"

    printf '%s\n' "${STATUS_JSON}]}"
}

cmd_devices() {
    local JA
    [ -n "$DEVICE_HOST_RELEASE" ] || DEVICE_HOST_RELEASE=$(getprop ro.build.version.release 2>/dev/null)
    json_set "$DEVICE_HOST_RELEASE"; JA=$JSTR
    devices_json
    printf '{"ok":true,"android":%s,"devices":%s}\n' "$JA" "$DEVICES_JSON"
}

is_base64_arg() {
    local T="$1"
    case "$T" in '' | *[!A-Za-z0-9+/=]*) return 1 ;; esac
    [ $(( ${#T} % 4 )) -eq 0 ] || return 1
    T=${T%=}
    T=${T%=}
    case "$T" in '' | *=*) return 1 ;; esac
    return 0
}

# $1 = bytes as "od -An -v -tx1" prints them. A byte-level check, so it does not depend on the libc.
is_utf8_hex() {
    local B NEED=0 NEXT=""
    for B in $1; do
        if [ "$NEED" -gt 0 ]; then
            case "${NEXT}:${B}" in
                any:[89ab]?|a0:[ab]?|9f:[89]?|90:[9ab]?|8f:8?) ;;
                *) return 1 ;;
            esac
            NEED=$((NEED - 1))
            NEXT=any
            continue
        fi
        case "$B" in
            [0-7]?) ;;
            c[2-9a-f]|d?) NEED=1; NEXT=any ;;
            e0) NEED=2; NEXT=a0 ;;
            ed) NEED=2; NEXT=9f ;;
            e?) NEED=2; NEXT=any ;;
            f0) NEED=3; NEXT=90 ;;
            f[1-3]) NEED=3; NEXT=any ;;
            f4) NEED=3; NEXT=8f ;;
            *) return 1 ;;
        esac
    done
    [ "$NEED" -eq 0 ]
}

# The WebUI sends a name as "b64:" followed by the base64 of its UTF-8 text, so that any
# character survives the command line. Every other argument (a name typed on the CLI) is the
# name itself and is never decoded.
name_from_arg() {
    local ARG="$1" B64 HEX
    case "$ARG" in
        b64:*)
            B64=${ARG#b64:}
            [ -n "$B64" ] || return 0
            if is_base64_arg "$B64"; then
                HEX=$(printf '%s' "$B64" | base64 -d 2>/dev/null | od -An -v -tx1 2>/dev/null)
                if [ -n "$HEX" ] && is_utf8_hex "$HEX"; then
                    printf '%s' "$B64" | base64 -d 2>/dev/null | persona_clean_name
                    return 0
                fi
            fi
            ;;
    esac
    printf '%s' "$ARG" | persona_clean_name
}

cmd_generate() {
    local ARG="$1" KEY="$2" DEV NAME ID MSG
    # A single argument that is a catalog key (or "random") is the device, not a name.
    if [ -n "$ARG" ] && [ -z "$KEY" ]; then
        if device_resolve_key "$ARG" >/dev/null 2>&1; then
            KEY="$ARG"
            ARG=""
        else
            # Shaped like a device key but not in the catalog: a mistyped key, not a name.
            case "$ARG" in
                *[!a-z0-9_]*) ;;
                *_*)
                    emit_error "Unknown device: ${ARG}. Run 'devicespooflabs devices' for the list. To use it as a name, add the device after it."
                    return 1
                    ;;
            esac
        fi
    fi
    DEV=$(device_resolve_key "$KEY") && device_load "$DEV" \
        || { emit_error "Unknown device: ${KEY:-default}. Run 'devicespooflabs devices' for the list."; return 1; }
    NAME=$(name_from_arg "$ARG")
    [ -n "$NAME" ] || NAME="$DEV_LABEL"
    ID=$(persona_create "$NAME" "$DEV") || { emit_error "${PERSONA_ERROR:-Failed to create persona}"; return 1; }
    persona_activate "$ID" || { emit_error "${PERSONA_ERROR:-Failed to activate persona}"; return 1; }
    NAME=$(persona_get_name "$ID")
    if [ "$NAME" = "$DEV_LABEL" ]; then
        MSG="Persona \"${NAME}\" generated and activated. Reboot to apply."
    else
        MSG="Persona \"${NAME}\" (${DEV_LABEL}) generated and activated. Reboot to apply."
    fi
    [ "$DEV_MATCH" = true ] || \
        MSG="${MSG} It uses the ${DEV_LABEL} Android ${DEV_RELEASE} build (no build for Android ${DEVICE_HOST_RELEASE:-?})."
    printf '{"ok":true,"reboot_required":true,"id":%s,"name":%s,"message":%s}\n' \
        "$(json_str "$ID")" "$(json_str "$NAME")" "$(json_str "$MSG")"
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
    local ID="$1" DIR LINE JI JN JC JB JM
    local NAME=Persona CREATED='' BRAND='' MODEL='' AITGT=0 AIEN=false ACT=false
    DIR="${PERSONAS_DIR}/${ID}"

    if [ -f "${DIR}/meta" ]; then
        while IFS= read -r LINE || [ -n "$LINE" ]; do
            case $LINE in
                NAME=?*)   NAME=${LINE#NAME=} ;;
                CREATED=*) CREATED=${LINE#CREATED=} ;;
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

    [ "$PERSONA_FIRST" -eq 1 ] || PERSONAS_JSON="${PERSONAS_JSON},"
    PERSONA_FIRST=0
    PERSONAS_JSON="${PERSONAS_JSON}{\"id\":${JI},\"name\":${JN},\"created\":${JC},\"active\":${ACT},\"brand\":${JB},\"model\":${JM},\"android_id_enabled\":${AIEN},\"android_id_targets\":${AITGT}}"
}

cmd_personas_list() {
    local ID PERSONA_FIRST=1 PERSONA_ACTIVE_ID JA PERSONAS_JSON=""
    PERSONA_ACTIVE_ID=$(persona_active_id 2>/dev/null)
    if [ -n "$PERSONA_ACTIVE_ID" ]; then json_set "$PERSONA_ACTIVE_ID"; JA=$JSTR; else JA=null; fi
    for ID in $(persona_list_ids); do
        emit_persona_row "$ID"
    done
    printf '{"ok":true,"active":%s,"personas":[%s]}\n' "$JA" "$PERSONAS_JSON"
}

cmd_persona_activate() {
    local ID="$1"
    [ -n "$ID" ] || { emit_error "No persona id given"; return 1; }
    persona_activate "$(printf '%s' "$ID" | tr -d ' \t\n\r')" \
        || { emit_error "${PERSONA_ERROR:-Failed to activate persona}"; return 1; }
    emit_ok_reboot "Persona activated. Reboot to apply."
}

cmd_persona_rename() {
    local ID="$1" NAME
    [ -n "$ID" ] || { emit_error "No persona id given"; return 1; }
    NAME=$(name_from_arg "$2")
    [ -n "$NAME" ] || { emit_error "Empty name"; return 1; }
    ID=$(printf '%s' "$ID" | tr -d ' \t\n\r')
    persona_rename "$ID" "$NAME" || { emit_error "${PERSONA_ERROR:-Rename failed}"; return 1; }
    emit_ok "Renamed to \"$(persona_get_name "$ID")\"."
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

media_scan() {
    command -v content >/dev/null 2>&1 || return 0
    if command -v timeout >/dev/null 2>&1; then
        timeout 10 content call --uri content://media --method scan_file --arg "$1" >/dev/null 2>&1
    else
        content call --uri content://media --method scan_file --arg "$1" >/dev/null 2>&1
    fi
}

# MediaStore indexing is best effort and slow (one app_process per file), so it runs detached:
# nothing of it reaches stdout and the reply does not wait for it. The exec is what lets go of
# the caller's stdout; with a redirection on the subshell mksh keeps a copy of it open.
media_scan_later() {
    local F
    command -v content >/dev/null 2>&1 || return 0
    (
        exec </dev/null >/dev/null 2>&1
        trap '' HUP
        for F in "$@"; do
            media_scan "$F"
        done
    ) &
}

cmd_persona_export() {
    local WHICH="${1:-all}" IDS ID COUNT=0 SHOWN FAILED=0
    case "$WHICH" in
        all) IDS=$(persona_list_ids) ;;
        *)   IDS=$(printf '%s' "$WHICH" | tr -d ' \t\n\r') ;;
    esac
    [ -n "$IDS" ] || { emit_error "No personas to export."; return 1; }

    mkdir -p "$PERSONA_EXPORT_DIR" 2>/dev/null
    [ -d "$PERSONA_EXPORT_DIR" ] || { emit_error "Could not create ${PERSONA_EXPORT_DIR}. Is the phone unlocked?"; return 1; }

    set --
    for ID in $IDS; do
        persona_export "$ID" "$PERSONA_EXPORT_DIR" || { FAILED=1; break; }
        set -- "$@" "$PERSONA_EXPORTED"
        COUNT=$((COUNT + 1))
    done
    [ "$#" -eq 0 ] || media_scan_later "$@"
    [ "$FAILED" -eq 0 ] || { emit_error "${PERSONA_ERROR:-Export failed}"; return 1; }

    SHOWN=${PERSONA_EXPORT_DIR#/storage/emulated/0/}
    if [ "$COUNT" -eq 1 ]; then
        printf '{"ok":true,"count":1,"path":%s,"message":%s}\n' "$(json_str "$PERSONA_EXPORTED")" \
            "$(json_str "Exported to ${SHOWN}/${PERSONA_EXPORTED##*/}")"
    else
        printf '{"ok":true,"count":%s,"path":%s,"message":%s}\n' "$COUNT" "$(json_str "$PERSONA_EXPORT_DIR")" \
            "$(json_str "Exported ${COUNT} personas to ${SHOWN}")"
    fi
}

cmd_persona_imports() {
    local F FIRST=1
    printf '{"ok":true,"dir":%s,"files":[' "$(json_str "$PERSONA_EXPORT_DIR")"
    for F in "$PERSONA_EXPORT_DIR"/*.persona "$PERSONA_EXPORT_DIR"/*.persona.txt \
             "${PERSONA_EXPORT_DIR%/*}"/*.persona "${PERSONA_EXPORT_DIR%/*}"/*.persona.txt; do
        [ -f "$F" ] || continue
        # A path with a control character cannot be sent back through the JSON unchanged.
        case $F in *[$__JSON_CTRL]*) continue ;; esac
        [ "$FIRST" -eq 1 ] || printf ','
        FIRST=0
        printf '{"path":%s,"file":%s}' "$(json_str "$F")" "$(json_str "${F##*/}")"
    done
    printf ']}'
    printf '\n'
}

cmd_persona_import() {
    local FILE="$1" RC MSG HOST
    [ -n "$FILE" ] || { emit_error "No file given"; return 1; }
    persona_import "$FILE"
    RC=$?
    case "$RC" in
        0)
            MSG="Imported \"${PERSONA_IMPORTED_NAME}\". Switch it on to use it."
            HOST=$(getprop ro.build.version.release 2>/dev/null)
            if [ -n "$PERSONA_IMPORTED_RELEASE" ] && [ -n "$HOST" ] && [ "$PERSONA_IMPORTED_RELEASE" != "$HOST" ]; then
                MSG="${MSG} Its build is for Android ${PERSONA_IMPORTED_RELEASE}; this phone runs Android ${HOST}."
            fi
            printf '{"ok":true,"id":%s,"name":%s,"message":%s}\n' \
                "$(json_str "$PERSONA_IMPORTED_ID")" "$(json_str "$PERSONA_IMPORTED_NAME")" \
                "$(json_str "$MSG")"
            ;;
        2)
            printf '{"ok":true,"skipped":true,"id":%s,"name":%s,"message":%s}\n' \
                "$(json_str "$PERSONA_IMPORTED_ID")" "$(json_str "$PERSONA_IMPORTED_NAME")" \
                "$(json_str "Already imported as \"${PERSONA_IMPORTED_NAME}\".")"
            ;;
        *)
            emit_error "Import failed: ${PERSONA_ERROR:-invalid file}"
            return 1
            ;;
    esac
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
    # toybox base64 -d does not fail on text that is not base64; it would replace the file with garbage.
    B64=$(printf '%s' "$B64" | tr -d ' \t\n\r')
    is_base64_arg "$B64" || { emit_error "Content is not base64"; return 1; }

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
    # Resolve generator tokens now; post-fs-data refuses an unresolved one on every boot.
    local MSG="Saved."
    if ! freeze_config_generators "$FILE"; then
        log "Config $NAME: a generator token could not be resolved"
        MSG="Saved, but a generator token is not valid, so no token in this file was resolved. Lines with a token are skipped at boot."
    fi
    persona_sync_file_from_config "$NAME"
    mark_reboot
    log "Config written: $NAME"
    emit_ok_reboot "$MSG"
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
    local VCODE RP CONF FILE EN HDR KEY LIVE CONFV ORIG ST GUARD
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
    GUARD="not yet"
    [ -f "$BOOT_WATCH_FILE" ] && GUARD=on
    [ -f "$BOOT_GUARD_OFF_FILE" ] && GUARD="switched off"
    echo "boot_attempts    : $(cat "$BOOT_ATTEMPTS_FILE" 2>/dev/null || echo 0) (counting ${GUARD})"
    echo "auto_disabled    : $( [ -f "$AUTO_DISABLED_FILE" ] && echo yes || echo no )"
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
    # A restart asked for here is not an unfinished boot (see boot_guard in post-fs-data.sh).
    rm -f "$BOOT_ATTEMPTS_FILE" 2>/dev/null
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
    local ENABLED=false VALUE USER PKG FIRST=1 JV JU JT=""
    ai_is_enabled && ENABLED=true
    VALUE=$(ai_get_value)
    USER=$(ai_get_user)
    json_set "$VALUE"; JV=$JSTR
    json_set "$USER";  JU=$JSTR
    while IFS= read -r PKG; do
        [ -n "$PKG" ] || continue
        [ "$FIRST" -eq 1 ] || JT="${JT},"
        FIRST=0
        json_set "$PKG"
        JT="${JT}${JSTR}"
    done <<EOF
$(ai_get_targets)
EOF
    printf '{"ok":true,"enabled":%s,"value":%s,"user_id":%s,"targets":[%s]}\n' "$ENABLED" "$JV" "$JU" "$JT"
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

# am can exit 0 when the activity was not started; the error is then only in its output.
am_start() {
    local OUT
    OUT=$(am start "$@" 2>&1) || return 1
    case "$OUT" in *Error*) return 1 ;; esac
    return 0
}

launch_ksuwebui() {
    log "[webui] launch $KSUWEBUI_ACTIVITY id=$MODULE_ID"
    am_start -n "$KSUWEBUI_ACTIVITY" -e id "$MODULE_ID" -e name "$MODULE_NAME"
}

webuix_installed() {
    pm path "$WEBUIX_PKG" >/dev/null 2>&1
}

# WebUI X v571 moved the activity and renamed the extra; older builds only have the old class.
launch_webuix() {
    local ACT
    for ACT in "$WEBUIX_ACTIVITY" "$WEBUIX_ACTIVITY_OLD"; do
        log "[webui] launch $ACT MODULE_ID=$MODULE_ID"
        am_start -n "$ACT" -e MODULE_ID "$MODULE_ID" -e MOD_ID "$MODULE_ID" -e id "$MODULE_ID" && return 0
    done
    return 1
}

pkg_installed() {
    pm path "$1" >/dev/null 2>&1
}

# KernelSU 3.3.0 and SukiSU 4.2.0 read the module id from "?id=" in the intent data; older
# KernelSU, KernelSU-Next and APatch read the id/name extras. One intent carries both.
launch_native_webui_component() {
    local PKG="$1" CLASS="$2" SCHEME="$3"
    log "[webui] launch native $PKG/$CLASS id=$MODULE_ID"
    am_start -a android.intent.action.VIEW \
        -n "${PKG}/${CLASS}" \
        -d "${SCHEME}://webui?id=${MODULE_ID}" \
        -e id "$MODULE_ID" \
        -e name "$MODULE_NAME"
}

launch_native_manager_webui() {
    local MGR="$1" PKG

    case "$MGR" in
        KernelSU)
            for PKG in me.weishu.kernelsu me.weishu.kernelsu.dev; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "me.weishu.kernelsu.ui.webui.WebUIActivity" ksu; then
                    return 0
                fi
            done
            for PKG in com.rifsxd.ksunext; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "com.rifsxd.ksunext.ui.webui.WebUIActivity" ksu; then
                    return 0
                fi
            done
            for PKG in com.sukisu.ultra; do
                if pkg_installed "$PKG" && launch_native_webui_component "$PKG" "com.sukisu.ultra.ui.webui.WebUIActivity" ksu; then
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
  devices                       List the device catalog as JSON (build picked for this Android version)
  generate-persona [name] [device|random]
                                Create a persona from a catalog device (default: the first one),
                                activate it, mark reboot. The name defaults to the device name.
                                A single argument that is a device key is taken as the device:
                                  generate-persona galaxy_a55
                                  generate-persona "Work phone" pixel_8_pro
  activate [id]                 Activate a persona by id (or the current/most-recent one)
  persona-activate <id>         Activate the persona with this id (deactivates any other)
  persona-rename <id> <name>    Rename a persona
  persona-delete <id>           Delete a persona (deactivates first if it was active)
  persona-export [id|all]       Export personas as .persona files to /sdcard/Download/DeviceSpoofLabs
  persona-imports               List .persona files in Download/DeviceSpoofLabs and Download as JSON
  persona-import <path>         Import a .persona file (it is not activated)
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
A name is plain text. For a name with characters that are hard to type in a shell, pass
b64:<base64 of the UTF-8 name> instead (the WebUI sends names that way).
Put --b64 before a command to get its stdout and its stderr base64-encoded, each after the
marker b64: (the WebUI calls every command that way).
Most actions require a reboot to take effect.
EOF
}

case "${1:-status}" in
    status)                     cmd_status ;;
    personas|personas-list)     cmd_personas_list ;;
    devices)                    cmd_devices ;;
    generate-persona|generate)  cmd_generate "$2" "$3" ;;
    activate)                   cmd_activate "$2" ;;
    persona-activate)           cmd_persona_activate "$2" ;;
    persona-rename)             cmd_persona_rename "$2" "$3" ;;
    persona-delete)             cmd_persona_delete "$2" ;;
    persona-export)             cmd_persona_export "$2" ;;
    persona-imports)            cmd_persona_imports ;;
    persona-import)             cmd_persona_import "$2" ;;
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
