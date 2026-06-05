#!/system/bin/sh
# Module installer (Magisk / KernelSU / APatch).

SKIPUNZIP=0

ui_print " "
ui_print "********************************"
ui_print "   DeviceSpoofLabs v3.0"
ui_print "********************************"
ui_print " "

if [ -n "$KSU" ]; then
    ui_print "- KernelSU $KSU_VER ($KSU_KERNEL_VER_CODE) detected"
    ROOT_MGR="ksu"
elif [ -n "$APATCH" ]; then
    ui_print "- APatch $APATCH_VER detected"
    ROOT_MGR="apatch"
elif [ -n "$MAGISK_VER_CODE" ]; then
    ui_print "- Magisk $MAGISK_VER ($MAGISK_VER_CODE) detected"
    ROOT_MGR="magisk"
    [ "$MAGISK_VER_CODE" -lt 20400 ] && abort "! Requires Magisk 20.4 or newer"
else
    abort "! Unsupported environment - install via Magisk, KernelSU, or APatch manager"
fi

migrate_persistent_state() {
    ui_print "- Preparing persistent state in /data/adb/devicespooflab"

    MODDIR="$MODPATH"
    DATA_DIR="/data/adb/devicespooflab"
    CONFIG_DIR="${DATA_DIR}/config"
    MODULE_CONFIG_DIR="${MODPATH}/config"
    LEGACY_CONFIG_DIR="/data/adb/modules/devicespooflab/config"

    if [ -f "${MODPATH}/common/state.sh" ]; then
        . "${MODPATH}/common/state.sh"
        ensure_persistent_state
    else
        abort "! Missing common/state.sh"
    fi
}

migrate_persistent_state

warn_if_unsafe_props_enabled() {
    if [ -f "/data/adb/devicespooflab/config/allow_unsafe_props" ] || \
        [ "$(getprop persist.devicespooflab.allow_unsafe 2>/dev/null)" = "1" ]; then
        ui_print "! WARNING: unsafe prop mode is enabled"
        ui_print "! custom.conf can bypass the safety allowlist pre-zygote"
        ui_print "! Unsafe props can bootloop or destabilize the device"
    fi
}

warn_if_unsafe_props_enabled

ui_print "- Installing module files..."

set_permissions() {
    ui_print "- Setting permissions"
    set_perm_recursive "$MODPATH" 0 0 0755 0644
    set_perm_recursive "$MODPATH/common" 0 0 0755 0755
    set_perm "$MODPATH/system/bin/devicespooflabs" 0 2000 0755
    set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
    set_perm "$MODPATH/service.sh" 0 0 0755
    set_perm "$MODPATH/uninstall.sh" 0 0 0755
    [ -f "$MODPATH/action.sh" ] && set_perm "$MODPATH/action.sh" 0 0 0755
}

set_permissions

ui_print "- No spoofing is applied until you activate a persona, then reboot"
ui_print " "
