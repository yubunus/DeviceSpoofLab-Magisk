#!/system/bin/sh
MODDIR="${0%/*}"
[ -f "${MODDIR}/common/webctl.sh" ] || MODDIR="/data/adb/modules/devicespooflab"

exec "${MODDIR}/common/webctl.sh" open-webui
