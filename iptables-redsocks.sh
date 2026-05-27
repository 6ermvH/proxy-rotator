#!/usr/bin/env bash
#
# Настройка прозрачного редиректа TCP в redsocks через iptables (таблица nat).
# По умолчанию заворачивается исходящий трафик самого сервера (chain OUTPUT).
# Для режима "шлюз для других машин" см. блок PREROUTING ниже.
#
set -euo pipefail

REDSOCKS_PORT=12345        # должен совпадать с LOCAL_PORT в rotate-proxy.sh
REDSOCKS_USER=redsocks     # под этим пользователем работает redsocks (исключаем из редиректа)

# Для режима "шлюз": раскомментируй и укажи интерфейс локальной сети.
# LAN_IFACE=eth1

start() {
    iptables -t nat -N REDSOCKS 2>/dev/null || iptables -t nat -F REDSOCKS

    # Локальные / зарезервированные сети идут напрямую, мимо прокси.
    for net in 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 \
               169.254.0.0/16 172.16.0.0/12 192.168.0.0/16 \
               224.0.0.0/4 240.0.0.0/4; do
        iptables -t nat -A REDSOCKS -d "$net" -j RETURN
    done

    # Весь остальной TCP — в redsocks.
    iptables -t nat -A REDSOCKS -p tcp -j REDIRECT --to-ports "$REDSOCKS_PORT"

    # КРИТИЧНО: трафик самого redsocks к upstream-прокси не заворачиваем,
    # иначе получится бесконечная петля. redsocks работает под uid $REDSOCKS_USER.
    iptables -t nat -C OUTPUT -p tcp -m owner --uid-owner "$REDSOCKS_USER" -j RETURN 2>/dev/null \
        || iptables -t nat -A OUTPUT -p tcp -m owner --uid-owner "$REDSOCKS_USER" -j RETURN

    # Исходящий TCP самого сервера -> REDSOCKS.
    iptables -t nat -C OUTPUT -p tcp -j REDSOCKS 2>/dev/null \
        || iptables -t nat -A OUTPUT -p tcp -j REDSOCKS

    # --- Режим "шлюз для других машин" (вместо/вдобавок к OUTPUT) ---
    # Требует включённого ip_forward: sysctl -w net.ipv4.ip_forward=1
    # if [[ -n "${LAN_IFACE:-}" ]]; then
    #     iptables -t nat -C PREROUTING -i "$LAN_IFACE" -p tcp -j REDSOCKS 2>/dev/null \
    #         || iptables -t nat -A PREROUTING -i "$LAN_IFACE" -p tcp -j REDSOCKS
    # fi
}

stop() {
    iptables -t nat -D OUTPUT -p tcp -j REDSOCKS 2>/dev/null || true
    iptables -t nat -D OUTPUT -p tcp -m owner --uid-owner "$REDSOCKS_USER" -j RETURN 2>/dev/null || true
    # iptables -t nat -D PREROUTING -i "${LAN_IFACE:-eth1}" -p tcp -j REDSOCKS 2>/dev/null || true
    iptables -t nat -F REDSOCKS 2>/dev/null || true
    iptables -t nat -X REDSOCKS 2>/dev/null || true
}

case "${1:-}" in
    start)   start ;;
    stop)    stop ;;
    restart) stop; start ;;
    *) echo "usage: $0 {start|stop|restart}" >&2; exit 1 ;;
esac
