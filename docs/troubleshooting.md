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
2. В outbound `FOREIGN-Domains` **нет** `geoip:google` (он только в отдельном
   `FOREIGN-Google-IP`).
3. Порядок: `FOREIGN-Domains` (домены) → `FOREIGN-Google-IP` (`geoip:google`) →
   `FOREIGN-Telegram-IP` (`geoip:telegram`) → `Direct` последний.
4. Sniffing включён, `routeOnly=false` в сгенерированном конфиге.
5. Клиент: Resolve Destination OFF, DNS remote, IPv6 off.
6. Hiddify блокирует QUIC/443 — это нормально, YouTube пойдёт по TCP.

Проверка с РФ:

```bash
curl -s --socks5-hostname 172.16.0.1:1080 https://api.ipify.org   # FOREIGN IP
curl -s -o /dev/null -w '%{http_code}\n' --socks5-hostname 172.16.0.1:1080 \
  https://www.youtube.com/generate_204                            # 204
```

## Сайт не открывается в браузере, но работает через curl/SOCKS

Признак: домен есть в `/root/belka-foreign-domains.txt`, `curl` через SOCKS на RU
и `curl.exe` с самого клиента отдают `200`, а браузер — таймаут или ошибку
соединения. При этом YouTube/Google в том же браузере открываются.

Причина: браузер с включённым «безопасным DNS» (DoH) получает HTTPS-запись домена
с параметром `ech` (так отдаёт Cloudflare, например для `rutracker.org`) и шифрует
SNI. Xray не видит домен, правило по домену не срабатывает, и трафик уходит в
`Direct` с российского IP — заблокированный сайт не открывается. YouTube при этом
работает, потому что его ловит `geoip:google` по IP в `FOREIGN-Google-IP`, поэтому
сбой выглядит выборочным.

Проверка на клиенте (curl не использует ECH):

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://rutracker.org/forum/index.php
```

`200` у curl при ошибке в браузере — почти всегда ECH/DoH. Публикует ли домен ECH:

```bash
curl -sS -H 'accept: application/dns-json' \
  'https://cloudflare-dns.com/dns-query?name=rutracker.org&type=HTTPS'
```

`ech=AEX+…` в ответе подтверждает причину.

Исправление — выключить DoH и ECH в браузере:

- Chrome / Edge / Яндекс: Настройки → Конфиденциальность и безопасность →
  «Использовать безопасный DNS» → выкл; в адресной строке
  `chrome://flags/#encrypted-client-hello` (в Яндексе `browser://flags/…`) →
  `Disabled`; перезапустить браузер.
- Firefox: `about:preferences#privacy` → «DNS через HTTPS» → выкл;
  `about:config` → `network.dns.echconfig.enabled = false` (и
  `network.dns.http3_echconfig.enabled = false`); перезапустить.

После исправления очистите site data или откройте приватное окно — страница
блокировки кешируется и переживает отключение ECH.

На сервере это не исправляется: SNI зашифрован, доменное правило его не увидит, а
IP-правило бесполезно — адреса Cloudflare общие для многих сайтов.

## Anthropic/Claude отдаёт 403

403 с текстом про регион означает, что выход всё ещё российский.

- проверьте, что `api.anthropic.com` попадает в `FOREIGN-Domains`;
- `geosite:anthropic` должен присутствовать; если тег неизвестен — оставьте
  явные домены из `/root/belka-foreign-domains.txt`;
- проверьте `curl` с РФ через SOCKS (см. выше);
- Claude Code на десктопе должен работать в TUN-режиме: SOCKS он не
  поддерживает. В WSL2/Docker TUN может не перехватываться.

## Gemini: «недоступен в вашей стране»

Симптом: `https://gemini.google.com/?hl=ru` показывает «Gemini пока не
поддерживается в вашей стране». «YouTube работает» ничего не доказывает: YouTube
доступен и напрямую из России, поэтому его трафик может идти через Direct. Параметр
`hl=ru` меняет только язык интерфейса.

**Важно:** Gemini проверяет не только IP, но и страну Google-аккаунта (регион
аккаунта и платёжный профиль). Аккаунт с российской страной показывает блок даже
через зарубежный IP. Быстрая проверка: откройте Gemini в чистом приватном окне
**без входа** — если блок исчез, дело в аккаунте, а не в VPN. После подключения
VPN обязательно перезагрузите вкладку: соединения, открытые до туннеля, идут
напрямую.

### Две причины блока

Признак «без входа открывается, со входом — „не поддерживается в вашей стране“»
означает, что домен до FOREIGN доходит; Google решает по стране exit-IP и стране
аккаунта. Порядок проверки:

1. **Разные exit-IP у сервисов Google** («traffic anomaly, ip A ≠ B»). Часть
   Google-хостов уходит Direct с российским IP. `google.com` и `geosite:google`
   **не** покрывают зоны `.google`, `.goog`, `.studio`: `gemini.google`,
   `ai.studio`, `generativeai.google`, `notebook.google`, `jules.google`,
   `flow.google`, `opal.google`, `antigravity.google`, `antigravity-unleash.goog`.
   Убедитесь, что в Sites вставлен весь `/root/belka-foreign-domains.txt`;
   `verify.sh` проверяет покрытие этих хостов по сгенерированному конфигу.
   Соединения к IP Google без домена (приложения, хосты вне списков) ловит
   `FOREIGN-Google-IP` с `geoip:google` — без него они уходят Direct.
2. **Страна exit-IP (`x-country: ru`)** — Google считает адрес российским, даже
   когда ipinfo/RIPE показывают другую страну. Смена правил не поможет: нужен
   другой IP/подсеть/хостер или IPv6-выход (`GOOGLE_IPV6_EGRESS=1`, см. runbook).
3. **Страна аккаунта = Россия** — нижний колонтитул Условий
   (`policies.google.com/u/0/terms`) или Play → Country and profiles. Помогает
   только Country Association Form (дни–недели) или новый аккаунт, созданный через
   туннель.
4. **`x-country` не `ru`, аккаунт не российский** — кеш, профиль или ECH:
   очистите site data `gemini.google.com`, выключите ECH/DoH, перезагрузите
   вкладку после подключения VPN.

Сначала выясните, доходит ли домен до зарубежного сервера. На FOREIGN (поставьте
`tcpdump`, если его нет) запустите захват и **затем** откройте новую приватную
вкладку Gemini:

```bash
timeout 90 tcpdump -ni awg0 -s0 -A 'tcp dst port 1080' 2>/dev/null \
  | grep -a --line-buffered -E 'gemini|google|\.com'
```

- виден `gemini.google.com` — маршрутизация работает, причина в exit-IP или аккаунте;
- пакеты есть, но только IP (`05 01 00 01 ...`) — Xray не увидел SNI (ECH) или клиент
  резолвил домен локально;
- пакетов нет — Gemini идёт Direct.

На RU сравните SOCKS и Direct и проверьте страну выхода:

```bash
curl -4 -sS -L --compressed --max-time 25 \
  --socks5-hostname 172.16.0.1:1080 -o /tmp/gemini-socks.html \
  -w '%{http_code} %{url_effective}\n' 'https://gemini.google.com/?hl=ru'
curl -4 -sS -L --compressed --max-time 25 -o /tmp/gemini-direct.html \
  -w '%{http_code} %{url_effective}\n' 'https://gemini.google.com/?hl=ru'

grep -aoiE 'not available in your country|not available in your region|недоступен в вашей стране|не поддерживается в вашей стране' \
  /tmp/gemini-socks.html /tmp/gemini-direct.html

curl -4 -sS --max-time 10 --socks5-hostname 172.16.0.1:1080 https://ipinfo.io/country; echo
curl -4 -sS --socks5-hostname 172.16.0.1:1080 https://ipinfo.io/json
```

Страница блокировки может отдаваться с кодом 200 и рисоваться JavaScript — отсутствие
маркера не доказывает успех; ориентируйтесь на `url_effective`, `<title>` и браузер.

Проверьте сгенерированный конфиг — Google должен быть в правиле на Socks-outbound:

```bash
jq -r '.routing.rules | to_entries[]
  | select((.value.domain // []) | length > 0)
  | "\(.key)\t\(.value.outboundTag)\t\(.value.domain | join(" "))"' \
  /opt/hiddify-manager/generated/xray.json
```

Допустимо `google.com`, `domain:google.com`, `geosite:google`. Если есть только
`full:google.com`, поддомены не покрыты — добавьте в Sites `domain:google.com`
(или явные `gemini.google.com`, `aistudio.google.com`).

Что делать:

- **Не проксируется.** Панель: Common Proxy Core = Xray; Sites содержит весь
  `/root/belka-foreign-domains.txt`, включая `.google`/`.goog`/`.studio`
  (`gemini.google`, `ai.studio`, `generativeai.google`, `antigravity.google`, …),
  а также `rutracker.org`, `rutor.info` и `instagram.com` с CDN;
  Geosites — `geosite:google` и `geosite:google-gemini`; WARP OFF; порядок
  FOREIGN-Domains → FOREIGN-Telegram-IP → Direct; Apply. Списки в `/root` уже без
  комментариев: валидатор Hiddify не принимает строки `#`. Клиент: IPv6 off, DNS
  remote `1.1.1.1`, Resolve Destination OFF, TUN.
  В браузере отключите ECH и DoH (при ECH Xray не видит SNI). Очистите site data или
  откройте приватное окно — кеш страницы блокировки переживает фикс.
- **Проксируется, но Google блокирует exit-IP.** Сторонние базы (`ipinfo.io`,
  Cloudflare) могут показывать зарубежную страну, а собственная геобаза Google — Россию.
  Смотрите страну глазами Google (на RU):

  ```bash
  S='--socks5-hostname 172.16.0.1:1080'
  curl -4 -sS -o /dev/null -D - $S \
    'https://clientservices.googleapis.com/chrome-variations/seed?osname=win&channel=stable&milestone=140' \
    | grep -i '^x-country'
  curl -4 -sS $S -A 'Mozilla/5.0 Chrome/140.0' 'https://www.youtube.com/?hl=en' \
    | grep -oE '"INNERTUBE_CONTEXT_GL":"[A-Z]{2}"' | head -1
  ```

  `ru` / `"RU"` — Google считает exit-IP российским. Типичный признак: Gemini без входа
  открывается, со входом — «не поддерживается в вашей стране». Браузер, кеш, политики
  Chrome и маршрутизация тут ни при чём. Смените IP/подсеть или хостера сервера выхода
  либо попросите хостера исправить geofeed для Google (дни–недели). Cloudflare WARP
  на FOREIGN не помогает: выход WARP через Хельсинки Google тоже считает `ru`.
  Новый IP проверяйте этими же командами до переезда.

  Без смены сервера: выпустите Google через IPv6 (`GOOGLE_IPV6_EGRESS=1`, см.
  runbook, раздел «IPv6-выход для Google»). У IPv6-адресов своя геолокация. Если у
  сервера нет нативного IPv6, подойдёт бесплатный туннель Hurricane Electric. Сначала
  проверьте страну по IPv6 на FOREIGN: `curl -6 -sS -o /dev/null -D - '<тот же URL>'
  | grep -i '^x-country'`. Если и там `ru`, этот путь не поможет.
  Проверяя «работает ли» в другом профиле или `--user-data-dir`, убедитесь, что вход
  действительно выполнен: cookies из скопированного профиля Chrome не расшифровываются.
- **Проксируется, но блокируется аккаунт.** Проверьте страну аккаунта: нижний
  колонтитул страницы Условий Google («Country Version») либо Play Store →
  Settings → General → Account and device preferences → Country and profiles.
  Исправление — [Google Country Association Form](https://policies.google.com/country-association-form);
  изменения могут занять несколько дней, Play-регион меняется не чаще раза в год. Работает и аккаунт,
  созданный через туннель в поддерживаемой стране (без российского телефона и
  платёжного профиля). `verify.sh` проверяет маршрутизацию Gemini/AI-хостов и
  страну exit-IP, но страну аккаунта он не видит.
- **Не делайте:** не добавляйте `geoip:google` в `FOREIGN-Domains` (только в
  отдельный `FOREIGN-Google-IP` ниже него); не правьте
  `/opt/hiddify-manager/generated/xray.json` (перезапишется при Apply); не ставьте
  WARP выше Socks.

Как «прокинуть все IP» Google: поле Geosites/GeoIPs в Hiddify Manager (Xray)
принимает только `geosite:`/`geoip:`, произвольные CIDR туда не вставляются;
rule-sets работают только в hiddify-core, а Common Proxy Core обязан быть Xray.
Поэтому диапазоны Google задаёт `geoip:google` в **отдельном** outbound
`FOREIGN-Google-IP` ниже `FOREIGN-Domains`. В одном правиле с доменами он
запрещён: `domainStrategy: IPOnDemand` резолвил бы Google российским DNS. Домены
по-прежнему ловятся первыми, RU передаёт на FOREIGN сниффнутый домен, и FOREIGN
резолвит его сам; `FOREIGN-Google-IP` добирает соединения «голым IP». `verify.sh`
падает, если `geoip:google` стоит в правиле с доменами или выше доменного правила.
Трафик с ECH/DoH по-прежнему не сниффится — выключайте их в браузере.

`ipinfo.io` в браузере не входит в список FOREIGN и покажет российский IP даже при
рабочем туннеле. Чтобы проверить выход, временно добавьте `ipinfo.io` в Sites, нажмите
Apply, посмотрите страну и уберите запись.

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
  выключить, Block — без списков и с выключенным «Domestic sites»: иначе
  `geoip:ru`/`domain:ru` уходят в blackhole и российские сайты не открываются
  (`verify.sh` это проверяет).
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
2. Удалите `/etc/ssh/sshd_config.d/01-belka-hardening.conf` (в старых версиях —
   `99-belka-hardening.conf`).
3. `systemctl reload ssh`.

Поэтому hardening по умолчанию выключен.

Файл называется `01-…`, а не `99-…`: sshd берёт **первое** значение каждого параметра,
а `sshd_config.d/*.conf` читает по алфавиту. Файл `99-…` не перебивал
`PasswordAuthentication yes` из `50-cloud-init.conf`. Проверка: `sshd -T | grep -i
passwordauthentication` должно показать `no`.

## Клиент импортирует подписку с ошибкой сертификата

Домена нет, панель на IP с self-signed. Используйте прямую `vless://`-ссылку
из панели вместо HTTPS-подписки. Для подписки заведите домен/DDNS и
перевыпустите сертификат в Hiddify.

## DNS-утечки / IPv6

- в Hiddify app: IPv6 **Disabled**, DNS remote `1.1.1.1` через прокси;
- в Hiddify Manager: **Only IPv4 = ON**;
- проверьте `https://test-ipv6.com` и `https://dnsleaktest.com`.

## Корпоративные сайты не открываются: DNS и «Строгая маршрутизация»

Симптом: при включённом belka VPN не открывается сайт внутренней сети (например,
`corp.example`), хотя сам адрес доступен: TCP 443 открыт, HTTPS отвечает. Резолвится
имя только тогда, когда VPN выключен.

Адреса и домены ниже — заглушки (`192.0.2.0/24` — TEST-NET); реальные значения держите
локально, в репозиторий они не попадают.

Проверьте:

```powershell
# какие DNS-серверы Windows NRPT назначает корпоративной зоне
Get-DnsClientNrptRule | Where-Object Namespace -like '*.corp.example' |
  Format-List Namespace, NameServers

# системный резолвер уходит по NRPT на корпоративный DNS
nslookup corp.example

# прямой запрос к корпоративному DNS (UDP/53 через ZeroTier)
nslookup corp.example 192.0.2.10

# сайт жив, если обойти DNS: TCP 443 открыт и HTTPS отвечает
Test-NetConnection 192.0.2.20 -Port 443
curl.exe -I --resolve corp.example:443:192.0.2.20 https://corp.example/
```

Если оба `nslookup` молчат, а `Test-NetConnection` и `curl --resolve` дают 200/302 —
блокируется именно DNS, а не доступность сайта.

Почему так: NRPT-правила Windows отправляют DNS корпоративной зоны на
корпоративный сервер `192.0.2.10`, доступный только через ZeroTier. Hiddify в режиме
**TUN** с включённой «Строгой маршрутизацией» блокирует весь трафик порта 53 (TCP и UDP),
идущий мимо DNS туннеля, — запрос до корпоративного сервера не доходит. TCP 80/443/445
при этом работают: адрес сайта попадает в Direct-правило и уходит через ZeroTier, а не
в Proxy.

Что делать: в Hiddify app откройте **Настройки → Входящие → «Строгая маршрутизация»**
(в англоязычной версии `Strict Route`), выключите её и переподключитесь. Проверьте, что
`nslookup corp.example` отвечает, а сайт открывается.

Компромисс: «Строгая маршрутизация» — защита от DNS-утечек. Без неё DNS корпоративной
зоны уходит напрямую на корпоративный сервер вне туннеля (именно это и нужно в доверенной
сети), а остальной DNS по-прежнему идёт через remote-DNS провайдера. Держите переключатель
выключенным, пока нужен корпоративный DNS.

Убедитесь, что трафик идёт Direct:

```powershell
# LocalAddress должен быть адресом интерфейса ZeroTier, а не TUN Hiddify
Get-NetTCPConnection -RemoteAddress 192.0.2.20 -State Established |
  Select-Object LocalAddress, RemotePort

tracert -d 192.0.2.20
```

Первый хоп — локальный шлюз/ZeroTier, в логах Hiddify соединение помечено `direct`.

Пошаговая настройка клиента — `docs/hiddify-client.md`. Состояние клиента
(`route_rule.proto`, `AppSettings.db`) вручную не правьте — настройки меняются только
через GUI.

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
