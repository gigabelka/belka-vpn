# belka-vpn

Двухсерверный VPN с разделением трафика:

- клиенты (Hiddify app) подключаются **только к российскому серверу** по VLESS + Reality;
- российский сервер отправляет YouTube, Telegram, сервисы Google, Claude/Anthropic и прочий AI через **зарубежный сервер**;
- весь остальной трафик выходит напрямую из России;
- между серверами — **AmneziaWG** (UDP), на зарубежной стороне — SOCKS5 только на адресе тоннеля.

```text
Hiddify app ──VLESS+Reality/443──► RU <RU_PUBLIC_IP> (Hiddify Manager)
                                     ├─ geosite:youtube/google/telegram/anthropic/openai
                                     │        └─ Socks ──► 172.16.0.1:1080 (FOREIGN Xray)
                                     │                        [внутри AmneziaWG/UDP]
                                     └─ всё остальное ──► Direct (RU)

RU 172.16.0.2 ══════ AmneziaWG ══════ 172.16.0.1 FOREIGN <FOREIGN_PUBLIC_IP> ──► интернет
```

Почему SOCKS, а не NAT на зарубежном сервере: домены выбранных сервисов резолвятся уже там. YouTube/Google не получают российские GGC-адреса, а Anthropic не видит российский IP. На зарубежном сервере не нужны `ip_forward` и NAT.

> **В репозитории нет IP-адресов.** Пользователь указывает российский и зарубежный IP через `scripts/configure.sh` или `/etc/belka-vpn/*.env`. Скрипты не имеют дефолтных публичных адресов и падают с понятной ошибкой, если IP не задан.

## Что в репозитории

```text
scripts/
  configure.sh       # интерактивно спрашивает IP/порты/SNI и пишет ru.env + foreign.env
  bootstrap.sh       # доставка/обновление репозитория на сервере + запуск этапа
  lib.sh             # общие функции
  install-foreign.sh # зарубежный сервер: AmneziaWG + Xray SOCKS + firewall
  install-ru.sh      # Россия: AmneziaWG + установка Hiddify Manager
  verify.sh          # проверки тоннеля, SOCKS и маршрутизации
  env/               # примеры /etc/belka-vpn/foreign.env и ru.env (IP пустые)
config/
  foreign/           # шаблоны awg0.conf и xray config
  ru/                # шаблон awg0.conf + чек-лист панели
  rules/             # готовые списки доменов/geosite/geoip для Hiddify
docs/
  architecture.md    # подробная схема и обоснование
  runbook.md         # пошаговое развёртывание
  troubleshooting.md # типовые проблемы
tests/lint.sh        # bash -n, shellcheck, запрет реальных IP и устаревших имён
.env.example         # локальные параметры; IP пустые, .env — gitignored
```

## Требования

- Два сервера Ubuntu 22.04/24.04, root SSH:
  - российский — вход для клиентов, публичный IP;
  - зарубежный — выход в интернет, публичный IP.
- Порты RU: 80/443/tcp (Hiddify Manager + Reality), SSH.
- Порты зарубежного: SSH, выбранный UDP-порт AmneziaWG (по умолчанию 443).
- Домен не обязателен: Hiddify Manager поднимется на IP с self-signed, Reality использует чужой SNI.
- IP-адреса задаёт пользователь; в репозитории их нет.

## Быстрый старт

Все команды ниже выполняются от root на соответствующем сервере, из каталога репозитория `/opt/belka-vpn`.

### 0. SSH-ключ (один раз, в своём терминале)

Мой терминал неинтерактивный, поэтому пароль вводится только в вашем терминале:

```powershell
ssh-keygen -t ed25519 -a 100 -f "$env:USERPROFILE\.ssh\belka_vpn_ed25519" -N '""' -C belka-vpn

Get-Content "$env:USERPROFILE\.ssh\belka_vpn_ed25519.pub" |
  ssh root@<RU_IP> "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"

Get-Content "$env:USERPROFILE\.ssh\belka_vpn_ed25519.pub" |
  ssh root@<FOREIGN_IP> "umask 077; mkdir -p ~/.ssh; cat >> ~/.ssh/authorized_keys"
```

Проверка:

```powershell
ssh -i "$env:USERPROFILE\.ssh\belka_vpn_ed25519" -o BatchMode=yes root@<RU_IP> hostname
ssh -i "$env:USERPROFILE\.ssh\belka_vpn_ed25519" -o BatchMode=yes root@<FOREIGN_IP> hostname
```

### 1. Доставка репозитория

Если репозиторий уже отправлен в GitHub:

```bash
curl -fsSL https://raw.githubusercontent.com/gigabelka/belka-vpn/main/scripts/bootstrap.sh -o /root/bootstrap.sh
bash /root/bootstrap.sh foreign --env-file /etc/belka-vpn/foreign.env
```

Если GitHub с сервера недоступен (актуально для РФ):

```powershell
# с рабочей станции
tar czf - scripts config docs tests .env.example | ssh -i <key> root@<RU_IP> "mkdir -p /opt/belka-vpn && tar xzf - -C /opt/belka-vpn"
```

### 2. IP серверов: конфигуратор

`configure.sh` не содержит адресов — он спрашивает их у пользователя.

Вариант А — на каждом сервере:

```bash
bash scripts/configure.sh --role foreign   # пишет /etc/belka-vpn/foreign.env
bash scripts/configure.sh --role ru        # пишет /etc/belka-vpn/ru.env
```

Вариант Б — локально, затем скопировать оба файла:

```bash
bash scripts/configure.sh --role both --output-dir ./env
scp ./env/ru.env root@<RU_IP>:/etc/belka-vpn/ru.env
scp ./env/foreign.env root@<FOREIGN_IP>:/etc/belka-vpn/foreign.env
```

Неинтерактивный режим (значения из env):

```bash
RU_PUBLIC_IP=<RU_IP> FOREIGN_PUBLIC_IP=<FOREIGN_IP> \
  bash scripts/configure.sh --non-interactive --role both --output-dir ./env
```

Файлы создаются с правами `600`. Конфигуратор также можно использовать вместо копирования примеров:

```bash
install -d -m 700 /etc/belka-vpn
install -m 600 scripts/env/foreign.env.example /etc/belka-vpn/foreign.env
# затем вручную заполнить FOREIGN_PUBLIC_IP и RU_PUBLIC_IP
```

### 3. Зарубежный сервер — первый проход

```bash
bash scripts/install-foreign.sh --env-file /etc/belka-vpn/foreign.env
```

Скрипт создаёт `/root/belka-foreign-handoff.env` (публичные данные). RU-peer пока не добавлен — handshake появится на шаге 5.

### 4. Россия — ключи

```bash
bash scripts/install-ru.sh --keys-only --env-file /etc/belka-vpn/ru.env
```

Скрипт печатает `RU_PUBLIC_KEY` и создаёт `/root/belka-ru-handoff.env`.

### 5. Добавить RU-peer на зарубежном сервере

Скопируйте `/root/belka-ru-handoff.env` с РФ на зарубежный сервер и выполните:

```bash
bash scripts/install-foreign.sh --handoff /root/belka-ru-handoff.env
```

Проверьте handshake:

```bash
awg show
```

### 6. Россия — установка и тоннель

Скопируйте `/root/belka-foreign-handoff.env` с зарубежного сервера на РФ и выполните:

```bash
bash scripts/install-ru.sh --handoff /root/belka-foreign-handoff.env
```

Скрипт установит Hiddify Manager (5–10 минут), поднимет `awg0` и напечатает чек-лист `/root/belka-ru-manual-checklist.txt`.

### 7. Панель Hiddify Manager

```bash
hiddify admin   # ссылка — секрет, не копируйте в чат/репозиторий
```

Ключевые шаги (полный чек-лист — `/root/belka-ru-manual-checklist.txt`):

1. **Country = Russia**, протоколы — только **VLESS**, домен не обязателен (IP + self-signed).
2. **Settings → Advanced → Common Proxy Core = Xray** — без этого `geosite`/`geoip` не работают, а домен из SNI не переподставляется.
3. **Only IPv4 = ON**, DNS = `1.1.1.1`, firewall пока OFF.
4. Reality на `443/tcp`, SNI — чужой сайт с TLS 1.3 + HTTP/2 (подобрать сканером).
5. Два outbound типа **Socks** на `172.16.0.1:1080`:
   - `FOREIGN-Domains` — только домены (`/root/belka-foreign-domains.txt`) и `geosite` (`/root/belka-foreign-geosites.txt`), **без** `geoip:google`;
   - `FOREIGN-Telegram-IP` — только `geoip:telegram` (`/root/belka-foreign-telegram-ip.txt`).
6. Порядок: `FOREIGN-Domains` → `FOREIGN-Telegram-IP` → `Direct` (последний, default). WARP выключить.
7. **Apply now**, затем проверить сгенерированный Xray-конфиг: sniffing включён, `routeOnly=false`, два Socks-outbound, Direct последний.
8. **Users → Add user** — получить `vless://` или подписку.

### 8. Клиент Hiddify app

- импорт `vless://` (или подписки);
- default outbound — **Proxy**;
- **Bypass LAN — ON**;
- Region — **Other** (разделение делает сервер);
- IPv6 — **Disabled**;
- DNS — remote `1.1.1.1` через прокси;
- Resolve Destination — **OFF**;
- на десктопе — **TUN/VPN mode** (Claude Code не поддерживает SOCKS).

Присланный список AllowedIPs эквивалентен «полный тоннель минус LAN»: `Bypass LAN` покрывает `10/8`, `172.16/12`, `192.168/16`. Если нужен буквальный список — добавьте Direct-правила IP-CIDR для непокрытых подсетей; 149 CIDR вручную вносить не нужно.

### 9. Проверка

```bash
# на РФ
bash scripts/verify.sh

# на зарубежном сервере
bash scripts/verify.sh --role foreign
```

Ожидается:

- handshake AmneziaWG свежий;
- `curl --socks5-hostname 172.16.0.1:1080 https://api.ipify.org` → зарубежный IP;
- YouTube через зарубежный сервер → 204;
- `gemini.google.com` не показывает «недоступно в вашей стране»;
- `api.anthropic.com` → 400/401/404/405, **не** 403;
- в клиенте `ipinfo.io` → российский IP, а YouTube/Google/Claude идут через зарубежный сервер.

## Обновление

```bash
# если репозиторий доступен с сервера
bash /root/bootstrap.sh foreign --ref main --env-file /etc/belka-vpn/foreign.env
# или повторно скопируйте tar/scp и запустите скрипт установки
```

Скрипты идемпотентны: повторный запуск не дублирует правила, не перегенерирует ключи и не перезапускает сервисы без изменений. Ротация — `ROTATE_KEYS=1` / `ROTATE_OBFUSCATION=1` (с последующей передачей handoff на другую сторону).

## Откат

```bash
bash scripts/install-foreign.sh --uninstall
bash scripts/install-ru.sh --uninstall
```

Hiddify Manager удаляется отдельно (официальный uninstall-скрипт), чтобы не задеть SSH и данные. Подробнее — в `docs/runbook.md`.

## Безопасность

- Приватные ключи AWG генерируются на серверах и не покидают их; handoff содержит только публичные ключи и параметры.
- В публичный репозиторий не попадают `.env`, ключи, handoff-файлы и admin-ссылка Hiddify.
- `ufw` включается только на зарубежном сервере. На РФ firewall управляет Hiddify Manager.
- `HARDEN_SSH=1` включает запрет парольного входа — только после проверки ключа во второй сессии.
- Пароли и токены не передаются в чат, аргументы команд и git.

## Ограничения

- UI Hiddify Manager (Reality, Outbounds, sniffing/DNS) скриптами не автоматизируется: панель перезаписывает сгенерированные конфиги. Скрипт печатает точный чек-лист.
- Без домена подписка по HTTPS может отклоняться Hiddify app из-за self-signed — используйте прямую `vless://`-ссылку.
- Hiddify Manager блокирует QUIC/443 на серверной стороне: YouTube/Google пойдут по TCP (SNI-маршрутизация сохраняется). UDP Telegram на других портах может работать; звонки проверяйте отдельно.
- Claude Code не поддерживает SOCKS: на компьютере нужен TUN-режим Hiddify; WSL2/Docker могут обходить TUN.

Диагностика — `docs/troubleshooting.md`.
