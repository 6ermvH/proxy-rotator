# socks-proxy-rotator

Прозрачная маршрутизация исходящего TCP-трафика сервера через SOCKS5-прокси
с автоматической сменой прокси раз в 30 минут.

Стек: **redsocks** (заворачивает TCP в SOCKS5) + **iptables** (перехват трафика)
+ **systemd timer** (ротация по расписанию). Своего кода — только скрипт ротации.

## Состав

| Файл                       | Назначение                                                        |
|----------------------------|-------------------------------------------------------------------|
| `proxies.txt`              | Список прокси, формат `IP:PORT:USER:PASS`, по одному в строке      |
| `rotate-proxy.sh`          | Берёт следующий прокси, генерит `redsocks.conf`, рестартит redsocks |
| `iptables-redsocks.sh`     | Поднимает/снимает правила редиректа TCP в redsocks                 |
| `redsocks-rotated.service` | systemd-юнит самого redsocks                                       |
| `rotate-proxy.service`     | one-shot юнит ротации (вызывает `rotate-proxy.sh`)                 |
| `rotate-proxy.timer`       | таймер: раз в 30 минут дёргает `rotate-proxy.service`              |

## Установка (Debian/Ubuntu, от root)

```bash
# 1. redsocks
apt-get update && apt-get install -y redsocks iptables

# redsocks-пакет ставит свой systemd-сервис и автозапуск — выключаем,
# мы управляем им своим юнитом:
systemctl disable --now redsocks 2>/dev/null || true

# 2. Отдельный системный пользователь (его трафик исключается из редиректа)
id redsocks >/dev/null 2>&1 || useradd -r -s /usr/sbin/nologin redsocks

# 3. Конфиг и скрипты
mkdir -p /etc/redsocks-rotator
cp proxies.txt            /etc/redsocks-rotator/
cp rotate-proxy.sh        /usr/local/bin/rotate-proxy.sh
cp iptables-redsocks.sh   /usr/local/bin/iptables-redsocks.sh
chmod +x /usr/local/bin/rotate-proxy.sh /usr/local/bin/iptables-redsocks.sh
chown -R redsocks:redsocks /etc/redsocks-rotator
chmod 600 /etc/redsocks-rotator/proxies.txt   # внутри логины/пароли

# 4. systemd-юниты
cp redsocks-rotated.service rotate-proxy.service rotate-proxy.timer /etc/systemd/system/
systemctl daemon-reload

# 5. Бутстрап: сгенерировать первый redsocks.conf и запустить redsocks
/usr/local/bin/rotate-proxy.sh
systemctl enable --now redsocks-rotated.service

# 6. Включить редирект трафика и таймер ротации
/usr/local/bin/iptables-redsocks.sh start
systemctl enable --now rotate-proxy.timer
```

> Путь к бинарю redsocks в `redsocks-rotated.service` — `/usr/sbin/redsocks`.
> Проверь `command -v redsocks` и поправь `ExecStart`, если отличается.

## Проверка

```bash
# Активный прокси сейчас (последняя строка ip = ...):
grep -E 'ip|port' /etc/redsocks-rotator/redsocks.conf

# Внешний IP — должен быть IP прокси, а не сервера:
curl -s https://api.ipify.org; echo

# Когда следующая ротация:
systemctl list-timers rotate-proxy.timer

# Лог переключений:
journalctl -t rotate-proxy --since '1 hour ago'
```

## Управление

```bash
# Сменить прокси прямо сейчас, не дожидаясь таймера:
systemctl start rotate-proxy.service

# Поменять список прокси на лету:
nano /etc/redsocks-rotator/proxies.txt    # round-robin подхватит при следующей ротации

# Снять редирект (трафик пойдёт напрямую):
/usr/local/bin/iptables-redsocks.sh stop

# Полностью остановить:
systemctl disable --now rotate-proxy.timer redsocks-rotated.service
/usr/local/bin/iptables-redsocks.sh stop
```

## Настройки

- **Интервал**: `OnUnitActiveSec` в `rotate-proxy.timer` (сейчас `30min`).
  После правки — `systemctl daemon-reload && systemctl restart rotate-proxy.timer`.
- **Случайный порядок** вместо round-robin: раскомментируй
  `Environment=ROTATE_MODE=random` в `rotate-proxy.service`.
- **Порт redsocks**: `LOCAL_PORT` в `rotate-proxy.sh` и `REDSOCKS_PORT` в
  `iptables-redsocks.sh` — должны совпадать.
- **Режим «шлюз для других машин»**: в `iptables-redsocks.sh` раскомментируй блок
  `PREROUTING`, укажи `LAN_IFACE`, включи `net.ipv4.ip_forward=1`.

## Важные оговорки

- **DNS не проксируется.** redsocks заворачивает только TCP; DNS-запросы (UDP)
  идут напрямую с сервера. Это и утечка реального IP через DNS, и возможное
  расхождение геолокации. Если нужен DNS через прокси — резолвить через
  TCP/прокси-aware резолвер или поднять локальный DNS поверх SOCKS5.
- **iptables-правила не переживают перезагрузку.** `iptables-redsocks.sh start`
  выполняется заново при каждом ребуте либо через `netfilter-persistent`/
  отдельный systemd-юнит. (При желании оформлю как сервис.)
- **Рестарт redsocks рвёт активные соединения** на момент смены прокси — для
  ротации раз в 30 минут это обычно некритично.
- **Только IPv4.** Если на сервере есть IPv6-маршрут, трафик может уйти мимо
  прокси напрямую по IPv6 — при необходимости заблокируй исходящий IPv6 или
  добавь правила `ip6tables`.
