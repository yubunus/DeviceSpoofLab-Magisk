#!/system/bin/sh
value_resolver_log() {
    case "$(type log 2>/dev/null)" in
        *function*)
            log "$1"
            ;;
    esac
}

replace_first() {
    local TEXT="$1"
    local NEEDLE="$2"
    local REPLACEMENT="$3"
    local PREFIX SUFFIX

    PREFIX=${TEXT%%"$NEEDLE"*}
    SUFFIX=${TEXT#*"$NEEDLE"}
    printf '%s%s%s\n' "$PREFIX" "$REPLACEMENT" "$SUFFIX"
}

generate_hex() {
    local LENGTH=${1:-16}

    case "$LENGTH" in
        ''|*[!0-9]*) LENGTH=16 ;;
    esac
    [ "$LENGTH" -lt 1 ] && LENGTH=16

    # dd, not head -c: toybox on Android 8.0 has no head -c.
    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | dd bs=1 count="$LENGTH" 2>/dev/null
}

generate_serial() {
    LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | dd bs=1 count=12 2>/dev/null
}

resolve_value() {
    local VALUE="$1"
    local TOKEN REPLACEMENT LEN

    while :; do
        case "$VALUE" in
            *'${RANDOM_HEX:'*'}'*)
                TOKEN=$(printf '%s\n' "$VALUE" | sed -n 's/.*\(\${RANDOM_HEX:[0-9][0-9]*}\).*/\1/p')
                [ -z "$TOKEN" ] && break
                LEN=$(printf '%s\n' "$TOKEN" | sed 's/${RANDOM_HEX:\([0-9][0-9]*\)}/\1/')
                REPLACEMENT=$(generate_hex "$LEN")
                VALUE=$(replace_first "$VALUE" "$TOKEN" "$REPLACEMENT")
                ;;
            *'${RANDOM_SERIAL}'*)
                REPLACEMENT=$(generate_serial)
                VALUE=$(replace_first "$VALUE" '${RANDOM_SERIAL}' "$REPLACEMENT")
                ;;
            *)
                break
                ;;
        esac
    done

    case "$VALUE" in
        *'${RANDOM_'*)
            value_resolver_log "Unresolved generator token in config value"
            return 1
            ;;
    esac

    printf '%s\n' "$VALUE"
}

has_generator_token() {
    case "$1" in
        *'${RANDOM_'*) return 0 ;;
        *) return 1 ;;
    esac
}

freeze_config_generators() {
    local FILE="$1"
    local TMP="${FILE}.tmp.$$"
    local LINE STATUS PROP RAW VALUE REST OUT="" CHANGED=0 NL='
'

    FREEZE_CONFIG_CHANGED=0
    [ -f "$FILE" ] || return 0

    # The new text is built in memory and written only when a token was resolved. Most files have
    # none, and a process per line is what made this slow on a phone.
    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            ''|'#'*|FILE_ENABLED|FILE_DISABLED)
                OUT="${OUT}${LINE}${NL}"
                continue
                ;;
            *'${RANDOM_'*) ;;
            *)
                OUT="${OUT}${LINE}${NL}"
                continue
                ;;
        esac

        STATUS=${LINE%%,*}
        REST=${LINE#*,}
        PROP=${REST%%,*}
        RAW=${REST#*,}

        if [ "$STATUS" != "$LINE" ] && [ -n "$PROP" ] && has_generator_token "$RAW"; then
            VALUE=$(resolve_value "$RAW") || return 1
            OUT="${OUT}${STATUS},${PROP},${VALUE}${NL}"
            CHANGED=1
        else
            OUT="${OUT}${LINE}${NL}"
        fi
    done < "$FILE"

    [ "$CHANGED" -eq 1 ] || return 0
    printf '%s' "$OUT" > "$TMP" || { rm -f "$TMP"; return 1; }
    chmod 600 "$TMP" 2>/dev/null
    mv -f "$TMP" "$FILE"
    FREEZE_CONFIG_CHANGED=1
}
