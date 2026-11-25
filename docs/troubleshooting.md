# Troubleshooting belka-vpn

## Сначала проверьте IP

Скрипты не содержат адресов. Если при запуске ошибка
`RU_PUBLIC_IP is required` / `FOREIGN_PUBLIC_IP is required`:

```bash
bash scripts/configure.sh --role foreign   # или --role ru
# либо отредактируйте /etc/belka-vpn/<role>.env
```

Файлы должны иметь режим `600`, а IP — быть реальными публичными адресами
серверов: `configure.sh` отвергает `0.0.0.0`, loopback, RFC1918, link-local
(`169.254/16`) и CGNAT (`100.64/10`), а также одинаковые IP у RU и FOREIGN.

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
- **MTU**: в текущем развёртывании `1240` (снижено с `1280`: крупные пакеты терялись,
  RTT давал всплески). Payload 1200 Б проходит чисто, ровно-в-MTU 1212 Б может
  всплескивать; при проблемах пробуйте 1228–1232.
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

## Через FOREIGN медленно: где узкое место

Начните с измерения по участкам. Тогда видно, где теряется скорость: у клиента, в
туннеле или на выходе FOREIGN.

```bash
# RU: скорость через SOCKS (весь путь туннель + выход FOREIGN)
curl -s -o /dev/null -w '%{speed_download}\n' --socks5-hostname 172.16.0.1:1080 <URL большого файла>
# FOREIGN: тот же файл напрямую (выход FOREIGN без туннеля)
curl -s -o /dev/null -w '%{speed_download}\n' <URL большого файла>
# RU: задержка и потери в туннеле и по голому каналу одновременно
ping -q -c 500 -i 0.1 172.16.0.1 & ping -q -c 500 -i 0.1 <FOREIGN_PUBLIC_IP>; wait
```

Для пропускной способности туннеля нужен `iperf3`. Ставьте его временно и без демона.
Сервер запускайте на RU (`iperf3 -s -1 -B 172.16.0.2`), клиент — на FOREIGN
(`iperf3 -c 172.16.0.2`, обратное направление — `-R`). Сравните TCP через туннель и TCP
по публичным IP.

Как читать результат:

- **Туннель медленнее голого TCP, ретрансмитов почти нет, CPU свободен** — UDP между
  площадками ограничен по пути (шейпинг у провайдеров или хостеров). Сырой UDP в обход
  туннеля упирается в тот же потолок. Настройками AmneziaWG и sysctl это не лечится;
  поможет только другая площадка или порт.
- **Пики задержки и потери одинаковы в туннеле и на голом канале** — проблема в сети
  между площадками, а не в AmneziaWG.
- **Скорость упирается в CPU** — на FOREIGN с одним vCPU смотрите `softirq` по дельте
  `/proc/stat`.

Ловушки измерений:

- Потери UDP в `iperf3` часто означают дропы в приёмном буфере сокета, а не в сети.
  Сравните с ростом `nstat -az UdpRcvbufErrors` на приёмнике.
- Первый кадр `top -bn1` показывает среднее с момента загрузки, а не текущую нагрузку.
- `mtr` с `-w`/`-z` на Ubuntu 24.04 может падать с `buffer overflow detected`.
  Используйте `mtr -rn` или `ping`.
- С ПК в TUN-режиме ICMP и `tracert` идут через sing-tun: промежуточных хопов не видно,
  а TCP-«порты» выглядят открытыми, потому что TUN сам принимает соединение. Внешние
  проверки делайте с другого сервера.

## Сайт на хостинге (Hetzner и др.) не открывается напрямую из РФ

Из России часть адресов крупных хостингов блокируется (TLS обрывается по таймауту).
Проверка на RU: `curl -m 15 https://<сайт>` висит, а через
`--socks5-hostname 172.16.0.1:1080` открывается. Если такие сайты нужны, добавьте их в
`FOREIGN-Domains`. Для Hetzner в базе Hiddify есть `geosite:hetzner`.

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
  FOREIGN-Domains → FOREIGN-Google-IP → FOREIGN-Telegram-IP → Direct; Apply. Списки в `/root` уже без
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
- **Порядок outbounds**: WARP/Block выше Socks перехватывают трафик, если у них
  есть списки. Встроенный Block стоит первым — это нормально. WARP
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

## После отключения протоколов Hiddify у клиентов пропадает связь

Симптом: после выключения протоколов в панели часть запросов у клиентов падает по
таймауту, а в `journalctl -u hiddify-xray` видны строки
`rejected proxy/trojan: not trojan protocol` с IP клиентов.

Причина: в подписке на устройстве остались удалённые конфиги. Группа `Auto` в Hiddify
app какое-то время выбирает их, сервер не узнаёт такие подключения и отдаёт заглушке.
Через несколько минут `Auto` сам переключается на рабочий конфиг, но приложение
продолжает проверять старые, пока подписка не обновлена. У того, кто вручную закрепил
удалённый конфиг, связи не будет до обновления подписки.

Что делать: на каждом устройстве обновите подписку (профиль → «Обновить»).

Какие флаги за что отвечают (Settings в панели; из CLI —
`hiddify-panel-cli set-setting -k <ключ> -v False`, затем `hiddify apply --no-gui`):

- `http_proxy_enable` («Allow HTTP Connection») — это **не** HTTP-прокси. Флаг
  включает все конфиги без TLS: VLESS/VMess на порту 80 и raw VLESS/VMess на
  случайных портах. Выключите, если клиенты ходят только через TLS/Reality на 443.
  Сам порт 80 останется: haproxy нужен для выпуска сертификатов.
- Отдельные порты открывают `ssh_server_enable`, `wireguard_enable`, `tuic_enable`,
  `hysteria_enable` (Hysteria и Hysteria2), `mieru_enable`, `snell_enable`,
  `anytls_enable`, а также `naive_enable`, `socks_enable`, `telegram_webproxy_enable`.
- Основа belka-vpn — `vless_enable`, `reality_enable` и транспорты на 443 (`tcp`,
  `grpc`, `xhttp`, `httpupgrade`, `h2`, `quic`).

`hiddify apply` может завершиться с кодом 1 из-за шага WARP: если WARP не используется,
это не ошибка. `hiddify-panel-cli get-setting` для выключенного флага ничего не
выводит: проверяйте значение в таблице `bool_config` или в панели. Порты выключенных
протоколов могут остаться в iptables — см. следующий раздел.

## На RU в iptables остались порты выключенных протоколов

Скрипт файрвола Hiddify (`/opt/hiddify-manager/generated/firewall.sh`) только
добавляет правила и в конце сохраняет **всё** текущее состояние в
`/etc/iptables/rules.v4` и `rules.v6`. При загрузке `netfilter-persistent`
восстанавливает правила из этих файлов, и Hiddify сохраняет их снова. Поэтому
ACCEPT-правила для портов выключенных протоколов живут вечно. Политика INPUT на RU и
так ACCEPT, а на этих портах никто не слушает, так что вреда от них нет — это хвост.

Чистить можно, если генератор Hiddify этот порт уже не создаёт (его нет в
`generated/firewall.sh`) и на порту никто не слушает (`ss -lntu`). Это не ручное правило,
а уборка того, что Hiddify больше не хочет:

```bash
P=<порт>   # порт выключенного протокола
for t in iptables ip6tables; do
  $t -S INPUT | grep -E -- "--dport $P( |$)" | sed 's/^-A /-D /' |
    while read -r rule; do eval "$t $rule"; done
done
source /opt/hiddify-manager/scripts/common/utils.sh
source /opt/hiddify-manager/services/firewall/utils.sh
save_firewall
bash /opt/hiddify-manager/services/firewall/run.sh   # не должен вернуть правило
grep -c -- "--dport $P" /etc/iptables/rules.v4        # 0
```

Перед этим сохраните копии `rules.v4` и `rules.v6`.

## Не работают WireGuard или WARP в Hiddify на RU

`install-ru.sh` выключает пересылку пакетов (`ip_forward`) на RU файлом
`/etc/sysctl.d/zz-belka-no-forward.conf`: схеме belka-vpn она не нужна, трафик в
FOREIGN идёт через SOCKS. Hiddify сам включает пересылку при каждой установке, а
установщик Hiddify запускается при каждой загрузке. Поэтому файл назван так, чтобы
применяться после `hiddify.conf` и `wg.conf`: sysctl читает файлы по алфавиту, и
побеждает последнее значение. В том же файле выключен приём ICMP-редиректов
(`accept_redirects`, `secure_redirects`): когда пересылка выключается, ядро снова их
включает, а UFW, который выключил бы их на FOREIGN, на RU нет.

WireGuard и WARP в Hiddify без пересылки не работают. Чтобы их включить:

1. Поставьте `RU_IP_FORWARD=1` в `/etc/belka-vpn/ru.env`.
2. Перезапустите `install-ru.sh` — он удалит файл. Либо удалите файл вручную и
   выполните `sysctl --system`.
3. Проверка: `sysctl net.ipv4.ip_forward` должно показать `1`.

## Сломался SSH после hardening

`HARDEN_SSH=1` пишет `/etc/ssh/sshd_config.d/01-belka-hardening.conf`:

- вход по паролю выключен (`PasswordAuthentication no`, `KbdInteractiveAuthentication no`);
- root входит только по ключу (`PermitRootLogin prohibit-password`);
- проброс X11 выключен (`X11Forwarding no`): на серверах нет графики, проброс только
  расширяет поверхность атаки.

Проброс TCP (`AllowTcpForwarding`) оставлен включённым: через него идёт SSH к FOREIGN
через туннель (см. ниже). Если ключ не был добавлен:

1. Откройте консоль провайдера.
2. Удалите `/etc/ssh/sshd_config.d/01-belka-hardening.conf` (в старых версиях —
   `99-belka-hardening.conf`).
3. `systemctl reload ssh`.

Поэтому hardening по умолчанию выключен.

Файл называется `01-…`, а не `99-…`: sshd берёт **первое** значение каждого параметра,
а `sshd_config.d/*.conf` читает по алфавиту. Файл `99-…` не перебивал
`PasswordAuthentication yes` из `50-cloud-init.conf`. Проверка: `sshd -T | grep -iE
'passwordauthentication|x11forwarding'` должно показать `no` для обоих.

## SSH к FOREIGN: «Connection closed» или `kex_exchange_identification`

Если ПК подключён к VPN, SSH до FOREIGN идёт через Hiddify и выходит в интернет с IP
RU. С этого же IP идут все клиенты VPN. На FOREIGN правило UFW `limit 22/tcp` отклоняет
(REJECT) новые подключения с IP, который за последние 30 секунд сделал 6 и более попыток. Серия быстрых
`ssh`-вызовов поэтому упирается в лимит примерно на минуту. Это не бан fail2ban:
`fail2ban-client status sshd` адреса RU не покажет.

Что делать:

- объединяйте команды в одну SSH-сессию и подождите минуту;
- или заходите на FOREIGN через RU по туннелю: у адреса `172.16.0.2` свой счётчик лимита,
  и SSH FOREIGN доступен по `172.16.0.1`:

  ```bash
  ssh -J root@<RU_PUBLIC_IP> root@172.16.0.1
  ```

  При первом входе ssh спросит отпечаток ключа сервера для адреса `172.16.0.1`: сверьте
  его с отпечатком FOREIGN (`ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub` на
  FOREIGN). Такой вход работает, пока жив туннель, и требует `AllowTcpForwarding` на RU.

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
# NRPT: какая зона уходит на корпоративный DNS
Get-DnsClientNrptPolicy | Where-Object Namespace -like '*.corp.example' |
  Format-List Namespace, NameServers

# системный резолвер не получает ответ
Resolve-DnsName corp.example

# хост доступен, но Strict Route блокирует порт 53
Test-NetConnection 192.0.2.10 -Port 80    # True
Test-NetConnection 192.0.2.10 -Port 53    # False, пока Strict Route включён

# сайт жив, если обойти DNS
curl.exe -I --resolve corp.example:443:192.0.2.20 https://corp.example/
```

Если `Resolve-DnsName` молчит, порт 80/443 у корпоративного DNS отвечает, а порт 53 —
нет, а `curl --resolve` даёт 200/302, значит блокируется именно DNS.

Почему так: NRPT-правила Windows отправляют DNS корпоративной зоны на корпоративный
сервер `192.0.2.10`, доступный только через ZeroTier. Hiddify в режиме **TUN** с
включённой «Строгой маршрутизацией» блокирует весь трафик порта 53 (TCP и UDP), идущий
мимо DNS туннеля, — запрос до корпоративного сервера не доходит. TCP 80/443/445 при
этом работают: адрес сайта уходит через ZeroTier напрямую, а не в Proxy.

Что делать: в Hiddify app откройте **Настройки → Входящие → «Строгая маршрутизация»**
(в англоязычной версии `Strict Route`), выключите её и переподключитесь. Проверено на
Hiddify 5.9.15: после этого `Resolve-DnsName corp.example` отвечает,
`Test-NetConnection 192.0.2.10 -Port 53` — True, сайт открывается.

Компромисс: «Строгая маршрутизация» — защита от DNS-утечек. Без неё DNS корпоративной
зоны уходит напрямую на корпоративный сервер вне туннеля (именно это и нужно в доверенной
сети), а остальной DNS по-прежнему идёт через remote-DNS провайдера. Держите переключатель
выключенным, пока нужен корпоративный DNS.

Пошаговая настройка клиента — `docs/hiddify-client.md`.

## Telegram: сообщения работают, звонки нет

Hiddify блокирует QUIC/443; звонки Telegram используют UDP на других портах.
SOCKS на зарубежном сервере включает UDP, но хвост может резаться DPI/хостером.
Проверьте `geoip:telegram` в отдельном outbound; при проблемах оставьте
TCP-режим.

## Telegram: нестабильность, медленные медиа

Симптомы: сообщения периодически не доходят, медиа/картинки/видео грузятся очень долго.

Причина: в подписке были `HC`-конфиги (`custom_proxy.server_core=hiddify_core`). Их
обслуживает hiddify-core, в маршрутизации которого нет `geoip:telegram` — только
список доменов. Telegram ходит на IP без SNI, поэтому такой конфиг уводит Telegram в
Direct из РФ, а TCP из РФ в Telegram заблокирован (ICMP при этом проходит).
Клиентский `Auto` (`balance`) размазывает соединения по всем конфигам, поэтому сбои
выглядят как «иногда».

На RU отключены все custom-proxy с `server_core=hiddify_core` (`enable=0`), а также
транспорты `vmess`, `grpc`, `httpupgrade`, `xhttp`, `quic`, `h2`; оставлены `vless`,
`reality`, `tcp`. Подписка теперь содержит только Xray-конфиги (`raw vless REALITY`
и `rawhttp vless`), без `HC`.

Проверка:

```bash
# флаги панели
hiddify-panel-cli get-setting vless_enable      # True
hiddify-panel-cli get-setting vmess_enable      # пусто/False

# HC-пресеты: ожидается hiddify_core 0 включённых
mysql ... "SELECT server_core, enable, COUNT(*) FROM custom_proxy GROUP BY server_core, enable"

# правило Telegram в сгенерированном Xray-конфиге
jq '.routing.rules[] | select(.ip != null)' /opt/hiddify-manager/generated/xray.json
```

Порядок изменения: `hiddify-panel-cli backup` → правка `custom_proxy`/флагов →
`hiddify apply --no-gui` (ошибка шага WARP с `rc=1` безвредна).

Клиентские настройки руками не меняем: Hiddify app сам обновляет профиль по интервалу
(в текущем профиле 3600 с; панель `auto_update=1`). Перезапуск приложения запускает
проверку, но не отменяет интервал; обновление можно форсировать кнопкой обновления
профиля.

`box.log` клиента может писать `MONITORING result ... failed: no route to internet`:
это его прямой health-check до IP сервера при `strict_route`, а не реальный трафик.
История Clash API ядра (`/proxies`) при этом показывает задержки 60–70 мс; если она
есть, конфиги живые.

## После загрузки `networking.service` и `ifup@eth0` в статусе failed

У части хостеров в образе остаётся `/etc/network/interfaces` (ifupdown) рядом с
netplan. Интерфейс уже настроил systemd-networkd, поэтому ifupdown падает. Проверка:
`networkctl list` показывает `eth0` как `routable configured`. Ошибка безвредна; если
мешает, удаляйте ifupdown-конфиг только с доступом к консоли провайдера.

## Повторный запуск скриптов что-то сломал

Скрипты идемпотентны, но проверьте:

```bash
bash tests/lint.sh       # без .git (копия из архива) сканирует все файлы
bash scripts/verify.sh
```

`/opt/belka-vpn`, доставленный архивом, не git-клон: `git status` там не работает.
Чтобы убедиться, что на сервере нужная версия, сравните хеши файлов с коммитом
(`git hash-object <файл>` на сервере против `git ls-tree -r <коммит>` локально)
или передайте архив заново.

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
