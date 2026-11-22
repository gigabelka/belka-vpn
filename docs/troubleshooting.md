# Troubleshooting belka-vpn

## Сначала проверьте IP

Скрипты не содержат адресов. Если при запуске ошибка
`RU_PUBLIC_IP is required` / `FOREIGN_PUBLIC_IP is required`:

```bash
bash scripts/configure.sh --role foreign   # или --role ru
# либо отредактируйте /etc/belka-vpn/<role>.env
```

Файлы должны иметь режим `600`, а IP — быть реальными публичными адресами
серверов (не loopback и не RFC1918).

## AmneziaWG не поднимается

Симптомы: `awg-quick@awg0` failed, handshake отсутствует.

Проверьте:

```bash
systemctl status awg-quick@awg0 --no-pager
journalctl -u awg-quick@awg0 -n 100 --no-pager
awg --version
dkms status
lsmod | grep amneziawg
```

Частые причины:

- **Модуль не собрался**: нет `linux-headers-$(uname -r)`, Secure Boot требует
  подписи, ядро обновилось без перезагрузки. Перезагрузите сервер, проверьте
  `dkms status`.
- **Разные версии/параметры**: `S1-S4`, `H1-H4` обязаны совпадать. Сверьте
  `/etc/amnezia/amneziawg/awg0.conf` на обоих концах.
- **Порт закрыт**: на зарубежном сервере `ufw status`; у провайдера — security
  group/firewall. Проверка: `tcpdump -ni any udp port 443` на обоих.
- **MTU**: начните с `1280`; при фрагментации снижайте до `1240`.
- **Jmax > MTU**: параметр не должен превышать MTU.
- **Несовпадение `S3/S4`/`HeaderProtectionKey`**: если включили, они должны
  быть одинаковы; при сомнениях оставьте `AWG_ENABLE_S3S4=0`.

## SOCKS недоступен с РФ

```bash
# на зарубежном сервере
ss -lntp | grep 1080          # должен быть только 172.16.0.1:1080
ufw status verbose
journalctl -u xray -n 100 --no-pager

# на РФ
curl -v --socks5-hostname 172.16.0.1:1080 https://api.ipify.org
```

Проверьте:

- `awg0` активен и handshake свежий;
- UFW на зарубежном сервере разрешает 1080 с `172.16.0.2` на `awg0` (TCP и UDP);
- Xray слушает `172.16.0.1`, а не `0.0.0.0`;
- в `awg0.conf` на РФ `AllowedIPs = 172.16.0.1/32`, маршрут до `172.16.0.1`
  идёт через `awg0` (`ip route get 172.16.0.1`).

## YouTube/Google идут через Россию или медленно

Признак: `ipinfo.io` в клиенте показывает российский IP для домена, который
должен идти через зарубежный сервер; или видео грузится с российского GGC.

Проверьте:

1. **Common Proxy Core = Xray** (Settings → Advanced). Без этого `geosite`/
   `geoip` не работают, а SNI не переподставляется.
2. В outbound `FOREIGN-Domains` **нет** `geoip:google`.
3. Два outbound: `FOREIGN-Domains` (домены) выше `FOREIGN-Telegram-IP`
   (`geoip:telegram`), `Direct` — последний.
4. Sniffing включён, `routeOnly=false` в сгенерированном конфиге.
5. Клиент: Resolve Destination OFF, DNS remote, IPv6 off.
6. Hiddify блокирует QUIC/443 — это нормально, YouTube пойдёт по TCP.

Проверка с РФ:

```bash
curl -s --socks5-hostname 172.16.0.1:1080 https://api.ipify.org   # FOREIGN IP
curl -s -o /dev/null -w '%{http_code}\n' --socks5-hostname 172.16.0.1:1080 \
  https://www.youtube.com/generate_204                            # 204
```

## Anthropic/Claude отдаёт 403

403 с текстом про регион означает, что выход всё ещё российский.

- проверьте, что `api.anthropic.com` попадает в `FOREIGN-Domains`;
- `geosite:anthropic` должен присутствовать; если тег неизвестен — оставьте
  явные домены из `/root/belka-foreign-domains.txt`;
- проверьте `curl` с РФ через SOCKS (см. выше);
- Claude Code на десктопе должен работать в TUN-режиме: SOCKS он не
  поддерживает. В WSL2/Docker TUN может не перехватываться.

## Hiddify Manager не стартует / Xray падает

```bash
journalctl -u hiddify-xray -n 200 --no-pager
journalctl -u hiddify-core -n 100 --no-pager
jq . /opt/hiddify-manager/generated/xray.json >/dev/null && echo json-ok
xray run -test -c /opt/hiddify-manager/generated/xray.json
```

Частые причины:

- **Неизвестный geosite-тег** (`geosite:anthropic`, `category-ai-!cn` могут
  отсутствовать в вашей версии). Уберите тег, оставьте домены.
- **Порядок outbounds**: WARP/Block выше Socks перехватывают трафик. WARP
  выключить, Block — без списков.
- **`hiddify-core` перезапускается каждые 5 секунд** (`status=1`, journal
  пуст): смотрите `/opt/hiddify-manager/data/log/hiddify-core.err.log`. Если
  там `implicit default HTTP client ... deprecated`, новое ядро sing-box
  требует `ENABLE_DEPRECATED_IMPLICIT_DEFAULT_HTTP_CLIENT=true`.
  `install-ru.sh` ставит drop-in
  `/etc/systemd/system/hiddify-core.service.d/belka-compat.conf`; вручную:
  `systemctl daemon-reload && systemctl restart hiddify-core`.
- **Правка сгенерированных файлов**: Hiddify перезаписывает их при Apply.
  Меняйте только через UI.
- **Порты 80/443 заняты**: Hiddify нужны оба; освободите или не устанавливайте
  Hiddify (`INSTALL_HIDDIFY=0`).

## Сломался SSH после hardening

`HARDEN_SSH=1` включает запрет пароля. Если ключ не был добавлен:

1. Откройте консоль провайдера.
2. Удалите `/etc/ssh/sshd_config.d/99-belka-hardening.conf`.
3. `systemctl reload ssh`.

Поэтому hardening по умолчанию выключен.

## Клиент импортирует подписку с ошибкой сертификата

Домена нет, панель на IP с self-signed. Используйте прямую `vless://`-ссылку
из панели вместо HTTPS-подписки. Для подписки заведите домен/DDNS и
перевыпустите сертификат в Hiddify.

## DNS-утечки / IPv6

- в Hiddify app: IPv6 **Disabled**, DNS remote `1.1.1.1` через прокси;
- в Hiddify Manager: **Only IPv4 = ON**;
- проверьте `https://test-ipv6.com` и `https://dnsleaktest.com`.

## Telegram: сообщения работают, звонки нет

Hiddify блокирует QUIC/443; звонки Telegram используют UDP на других портах.
SOCKS на зарубежном сервере включает UDP, но хвост может резаться DPI/хостером.
Проверьте `geoip:telegram` в отдельном outbound; при проблемах оставьте
TCP-режим.

## Повторный запуск скриптов что-то сломал

Скрипты идемпотентны, но проверьте:

```bash
git -C /opt/belka-vpn status --short
bash -n scripts/*.sh
bash scripts/verify.sh
```

Если конфиг изменился неожиданно, сравните `/etc/amnezia/amneziawg/awg0.conf`
с шаблоном и handoff. Ключи и обфускация лежат в
`/etc/amnezia/amneziawg/keys` и `/etc/belka-vpn/foreign-obfuscation.env`; при
`ROTATE_*` они перегенерируются — не забудьте передать handoff другой стороне.

## Где логи

- `/var/log/belka-vpn-foreign.log`, `/var/log/belka-vpn-ru.log`,
  `/var/log/belka-vpn-verify.log`;
- `/var/log/belka-vpn-bootstrap.log`;
- `journalctl -u awg-quick@awg0`, `-u xray`, `-u hiddify-*`;
- `/opt/hiddify-manager/data/log/hiddify-core.{out,err}.log` — stdout/stderr
  `hiddify-core` (unit пишет их в файлы, а не в journal).

В логах нет приватных ключей и admin-ссылки Hiddify. Installer output с
admin-ссылкой — `/root/belka-hiddify-install.out` (0600).
