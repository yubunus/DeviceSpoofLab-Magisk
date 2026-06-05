#!/system/bin/sh
MODDIR=${0%/*}
LOG_FILE="${LOG_FILE:-/data/adb/devicespooflab/devicespooflab.log}"

log() {
    case "$(type append_log_line 2>/dev/null)" in
        *function*)
            append_log_line "[$(date '+%Y-%m-%d %H:%M:%S')] [service] $1"
            ;;
        *)
            mkdir -p "${LOG_FILE%/*}" 2>/dev/null
            chmod 700 "${LOG_FILE%/*}" 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] [service] $1" >> "$LOG_FILE"
            chmod 600 "$LOG_FILE" 2>/dev/null
            ;;
    esac
}

if [ -f "${MODDIR}/common/state.sh" ]; then
    . "${MODDIR}/common/state.sh"
    ensure_persistent_state
fi

ensure_cli_in_path() {
    local LAUNCHER="${MODDIR}/system/bin/devicespooflabs"
    [ -f "$LAUNCHER" ] || return 0

    [ -x /system/bin/devicespooflabs ] && return 0

    for BIN in /data/adb/ksu/bin /data/adb/ap/bin; do
        if [ -d "$BIN" ]; then
            ln -sf "$LAUNCHER" "$BIN/devicespooflabs" 2>/dev/null && \
                log "CLI symlink: $BIN/devicespooflabs -> $LAUNCHER"
            return 0
        fi
    done
}

log "Service starting..."

if [ -f "${MODDIR}/disable" ]; then
    log "Module disabled - skipping"
    exit 0
fi

ensure_cli_in_path

log "Service complete (CLI path ensured; spoofing handled pre-zygote)"
