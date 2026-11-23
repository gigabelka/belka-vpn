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
   (default). WARP OFF.
8. Apply now.
9. Проверить сгенерированный конфиг:
   - sniffing `http/tls/quic`, `routeOnly=false`;
   - три Socks-outbound;
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
