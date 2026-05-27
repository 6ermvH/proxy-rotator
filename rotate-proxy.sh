#!/usr/bin/env bash
#
# Выбирает следующий SOCKS5-прокси из списка, генерирует redsocks.conf
# и перезапускает redsocks. Запускается по таймеру systemd раз в 30 минут.
#
set -euo pipefail

CONF_DIR="/etc/redsocks-rotator"
PROXIES_FILE="${CONF_DIR}/proxies.txt"
OUTPUT_CONF="${CONF_DIR}/redsocks.conf"
STATE_FILE="${CONF_DIR}/.state"          # индекс последнего использованного прокси
SERVICE="redsocks-rotated.service"
LOCAL_PORT=12345                          # должен совпадать с REDSOCKS_PORT в iptables-redsocks.sh

# Порядок обхода: "rr" (round-robin) или "random".
MODE="${ROTATE_MODE:-rr}"

# Считываем непустые строки без комментариев.
mapfile -t PROXIES < <(grep -vE '^[[:space:]]*(#|$)' "$PROXIES_FILE")
COUNT=${#PROXIES[@]}
if (( COUNT == 0 )); then
    echo "rotate-proxy: proxy list is empty: $PROXIES_FILE" >&2
    exit 1
fi

if [[ "$MODE" == "random" ]]; then
    next=$(( RANDOM % COUNT ))
else
    last=-1
    [[ -f "$STATE_FILE" ]] && last=$(cat "$STATE_FILE" 2>/dev/null || echo -1)
    [[ "$last" =~ ^-?[0-9]+$ ]] || last=-1
    next=$(( (last + 1) % COUNT ))
fi

line="${PROXIES[$next]}"
# pass получает весь остаток после третьего ':', даже если в пароле есть ':'.
IFS=':' read -r host port user pass <<< "$line"

if [[ -z "${host:-}" || -z "${port:-}" ]]; then
    echo "rotate-proxy: malformed proxy line #${next}: $line" >&2
    exit 1
fi

umask 077
cat > "$OUTPUT_CONF" <<EOF
base {
    log_debug = off;
    log_info = on;
    log = "syslog:daemon";
    daemon = off;
    redirector = iptables;
}

redsocks {
    local_ip = 127.0.0.1;
    local_port = ${LOCAL_PORT};
    ip = ${host};
    port = ${port};
    type = socks5;
    login = "${user:-}";
    password = "${pass:-}";
}
EOF

echo "$next" > "$STATE_FILE"
logger -t rotate-proxy "switching to proxy #${next}: ${host}:${port}"

systemctl restart "$SERVICE"
