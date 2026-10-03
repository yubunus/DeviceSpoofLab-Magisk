#!/system/bin/sh
# Allowlist guard: only safe identity props may be spoofed; security_patch is blocked even in unsafe mode.

ALLOW_UNSAFE_PROPS_FILE="${CONFIG_DIR}/allow_unsafe_props"

safety_log() {
    case "$(type log 2>/dev/null)" in
        *function*) log "$1" ;;
    esac
}

unsafe_props_allowed() {
    [ -f "$ALLOW_UNSAFE_PROPS_FILE" ] && return 0
    [ "$(getprop persist.devicespooflab.allow_unsafe 2>/dev/null)" = "1" ] && return 0
    return 1
}

is_blocked_prop() {
    case "$1" in
        ro.build.version.security_patch|\
        ro.vendor.build.security_patch|\
        ro.odm.build.security_patch)
            return 0
            ;;
    esac

    return 1
}

is_safe_identity_prop() {
    case "$1" in
        ro.product.brand|\
        ro.product.manufacturer|\
        ro.product.model|\
        ro.product.product.brand|\
        ro.product.product.manufacturer|\
        ro.product.product.model|\
        ro.product.system.brand|\
        ro.product.system.manufacturer|\
        ro.product.system.model|\
        ro.product.system_ext.brand|\
        ro.product.system_ext.manufacturer|\
        ro.product.system_ext.model)
            return 0
            ;;
        ro.build.fingerprint|\
        ro.build.id|\
        ro.build.display.id|\
        ro.build.version.incremental|\
        ro.build.type|\
        ro.build.tags|\
        ro.build.description|\
        ro.build.flavor|\
        ro.product.build.fingerprint|\
        ro.product.build.id|\
        ro.product.build.tags|\
        ro.product.build.type|\
        ro.product.build.version.incremental|\
        ro.system.build.fingerprint|\
        ro.system_ext.build.fingerprint)
            return 0
            ;;
        ro.vendor.build.fingerprint|\
        ro.vendor.build.id|\
        ro.vendor.build.version.incremental|\
        ro.vendor.build.tags|\
        ro.vendor.build.type|\
        ro.odm.build.fingerprint|\
        ro.odm.build.version.incremental)
            return 0
            ;;
        ro.serialno)
            return 0
            ;;
    esac

    return 1
}

should_apply_prop() {
    local PROP="$1"
    local VALUE="$2"
    local STAGE="$3"
    local SOURCE="$4"

    if is_blocked_prop "$PROP"; then
        safety_log "Hard block (${STAGE}/${SOURCE}): $PROP=$VALUE (never spoofed, even in unsafe mode)"
        return 1
    fi

    unsafe_props_allowed && return 0

    if is_safe_identity_prop "$PROP"; then
        return 0
    fi

    safety_log "Allowlist skip (${STAGE}/${SOURCE}): $PROP=$VALUE (not a safe identity prop)"
    return 1
}
