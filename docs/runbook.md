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

Доставка репозитория, если GitHub с сервера недоступен: архив из коммита с LF,
передаётся из Git Bash — команды в разделе «Доставка кода на серверы с Windows» (§10).
Для первой доставки добавьте `mkdir -p /opt/belka-vpn` перед `tar -x`.

Если GitHub доступен — `git clone` в `/opt/belka-vpn`, обновления через `bootstrap.sh`
(см. README). `bootstrap.sh` работает только с git-клоном.

## 2. IP серверов: конфигуратор

`configure.sh` не содержит адресов — он спрашивает их у пользователя.

На каждом сервере:

```bash
bash scripts/configure.sh --role foreign   # /etc/belka-vpn/foreign.env
bash scripts/configure.sh --role ru        # /etc/belka-vpn/ru.env
```

Или локально, затем скопировать (подойдёт и `./env` в репозитории: он в
`.gitignore`, и `tests/lint.sh` игнорируемые файлы не сканирует):

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

1. ставит базовые пакеты, sysctl (BBR, буферы, `tcp_mtu_probing`), logrotate;
2. ставит AmneziaWG (PPA), заголовки ядра, `awg-quick`;
3. генерирует ключи зарубежного сервера и параметры обфускации;
4. пишет `/root/belka-foreign-handoff.env`;
5. пишет `/etc/amnezia/amneziawg/awg0.conf` (пока без peer RU) и поднимает `awg0`;
6. при `GOOGLE_IPV6_EGRESS=1` — IPv6-выход для Google (см. ниже), иначе пропускается;
7. ставит Xray-core, SOCKS на `172.16.0.1:1080`, systemd drop-in после `awg0`;
8. настраивает UFW: SSH (`limit`), UDP-порт только с российского IP, 1080 (TCP и UDP)
   только на `awg0` с `172.16.0.2`;
9. fail2ban для SSH; при `HARDEN_SSH=1` — hardening SSH.

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

Порядок внутри скрипта: базовые пакеты → Hiddify Manager (с drop-in
`hiddify-core.service.d/belka-compat.conf`) → AmneziaWG (пакет, ключи) → RU handoff →
`awg0` → отключение пересылки (`zz-belka-no-forward.conf`) → fail2ban
(`banaction = route`) → чек-лист и списки в `/root` → hardening SSH (при
`HARDEN_SSH=1`). Hiddify ставится до поднятия тоннеля, чтобы инсталлятор не трогал
`awg0`.

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

1. Country = Russia; только VLESS (TLS/Reality на 443); без домена — IP + self-signed.
   Остальные протоколы и «Allow HTTP Connection» (`http_proxy_enable`, конфиги без TLS)
   выключить. Если выключаете уже после подключения клиентов, им нужно обновить
   подписку (`docs/troubleshooting.md`).
2. **Common Proxy Core = Xray**.
3. Only IPv4 = ON; DNS `1.1.1.1`; firewall Hiddify пока OFF (включать в
   панели после успешного `verify.sh`; ручных ufw/iptables не добавлять).
4. Reality 443/tcp; SNI — чужой TLS1.3/HTTP2-сайт (Scanner).
5. Outbound `FOREIGN-Domains`: Socks `172.16.0.1:1080`, списки
   `/root/belka-foreign-domains.txt` + `/root/belka-foreign-geosites.txt`,
   **без** `geoip:google`, Domestic sites OFF.
6. Outbound `FOREIGN-Google-IP`: Socks `172.16.0.1:1080`, только
   `/root/belka-foreign-google-ip.txt` (`geoip:google`), Sites пустые.
   Outbound `FOREIGN-Telegram-IP`: Socks `172.16.0.1:1080`, только
   `/root/belka-foreign-telegram-ip.txt`.
7. Порядок: FOREIGN-Domains → FOREIGN-Google-IP → FOREIGN-Telegram-IP → Direct
   (default). WARP OFF. Встроенный Block остаётся выше Socks, но без списков и с
   Domestic sites OFF.
8. Apply now.
9. Проверить сгенерированный конфиг:
   - sniffing `http/tls/quic`, `routeOnly=false`;
   - три Socks-outbound;
   - Direct последний;
   - `xray -test` проходит (нет неизвестных geosite-тегов).
10. Users → Add user → ссылка/подписка.
11. Custom Proxies: отключить все конфиги с `HC` (их обслуживает hiddify-core, где нет
    `geoip:telegram`); в настройках протоколов оставить только VLESS, Reality и TCP.
    Подписка должна содержать только Xray-конфиги.

## 8. Клиент

- импорт `vless://`/подписки;
- default Proxy, Bypass LAN ON, IPv6 Off, Region Other;
- DNS remote `1.1.1.1`, Resolve Destination OFF;
- desktop — TUN/VPN mode (Claude Code не умеет SOCKS);
- два правила из `config/client/hiddify-allowedips.txt`: 12 исключений → Direct,
  все 199 CIDR → Proxy (правило Proxy ниже правила Direct).

## 9. Проверка

```bash
# RU
bash scripts/verify.sh

# зарубежный сервер
bash scripts/verify.sh --role foreign
```

Клиентские проверки:

1. `https://api.ipify.org` (или `https://ifconfig.me/ip`) → российский IP. `ipinfo.io`
   может уйти через FOREIGN, если его адрес попадает в `geoip:google`.
2. Временно добавить `ipinfo.io` в `Sites` outbound FOREIGN-Domains → зарубежный IP; убрать.
3. YouTube/Google/Claude/OpenAI/ChatGPT/Telegram/Gemini работают (включая медиа/видео Telegram);
   российские сайты идут Direct.
4. `api.anthropic.com` — не 403; `api.openai.com/v1/models` — 401 без ключа, не 403.
5. DNS/IPv6 leak-тесты.
6. Claude Code и Codex CLI в TUN-режиме.

## Текущее состояние: стабилизация Telegram (2026-11-24)

После жалоб на нестабильный Telegram и медленные медиа на RU:

1. Отключены все custom-proxy с `server_core=hiddify_core` (`HC`): 61 включённый →
   `enable=0`. Причина — у hiddify-core нет `geoip:telegram`, Telegram по IP уходил в
   Direct из РФ, где TCP до Telegram заблокирован.
2. Отключены транспорты `vmess`, `grpc`, `httpupgrade`, `xhttp`, `quic`, `h2`;
   оставлены `vless`, `reality`, `tcp`. Подписка отдаёт только Xray-конфиги
   (`raw vless REALITY` и `rawhttp vless`).
3. `AWG_MTU=1240` на обоих серверах (было 1280): на 1280 крупные пакеты терялись
   (до 2%), RTT давал всплески до 0.9 с; на 1240 — 0% на 100×1200 Б.
4. Клиент не настраивался: Hiddify app обновляет профиль по своему интервалу
   (в текущем профиле 3600 с).

Порядок изменения MTU (важно: handoff перекрывает env):

```bash
# на RU
sed -i 's/^AWG_MTU=1280$/AWG_MTU=1240/' /etc/belka-vpn/ru.env \
  /etc/belka-vpn/foreign-handoff.env /root/belka-foreign-handoff.env
sed -i 's/^MTU = 1280$/MTU = 1240/' /etc/amnezia/amneziawg/awg0.conf
systemctl restart awg-quick@awg0

# на FOREIGN
sed -i 's/^AWG_MTU=1280$/AWG_MTU=1240/' /etc/belka-vpn/foreign.env \
  /root/belka-foreign-handoff.env
sed -i 's/^MTU = 1280$/MTU = 1240/' /etc/amnezia/amneziawg/awg0.conf
systemctl restart awg-quick@awg0
```

Проверка: `ip link show awg0` → `mtu 1240`; `awg show` → свежий handshake;
`ping -c100 -s1200 172.16.0.1` с РФ → 0% потерь; `bash scripts/verify.sh` → PASS.

При отключении HC/транспортов сначала сделайте `hiddify-panel-cli backup`, затем
`hiddify apply --no-gui` (ошибка WARP `rc=1` безвредна). Подробности — в
`docs/troubleshooting.md`, раздел «Telegram: нестабильность, медленные медиа».

## IPv6-выход для Google

Нужен, когда `verify.sh` на RU пишет «Google geolocates the FOREIGN exit as RU»: Gemini
со входом в аккаунт тогда блокируется, хотя `ipinfo.io` показывает зарубежную страну.
С `GOOGLE_IPV6_EGRESS=1` Xray на FOREIGN отправляет `geosite:google` и
`geosite:google-gemini` через IPv6 (`ForceIPv6`). YouTube и всё остальное остаются на
IPv4. RU и панель Hiddify не меняются.

1. Если у FOREIGN нет нативного IPv6, зарегистрируйтесь на tunnelbroker.net и создайте
   Regular Tunnel: IPv4 Endpoint — `FOREIGN_PUBLIC_IP`, сервер туннеля в ЕС
   (Amsterdam, Frankfurt, Paris).
2. В `/etc/belka-vpn/foreign.env`:

   ```bash
   GOOGLE_IPV6_EGRESS=1
   HE_SERVER_IPV4=<Server IPv4 Address>
   HE_CLIENT_IPV6=<Client IPv6 Address, с /64>
   ```

   При нативном IPv6 оставьте `HE_*` пустыми.
3. `bash scripts/install-foreign.sh --env-file /etc/belka-vpn/foreign.env`. Скрипт
   поднимает `belka-he-ipv6.service` (6in4), разрешает в UFW proto 41 от сервера HE и
   проверяет `https://www.google.com/generate_204` по IPv6. Конфиг Xray меняется только
   после успешной проверки. Страну по IPv6 глазами Google скрипт пишет в лог.
4. `bash scripts/verify.sh --role foreign`, затем `bash scripts/verify.sh` на RU:
   страна Google для FOREIGN не должна быть `ru`.
5. На клиенте очистите site data `gemini.google.com` и войдите заново.

Отключение: `GOOGLE_IPV6_EGRESS=0` и повторный запуск установщика. Юнит туннеля и
правило UFW удаляются.

## Исходящий IPv4 для Google (sendThrough)

Если Google определяет основной IPv4 как `ru`, а провайдер выдал дополнительный
IPv4, который Google видит иначе, его можно назначить источником для всего прямого
выхода FOREIGN. Переменная действует на outbound `direct` целиком: Google, YouTube,
Telegram, OpenAI и остальные сервисы без отдельного правила.

1. Назначьте адрес по инструкции провайдера и убедитесь, что он локальный:

   ```bash
   ip -4 -o addr show scope global
   ip route get 1.1.1.1 from <ip>
   curl -4 -fsS --interface <ip> --max-time 15 -o /dev/null -D - \
     'https://clientservices.googleapis.com/chrome-variations/seed?osname=win&channel=stable&milestone=140' \
     | grep -i '^x-country:'
   ```

   При NAT провайдера укажите локальный адрес, соответствующий нужному публичному
   выходу. Адрес должен сохраняться после перезагрузки (провайдер, netplan или
   cloud-init): скрипты его не добавляют. Продолжайте, когда `x-country` перестанет
   быть `ru`.

2. В `/etc/belka-vpn/foreign.env`:

   ```bash
   FOREIGN_EGRESS_IPV4=<ip>
   GOOGLE_IPV6_EGRESS=0
   ```

3. Из каталога проекта на FOREIGN:

   ```bash
   bash scripts/install-foreign.sh --env-file /etc/belka-vpn/foreign.env
   systemctl is-active xray
   ```

4. На RU проверьте страну через SOCKS:

   ```bash
   bash scripts/verify.sh --google-only --expect-country fi
   ```

   Без `--expect-country` режим печатает страну и падает только на `ru`/пустом ответе.
   Фактический исходящий адрес проверяется так:
   `bash scripts/verify.sh --expect-egress <ip>`.
   Затем проверьте в клиенте Google Search (страна и источник «по интернет-адресу»),
   Gemini после входа и воспроизведение YouTube.

При `GOOGLE_IPV6_EGRESS=1` Google-хосты уходят через `google-v6` по IPv6 и
`sendThrough` не используют; YouTube остаётся на `direct`.

Если новый адрес становится основным выходом системы, `sendThrough` не нужен. Если
он заменяет публичный адрес, на который RU подключается по AmneziaWG, обновите
`FOREIGN_PUBLIC_IP` в env-файлах и заново обменяйтесь handoff (см. раздел 4).
Откат: очистите `FOREIGN_EGRESS_IPV4` и повторно запустите установщик.

## 10. Обновление и ротация

Повторный запуск скриптов идемпотентен. Ключи и обфускация переиспользуются.

### Доставка кода на серверы с Windows

`/opt/belka-vpn` на серверах — копия из tar, а не git-клон. Если в рабочей копии
`core.autocrlf=true`, то и tar рабочей копии, и обычный `git archive` дают CRLF, и bash
падает с `$'\r': command not found`. Собирайте архив из коммита с LF и передавайте его
из Git Bash: PowerShell 5.1 портит двоичный поток в пайпе.

```bash
git -c core.autocrlf=false -c core.eol=lf archive --format=tar -o deploy.tar \
  HEAD scripts config docs tests .env.example README.md
python -c "import tarfile,sys; t=tarfile.open(sys.argv[1]); \
print([m.name for m in t if m.isfile() and b'\r' in t.extractfile(m).read()] or 'no CR')" deploy.tar
ssh root@<server> 'tar -x -C /opt/belka-vpn && bash /opt/belka-vpn/tests/lint.sh' < deploy.tar
```

CR проверяйте Python-ом, а не `grep $'\r'`: grep из Git Bash CR не находит.

### Обновление ОС и ядра

Модуль AmneziaWG собирается через DKMS. Перед перезагрузкой в новое ядро убедитесь,
что он собран, иначе `awg0` не поднимется. Сначала FOREIGN, потом RU: перезагрузка RU
прерывает VPN у всех клиентов примерно на минуту, перезагрузка FOREIGN — только
FOREIGN-маршруты, примерно на 20–30 секунд.

```bash
DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get -y \
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold dist-upgrade
dkms status                                   # amneziawg: installed для нового ядра
modinfo -k <новое ядро> amneziawg | grep vermagic
grep -m1 -o 'Linux [0-9.-]*-generic' /boot/grub/grub.cfg   # первое = новое ядро
systemctl reboot
# после загрузки
uname -r; bash scripts/verify.sh            # на FOREIGN: --role foreign
```

`--force-confold` сохраняет ваши конфиги (sshd, sysctl). Запускайте `apt-get` через
`nohup` или в `tmux`: на RU ваша SSH-сессия может идти через тот же VPN.

### Hiddify перезаписывает настройки сам

На RU Hiddify запускает свой установщик при каждой загрузке
(`/etc/cron.d/hiddify_reinstall_on_reboot`) и автообновление каждую ночь в 03:00
(`hiddify_auto_update`). Установщик заново создаёт `/etc/sysctl.d/hiddify.conf` с
включённой пересылкой — поэтому `install-ru.sh` перекрывает его файлом
`zz-belka-no-forward.conf`. Новая версия Hiddify может вернуть протоколы или правила по
умолчанию. После перезагрузки RU и после обновлений Hiddify прогоняйте `verify.sh`.

### Ротация ключей

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
ручные правила. Исключение — хвосты от выключенных протоколов, которые Hiddify сам
не удаляет (`docs/troubleshooting.md`). Если доступа к панели нет:

```bash
systemctl restart ssh
fail2ban-client unban --all     # если вас забанил fail2ban
```

fail2ban на RU банит через маршрут (`banaction = route`), а не через iptables:
забаненный адрес виден в `ip route show type unreachable`. Если fail2ban не
отвечает, снимите бан вручную: `ip route del unreachable <ваш IP>`.

## 12. Известные расхождения конфигурации серверов

Открытых расхождений нет. Последняя сверка — 2026-11-24: код в `/opt/belka-vpn` на
обоих серверах совпадает с репозиторием, `verify.sh` проходит без FAIL (RU 26/0,
FOREIGN 7/0).

Закрыто 2026-11-24: на RU включён «Only IPv4»; `REALITY_SNI` в `ru.env` приведён к
фактическому SNI Reality из панели, чек-лист в `/root` пересобран; сохранённый handoff
на RU заменён свежим (без `REALITY_SNI`); удалены лишний `REALITY_SNI` из `foreign.env`
на FOREIGN и посторонний `foreign.env` на RU. Бэкапы прежних файлов — в `/root`
(`*.bak-<дата>`).

Если при следующей сверке найдётся отличие сервера от документации, запишите его сюда
таблицей «Где / Расхождение / Влияние / Как устранить» и удалите строку после
исправления и успешного `verify.sh` на обоих серверах.
