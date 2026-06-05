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

    LC_ALL=C tr -dc 'a-f0-9' < /dev/urandom | head -c "$LENGTH"
}

generate_serial() {
    LC_ALL=C tr -dc 'A-Z0-9' < /dev/urandom | head -c 12
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
    local LINE STATUS PROP RAW VALUE REST CHANGED=0

    FREEZE_CONFIG_CHANGED=0
    [ -f "$FILE" ] || return 0

    grep -qF '${RANDOM_' "$FILE" 2>/dev/null || return 0

    : > "$TMP" || return 1

    while IFS= read -r LINE || [ -n "$LINE" ]; do
        case "$LINE" in
            ''|'#'*|FILE_ENABLED|FILE_DISABLED)
                printf '%s\n' "$LINE" >> "$TMP" || { rm -f "$TMP"; return 1; }
                continue
                ;;
            *'${RANDOM_'*) ;;
            *)
                printf '%s\n' "$LINE" >> "$TMP" || { rm -f "$TMP"; return 1; }
                continue
                ;;
        esac

        STATUS=${LINE%%,*}
        REST=${LINE#*,}
        PROP=${REST%%,*}
        RAW=${REST#*,}

        if [ "$STATUS" != "$LINE" ] && [ -n "$PROP" ] && has_generator_token "$RAW"; then
            VALUE=$(resolve_value "$RAW") || { rm -f "$TMP"; return 1; }
            printf '%s,%s,%s\n' "$STATUS" "$PROP" "$VALUE" >> "$TMP" || { rm -f "$TMP"; return 1; }
            CHANGED=1
        else
            printf '%s\n' "$LINE" >> "$TMP" || { rm -f "$TMP"; return 1; }
        fi
    done < "$FILE"

    if [ "$CHANGED" -eq 1 ]; then
        chmod 600 "$TMP" 2>/dev/null
        mv -f "$TMP" "$FILE"
        FREEZE_CONFIG_CHANGED=1
    else
        rm -f "$TMP"
    fi
}
