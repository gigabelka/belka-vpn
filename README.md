# belka-vpn

Двухсерверный VPN с разделением трафика:

- клиенты (Hiddify app) подключаются **только к российскому серверу** по VLESS + Reality;
- российский сервер отправляет YouTube, Telegram, сервисы Google, Claude/Anthropic, прочий AI, а также заблокированные в РФ рутрекер/рутор и Instagram через **зарубежный сервер**;
- весь остальной трафик выходит напрямую из России;
- между серверами — **AmneziaWG** (UDP), на зарубежной стороне — SOCKS5 только на адресе тоннеля.

```text
Hiddify app ──VLESS+Reality/443──► RU <RU_PUBLIC_IP> (Hiddify Manager)
                                     ├─ 1. FOREIGN-Domains: домены + geosite (youtube/google/telegram/anthropic/openai, rutracker/rutor/instagram)
                                     │        └─ Socks ──► 172.16.0.1:1080 (FOREIGN Xray)
                                     ├─ 2. FOREIGN-Google-IP: geoip:google (Google без домена)
                                     │        └─ Socks ──► 172.16.0.1:1080
                                     ├─ 3. FOREIGN-Telegram-IP: geoip:telegram
                                     │        └─ Socks ──► 172.16.0.1:1080  [внутри AmneziaWG/UDP]
                                     └─ 4. всё остальное ──► Direct (RU)

RU 172.16.0.2 ══════ AmneziaWG ══════ 172.16.0.1 FOREIGN <FOREIGN_PUBLIC_IP> ──► интернет
```

Почему SOCKS, а не NAT на зарубежном сервере: домены выбранных сервисов резолвятся уже там. YouTube/Google не получают российские GGC-адреса, а Anthropic не видит российский IP. `ip_forward` и NAT не нужны ни на одном сервере, на RU пересылка выключена явно.

> **В репозитории нет адресов серверов.** Российский и зарубежный IP пользователь задаёт через `scripts/configure.sh` или `/etc/belka-vpn/*.env`. Скрипты не имеют дефолтных публичных адресов и падают с понятной ошибкой, если IP не задан. Единственный файл с публичными диапазонами — `config/client/hiddify-allowedips.txt`: это список маршрутизации клиента, а не идентификатор сервера (см. «Адреса в обход VPN»).

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
  client/            # Direct-список и инверсный AllowedIPs для клиента Hiddify app
docs/
  architecture.md    # подробная схема и обоснование
  hiddify-client.md  # клиент Hiddify app: настройка, Direct-правило, AllowedIPs
  runbook.md         # пошаговое развёртывание
  troubleshooting.md # типовые проблемы
tests/lint.sh        # bash -n, shellcheck, запрет реальных IP и устаревших имён
.env.example         # справочник всех переменных; скрипты его не читают (см. комментарий в файле)
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

### 1. Доставка репозитория (на оба сервера)

Если GitHub с сервера доступен:

```bash
git clone https://github.com/gigabelka/belka-vpn.git /opt/belka-vpn
```

Если GitHub с сервера недоступен (актуально для РФ), соберите архив из коммита с LF и
передайте его из Git Bash (не из PowerShell 5.1: он портит двоичный поток в пайпе):

```bash
# с рабочей станции, Git Bash
git -c core.autocrlf=false -c core.eol=lf archive --format=tar -o deploy.tar \
  HEAD scripts config docs tests .env.example README.md
ssh -i <key> root@<RU_IP> 'mkdir -p /opt/belka-vpn && tar -x -C /opt/belka-vpn' < deploy.tar
ssh -i <key> root@<FOREIGN_IP> 'mkdir -p /opt/belka-vpn && tar -x -C /opt/belka-vpn' < deploy.tar
```

Проверка CR перед отправкой — `docs/runbook.md`, раздел «Доставка кода на серверы с Windows».

`bootstrap.sh` (см. «Обновление») требует уже готовый env-файл из шага 2 и сразу запускает установщик, поэтому он заменяет шаги 1 и 3 только после того, как env создан.

### 2. IP серверов: конфигуратор

`configure.sh` не содержит адресов — он спрашивает их у пользователя.

Вариант А — на каждом сервере:

```bash
bash scripts/configure.sh --role foreign   # пишет /etc/belka-vpn/foreign.env
bash scripts/configure.sh --role ru        # пишет /etc/belka-vpn/ru.env
```

Вариант Б — локально, затем скопировать оба файла. Подойдёт и `./env` внутри репозитория: он в `.gitignore`, и `tests/lint.sh` игнорируемые файлы не сканирует.

```bash
bash scripts/configure.sh --role both --output-dir ~/belka-env
scp ~/belka-env/ru.env root@<RU_IP>:/etc/belka-vpn/ru.env
scp ~/belka-env/foreign.env root@<FOREIGN_IP>:/etc/belka-vpn/foreign.env
```

Неинтерактивный режим (все значения и флаги берутся из окружения, кроме `ENABLE_UFW` для RU — он всегда `0`):

```bash
RU_PUBLIC_IP=<RU_IP> FOREIGN_PUBLIC_IP=<FOREIGN_IP> \
  bash scripts/configure.sh --non-interactive --role both --output-dir ~/belka-env
```

Файлы создаются с правами `600`. Вместо конфигуратора можно скопировать примеры:

```bash
install -d -m 700 /etc/belka-vpn
install -m 600 scripts/env/foreign.env.example /etc/belka-vpn/foreign.env   # на FOREIGN
install -m 600 scripts/env/ru.env.example /etc/belka-vpn/ru.env             # на RU
# затем вручную заполнить FOREIGN_PUBLIC_IP и RU_PUBLIC_IP
```

### 3. Зарубежный сервер — первый проход

```bash
bash scripts/install-foreign.sh --env-file /etc/belka-vpn/foreign.env
```

Скрипт создаёт `/root/belka-foreign-handoff.env` (публичные данные). RU-peer пока не добавлен — handshake появится на шаге 6, когда RU поднимет `awg0`.

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

Проверьте, что peer добавлен (handshake ещё нет: `--keys-only` не поднимает `awg0` на RU):

```bash
awg show   # peer с RU_PUBLIC_KEY присутствует
```

### 6. Россия — установка и тоннель

Скопируйте `/root/belka-foreign-handoff.env` с зарубежного сервера на РФ и выполните:

```bash
bash scripts/install-ru.sh --handoff /root/belka-foreign-handoff.env
```

Скрипт установит Hiddify Manager (5–10 минут), поднимет `awg0` и напечатает чек-лист `/root/belka-ru-manual-checklist.txt`. Теперь `awg show` на обеих сторонах должен показать свежий handshake.

### 7. Панель Hiddify Manager

```bash
hiddify admin   # ссылка — секрет, не копируйте в чат/репозиторий
```

Ключевые шаги (полный чек-лист — `/root/belka-ru-manual-checklist.txt`):

1. **Country = Russia**, протоколы — только **VLESS** (TLS/Reality на 443), домен не обязателен (IP + self-signed). Лишние протоколы (Hysteria2, TUIC, SSH, WireGuard и др.) и **Allow HTTP Connection** выключите: каждый открывает свой порт или конфиги без TLS. Подробнее — `docs/troubleshooting.md`.
2. **Settings → Advanced → Common Proxy Core = Xray** — без этого `geosite`/`geoip` не работают, а домен из SNI не переподставляется.
3. **Only IPv4 = ON**, DNS = `1.1.1.1`, firewall Hiddify пока OFF (включать в панели после успешного `verify.sh`; ручных ufw/iptables не добавлять).
4. Reality на `443/tcp`, SNI — чужой сайт с TLS 1.3 + HTTP/2 (подобрать сканером).
5. Три outbound типа **Socks** на `172.16.0.1:1080`:
   - `FOREIGN-Domains` — только домены (`/root/belka-foreign-domains.txt`) и `geosite` (`/root/belka-foreign-geosites.txt`), **без** `geoip:google`;
   - `FOREIGN-Google-IP` — только `geoip:google` (`/root/belka-foreign-google-ip.txt`);
   - `FOREIGN-Telegram-IP` — только `geoip:telegram` (`/root/belka-foreign-telegram-ip.txt`).
6. Порядок: `FOREIGN-Domains` → `FOREIGN-Google-IP` → `FOREIGN-Telegram-IP` → `Direct` (последний, default). WARP выключить. Встроенный `Block` остаётся выше Socks, но без списков и с выключенным «Domestic sites» — тогда он ничего не перехватывает.
7. **Apply now**, затем проверить сгенерированный Xray-конфиг: sniffing включён, `routeOnly=false`, три Socks-outbound, Direct последний.
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

Подробная пошаговая инструкция (импорт, Direct-правило, `AllowedIPs`, «Строгая
маршрутизация», проверка) — `docs/hiddify-client.md`.

#### Адреса в обход VPN

Клиент по умолчанию отправляет всё в **Proxy**, а 12 диапазонов, перечисленных в шапке `config/client/hiddify-allowedips.txt`, уходят **Direct** — это и есть адреса, которые клиент игнорирует:

1. **Настройки → Маршрутизация → добавить правило**, тип **IP CIDR**, outbound **Direct**, вставить эти 12 диапазонов. Образец формата — `config/client/hiddify-bypass.txt.example`; личные дополнения держите в `config/client/hiddify-bypass.local.txt` (он в `.gitignore` через `*.local.txt`). Сохранить правило и переподключиться.
2. `config/client/hiddify-allowedips.txt` — обратная запись: 199 CIDR «весь интернет, кроме этих 12 исключений». Нужен клиентам и профилям, которые буквально понимают `AllowedIPs`; в Hiddify app то же самое делает Direct-правило из п. 1, поэтому вставлять 199 строк в приложение не требуется.
3. Проверка: `tracert -d <IP из Direct-списка>` — первый хоп через локальный шлюз, в логах Hiddify соединение идёт через `direct`.

`C:\Program Files\Hiddify\Hiddify.exe` — лаунчер, а не конфиг. Состояние клиента лежит в `%APPDATA%\Hiddify\hiddify\route_rule.proto` (бинарный protobuf) и `configs\*.json` (там приватные ключи): вручную не правьте и в репозиторий не кладите.

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
- rutracker.org, rutor.info и instagram.com открываются через зарубежный сервер (медиа Instagram грузится);
- `gemini.google.com` не показывает «недоступно в вашей стране»;
- `api.anthropic.com` → 400/401/404/405, **не** 403;
- в клиенте `ipinfo.io` → российский IP, а YouTube/Google/Claude идут через зарубежный сервер.

## Обновление

```bash
# только если /opt/belka-vpn — git-клон (шаг 1, git clone)
bash /root/bootstrap.sh foreign --ref main --env-file /etc/belka-vpn/foreign.env
```

Если `/opt/belka-vpn` доставлен архивом (в нём нет `.git`), `bootstrap.sh` откажется
работать (`exists but is not a git repository`): заново передайте архив и запустите
скрипт установки.

Копируете с Windows — собирайте архив так, чтобы в нём были переводы строк LF: при
`core.autocrlf=true` и tar рабочей копии, и обычный `git archive` дают CRLF, и bash на
сервере падает с `$'\r': command not found`. Порядок действий — `docs/runbook.md`, раздел
«Обновление и ротация».

Скрипты идемпотентны: повторный запуск не дублирует правила, не перегенерирует ключи и не перезапускает сервисы без изменений. Ротация — `ROTATE_KEYS=1` / `ROTATE_OBFUSCATION=1` (с последующей передачей handoff на другую сторону, см. `docs/runbook.md`).

Дополнительные аргументы `bootstrap.sh` передаются установщику; явный разделитель — `--`, например `bootstrap.sh ru -- --handoff /root/belka-foreign-handoff.env --dry-run`. Сам `bootstrap.sh` забирает `--ref`, `--env-file`, `-h`.

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
- `HARDEN_SSH=1` запрещает вход по паролю и X11-проброс (root — только по ключу). Включайте только после проверки ключа во второй сессии.
- На RU пересылка пакетов (`ip_forward`) и приём ICMP-редиректов выключены: схеме они не нужны, а Hiddify включает пересылку при каждой загрузке. Для WireGuard/WARP в Hiddify — `RU_IP_FORWARD=1` (`docs/troubleshooting.md`).
- Hiddify на RU переустанавливается при каждой загрузке и обновляется ночью; после этого прогоняйте `verify.sh`.
- Пароли и токены не передаются в чат, аргументы команд и git.

## Ограничения

- UI Hiddify Manager (Reality, Outbounds, sniffing/DNS) скриптами не автоматизируется: панель перезаписывает сгенерированные конфиги. Скрипт печатает точный чек-лист.
- Без домена подписка по HTTPS может отклоняться Hiddify app из-за self-signed — используйте прямую `vless://`-ссылку.
- Hiddify Manager блокирует QUIC/443 на серверной стороне: YouTube/Google пойдут по TCP (SNI-маршрутизация сохраняется). UDP Telegram на других портах может работать; звонки проверяйте отдельно.
- Hiddify Manager отправляет протокол BitTorrent в blackhole (правило в сгенерированном `xray.json`): сайты и анонсы трекеров (HTTP к `t-ru.org`) идут через FOREIGN, но P2P-обмен торрент-клиента через VPN не работает.
- Claude Code не поддерживает SOCKS: на компьютере нужен TUN-режим Hiddify; WSL2/Docker могут обходить TUN.

Диагностика — `docs/troubleshooting.md`.
