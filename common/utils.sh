#!/system/bin/sh
MODDIR="${MODDIR:-/data/adb/modules/devicespooflab}"
SCRIPT_DIR="${SCRIPT_DIR:-${0%/*}}"
LOG_FILE="${LOG_FILE:-/data/adb/devicespooflab/devicespooflab.log}"

if [ -f "${SCRIPT_DIR}/state.sh" ]; then
    . "${SCRIPT_DIR}/state.sh"
    ensure_persistent_state
else
    CONFIG_DIR="${CONFIG_DIR:-${MODDIR}/config}"
    PERSONA_FLAG="${PERSONA_FLAG:-${CONFIG_DIR}/persona_active}"
    BACKUP_FILE="${BACKUP_FILE:-${CONFIG_DIR}/backup.conf}"
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'

print_color() {
    printf '%b\n' "${1}${2}${NC}"
}

print_error() {
    printf '%b\n' "${RED}[!] ${1}${NC}"
}

print_ok() {
    printf '%b\n' "${GREEN}[+] ${1}${NC}"
}

print_warn() {
    printf '%b\n' "${YELLOW}[*] ${1}${NC}"
}

print_info() {
    printf '%b\n' "${CYAN}[i] ${1}${NC}"
}

log() {
    case "$(type append_log_line 2>/dev/null)" in
        *function*)
            append_log_line "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
            ;;
        *)
            mkdir -p "${LOG_FILE%/*}" 2>/dev/null
            chmod 700 "${LOG_FILE%/*}" 2>/dev/null
            echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
            chmod 600 "$LOG_FILE" 2>/dev/null
            ;;
    esac
}
