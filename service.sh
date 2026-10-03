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

boot_look() {
    printf '%s/%s' "$(pidof system_server 2>/dev/null)" "$(pidof com.android.systemui 2>/dev/null)"
}

# post-fs-data.sh counts each boot that applies a persona and switches the persona off after
# two that never finished. A boot has finished when the phone is up and system_server and
# SystemUI have kept their process for 30 seconds; a phone that crash-loops or reboots before
# that leaves the count in place. BOOT_WATCH_FILE tells post-fs-data.sh that this check runs
# on this phone; without it nothing is counted. Runs detached, so the service stage is not
# held up.
watch_boot() {
    [ -n "$BOOT_ATTEMPTS_FILE" ] || return 0
    [ -f "$BOOT_ATTEMPTS_FILE" ] || [ ! -f "$BOOT_WATCH_FILE" ] || return 0
    (
        exec </dev/null >/dev/null 2>&1
        until [ "$(getprop sys.boot_completed 2>/dev/null)" = "1" ]; do
            sleep 5
        done
        touch "$BOOT_WATCH_FILE" 2>/dev/null

        # Eleven looks, 3 seconds apart, must show the same two processes.
        SEEN_UI=0
        WARNED=0
        while :; do
            FIRST=$(boot_look)
            case "$FIRST" in */?*) SEEN_UI=1 ;; esac
            STABLE=1
            N=0
            while [ "$N" -lt 10 ]; do
                sleep 3
                N=$((N + 1))
                NOW=$(boot_look)
                case "$NOW" in */?*) SEEN_UI=1 ;; esac
                [ "$NOW" = "$FIRST" ] || { STABLE=0; break; }
            done
            if [ "$STABLE" -eq 1 ]; then
                case "$FIRST" in
                    # No system_server: fine only where pidof finds nothing at all.
                    /*) [ -z "$(pidof init 2>/dev/null)" ] || STABLE=0 ;;
                    # No SystemUI: fine only where it was never there (another process name).
                    */) [ "$SEEN_UI" -eq 0 ] || STABLE=0 ;;
                esac
            fi
            [ "$STABLE" -eq 0 ] || break
            [ "$WARNED" -eq 1 ] || log "Boot not finished yet (system_server or SystemUI restarted), still watching"
            WARNED=1
        done
        rm -f "$BOOT_ATTEMPTS_FILE" 2>/dev/null
        fsync "${BOOT_ATTEMPTS_FILE%/*}" 2>/dev/null || sync
        log "Boot finished (system stable)"
    ) &
}

log "Service starting..."

if [ -f "${MODDIR}/disable" ]; then
    log "Module disabled - skipping"
    exit 0
fi

ensure_cli_in_path
watch_boot

log "Service complete (CLI path ensured; spoofing handled pre-zygote)"
