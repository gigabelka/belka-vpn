# Runbook: развёртывание belka-vpn

Все команды — от root, из `/opt/belka-vpn`, если не указано иное. Публичные IP
задаёт пользователь; в репозитории их нет.

## 0. Предварительно

- Вторая SSH-сессия открыта на каждом сервере.
- Доступ через консоль провайдера проверен.
- На зарубежном сервере у провайдера открыт UDP-порт AmneziaWG (по умолчанию 443).
- На RU порты 80/443/tcp свободны: их займёт Hiddify Manager.

## 1. Ключ и доставка

Сгенерируйте ключ и добавьте публичную часть на оба сервера (пароль вводится
только в вашем терминале):

```powershell
ssh-keygen -t ed25519 -a 100 -f "$env:USERPROFILE\.ssh\belka_vpn_ed25519" -N '""' -C belka-vpn
Get-Content "$env:USERPROFILE\.ssh\belka_vpn_ed25519.pub" | ssh root@<RU_IP> "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"
Get-Content "$env:USERPROFILE\.ssh\belka_vpn_ed25519.pub" | ssh root@<FOREIGN_IP> "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"
```

Доставка репозитория (если GitHub с сервера недоступен):

```powershell
tar czf - scripts config docs tests .env.example | ssh -i <key> root@<RU_IP> "mkdir -p /opt/belka-vpn && tar xzf - -C /opt/belka-vpn"
tar czf - scripts config docs tests .env.example | ssh -i <key> root@<FOREIGN_IP> "mkdir -p /opt/belka-vpn && tar xzf - -C /opt/belka-vpn"
```

Если GitHub доступен — используйте `bootstrap.sh` (см. README).

## 2. IP серверов: конфигуратор

`configure.sh` не содержит адресов — он спрашивает их у пользователя.

На каждом сервере:

```bash
bash scripts/configure.sh --role foreign   # /etc/belka-vpn/foreign.env
bash scripts/configure.sh --role ru        # /etc/belka-vpn/ru.env
```

Или локально, затем скопировать (каталог вывода — вне репозитория, иначе
`tests/lint.sh` упадёт на реальных IP):

```bash
bash scripts/configure.sh --role both --output-dir ~/belka-env
scp ~/belka-env/ru.env root@<RU_IP>:/etc/belka-vpn/ru.env
scp ~/belka-env/foreign.env root@<FOREIGN_IP>:/etc/belka-vpn/foreign.env
```

Неинтерактивный режим (значения и флаги из окружения; `ENABLE_UFW` для RU
всегда `0`):

```bash
RU_PUBLIC_IP=<RU_IP> FOREIGN_PUBLIC_IP=<FOREIGN_IP> \
  bash scripts/configure.sh --non-interactive --role both --output-dir ~/belka-env
```

Альтернатива — вручную из примеров:

```bash
install -d -m 700 /etc/belka-vpn
install -m 600 scripts/env/foreign.env.example /etc/belka-vpn/foreign.env
install -m 600 scripts/env/ru.env.example /etc/belka-vpn/ru.env
# заполните RU_PUBLIC_IP и FOREIGN_PUBLIC_IP
```

В env-файлах нет приватных ключей: только IP, порты, MTU и флаги.

## 3. Зарубежный сервер: первый проход

```bash
bash scripts/install-foreign.sh --env-file /etc/belka-vpn/foreign.env
```

Что делает:

1. ставит AmneziaWG (PPA), заголовки ядра, `awg-quick`;
2. генерирует ключи зарубежного сервера и параметры обфускации;
3. пишет `/etc/amnezia/amneziawg/awg0.conf` (пока без peer RU);
4. ставит Xray-core, SOCKS на `172.16.0.1:1080`, systemd drop-in после `awg0`;
5. настраивает UFW: SSH, UDP-порт только с российского IP, 1080 только на `awg0`;
6. пишет `/root/belka-foreign-handoff.env`.

Проверка:

```bash
awg show
ss -lntp | grep 1080           # только 172.16.0.1:1080
ufw status verbose
```

## 4. Россия: ключи

```bash
bash scripts/install-ru.sh --keys-only --env-file /etc/belka-vpn/ru.env
```

Скрипт устанавливает AmneziaWG, генерирует ключи RU, пишет
`/root/belka-ru-handoff.env` и печатает `RU_PUBLIC_KEY`.

## 5. Добавить RU-peer на зарубежном сервере

```powershell
scp -i <key> root@<RU_IP>:/root/belka-ru-handoff.env .
scp -i <key> belka-ru-handoff.env root@<FOREIGN_IP>:/root/belka-ru-handoff.env
```

На зарубежном сервере:

```bash
bash scripts/install-foreign.sh --handoff /root/belka-ru-handoff.env
awg show     # peer RU присутствует; handshake появится после шага 6
```

`--keys-only` на шаге 4 не поднимает `awg0` на RU, поэтому handshake здесь
ещё невозможен.

## 6. Россия: установка и тоннель

```powershell
scp -i <key> root@<FOREIGN_IP>:/root/belka-foreign-handoff.env .
scp -i <key> belka-foreign-handoff.env root@<RU_IP>:/root/belka-foreign-handoff.env
```

На РФ:

```bash
bash scripts/install-ru.sh --handoff /root/belka-foreign-handoff.env
```

Порядок внутри скрипта: Hiddify Manager → AmneziaWG (пакет, ключи) → RU
handoff → `awg0` → fail2ban → чек-лист. Hiddify ставится до поднятия тоннеля,
чтобы инсталлятор не трогал `awg0`.

Проверка:

```bash
awg show     # свежий handshake и растущий transfer
ping -c3 172.16.0.1
curl -s --socks5-hostname 172.16.0.1:1080 https://api.ipify.org
```

## 7. Панель Hiddify Manager

```bash
hiddify admin   # ссылка — секрет
```

Далее — `/root/belka-ru-manual-checklist.txt`. Критичные пункты:

1. Country = Russia; только VLESS; без домена — IP + self-signed.
2. **Common Proxy Core = Xray**.
3. Only IPv4 = ON; DNS `1.1.1.1`; firewall Hiddify пока OFF (включать в
   панели после успешного `verify.sh`; ручных ufw/iptables не добавлять).
4. Reality 443/tcp; SNI — чужой TLS1.3/HTTP2-сайт (Scanner).
5. Outbound `FOREIGN-Domains`: Socks `172.16.0.1:1080`, списки
   `/root/belka-foreign-domains.txt` + `/root/belka-foreign-geosites.txt`,
   **без** `geoip:google`, Domestic sites OFF.
6. Outbound `FOREIGN-Telegram-IP`: Socks `172.16.0.1:1080`, только
   `/root/belka-foreign-telegram-ip.txt`.
7. Порядок: FOREIGN-Domains → FOREIGN-Telegram-IP → Direct (default). WARP OFF.
8. Apply now.
9. Проверить сгенерированный конфиг:
   - sniffing `http/tls/quic`, `routeOnly=false`;
   - два Socks-outbound;
   - Direct последний;
   - `xray -test` проходит (нет неизвестных geosite-тегов).
10. Users → Add user → ссылка/подписка.

## 8. Клиент

- импорт `vless://`/подписки;
- default Proxy, Bypass LAN ON, IPv6 Off, Region Other;
- DNS remote `1.1.1.1`, Resolve Destination OFF;
- desktop — TUN/VPN mode (Claude Code не умеет SOCKS).

## 9. Проверка

```bash
# RU
bash scripts/verify.sh

# зарубежный сервер
bash scripts/verify.sh --role foreign
```

Клиентские проверки:

1. `https://ipinfo.io` → российский IP.
2. Временно добавить `ipinfo.io` в `Sites` outbound FOREIGN-Domains → зарубежный IP; убрать.
3. YouTube/Google/Claude/Telegram/Gemini работают; российские сайты идут Direct.
4. `api.anthropic.com` — не 403.
5. DNS/IPv6 leak-тесты.
6. Claude Code в TUN-режиме.

## 10. Обновление и ротация

Повторный запуск скриптов идемпотентен. Ключи и обфускация переиспользуются.

Ротация:

```bash
# 1. зарубежный сервер
ROTATE_KEYS=1 ROTATE_OBFUSCATION=1 bash scripts/install-foreign.sh --env-file /etc/belka-vpn/foreign.env
# 2. передать новый /root/belka-foreign-handoff.env на RU, затем на RU:
ROTATE_KEYS=1 bash scripts/install-ru.sh --handoff /root/belka-foreign-handoff.env
# 3. передать новый /root/belka-ru-handoff.env на зарубежный сервер, затем там:
bash scripts/install-foreign.sh --handoff /root/belka-ru-handoff.env
```

Шаг 3 обязателен при ротации ключей RU: иначе зарубежный сервер держит старый
`RU_PUBLIC_KEY` и handshake перестаёт проходить. То же после ротации
обфускации — handoff нужно обновить на обеих сторонах.

## 11. Откат

```bash
bash scripts/install-foreign.sh --uninstall
bash scripts/install-ru.sh --uninstall
```

Hiddify Manager удаляется отдельно:

```bash
ls /opt/hiddify-manager/uninstall.sh
# прочитайте и выполните осознанно; это удалит панель и её данные
```

Если потерян SSH на RU, используйте консоль провайдера. Firewall на RU
принадлежит Hiddify Manager — правьте его через панель (Settings → Advanced →
Firewall, затем Apply now), а не ручными `iptables`/`ufw`: панель перезапишет
ручные правила. Если доступа к панели нет:

```bash
systemctl restart ssh
fail2ban-client unban --all     # если вас забанил fail2ban
```
