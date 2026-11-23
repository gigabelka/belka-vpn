# Архитектура belka-vpn

## Компоненты

| Компонент | Где | Назначение |
|---|---|---|
| Hiddify app | клиенты | VLESS + Reality клиент, TUN-режим |
| Hiddify Manager (Xray core) | RU | вход, аутентификация, маршрутизация по доменам/геосайтам |
| AmneziaWG `awg0` | RU + FOREIGN | защищённый транспорт между серверами |
| Xray SOCKS5 | FOREIGN | выход в интернет и резолв доменов на зарубежной стороне |
| Hiddify app routing | клиент | только Direct/Proxy/Block; двух прокси в правиле нет |

## Адресация

```text
Клиент → RU: <RU_PUBLIC_IP>:443/tcp (VLESS+Reality)
RU awg0:     172.16.0.2/24
FOREIGN awg0: 172.16.0.1/24
FOREIGN SOCKS: 172.16.0.1:1080 (только внутри тоннеля)
AmneziaWG:   UDP/443 (настраивается)
```

`AllowedIPs` на RU = `172.16.0.1/32`, на FOREIGN = `172.16.0.2/32`. Default route не перехватывается, NAT/`ip_forward` не нужны ни на одном сервере. На RU `install-ru.sh` выключает пересылку явно (см. «Безопасность»).

Маска в `Address` берётся из `TUNNEL_NET` (по умолчанию `172.16.0.0/24` → `/24`). Допустимы префиксы `/8`–`/30`; оба адреса тоннеля должны лежать внутри сети и не совпадать с адресом сети или broadcast — иначе `configure.sh` и установщики завершаются с ошибкой. `TUNNEL_NET` передаётся в handoff FOREIGN, поэтому на RU действует значение зарубежной стороны.

Публичные IP задаёт пользователь через `scripts/configure.sh` или `/etc/belka-vpn/*.env`. В репозитории их нет.

## Поток трафика

1. Клиент устанавливает VLESS+Reality-соединение с российским сервером.
2. Xray на RU получает SNI (sniffing), применяет правила Outbounds сверху вниз.
3. Совпало с `FOREIGN-Domains`, `FOREIGN-Google-IP` или `FOREIGN-Telegram-IP` → соединение уходит в SOCKS5-outbound на `172.16.0.1:1080`.
4. SOCKS-трафик идёт внутри `awg0` (AmneziaWG) до зарубежного сервера.
5. Xray на FOREIGN принимает SOCKS, резолвит домен через зарубежные DNS (`1.1.1.1`, `8.8.8.8`) и открывает соединение в интернет.
6. Не совпало ни с одним FOREIGN-правилом → `Direct`, выход из России.

## Почему отдельные outbound

Hiddify Manager (v14.5) собирает Xray-конфиг с `domainStrategy: IPOnDemand`. Если в outbound одновременно есть доменные правила и `geoip:google`, Xray может сначала резолвить Google-домен российским DNS, получить российский GGC-адрес и отправить на зарубежный сервер уже IP. Зарубежный выход подключится к российскому кэшу — это медленно и ненадёжно.

Поэтому:

- **FOREIGN-Domains** — только домены и `geosite` (google/youtube/telegram/anthropic/openai/ai). Без `geoip:google`. Сюда же входят заблокированные в РФ торрент-трекеры (`rutracker.org`, `rutor.info` с announce-хостами `t-ru.org` и вспомогательными `dler.cc`) и Instagram с CDN (`cdninstagram.com`, `fbcdn.net`): для них нет geosite-тегов, поэтому хосты перечислены явно.
- **FOREIGN-Google-IP** — только `geoip:google`, ниже FOREIGN-Domains. Ловит соединения к адресам Google без домена (приложения, которые ходят по IP, хосты вне доменных списков), чтобы залогиненная сессия Google не видела российский IP рядом с зарубежным.
- **FOREIGN-Telegram-IP** — только `geoip:telegram`, ниже FOREIGN-Domains. Telegram-клиенты ходят на hardcoded IP без SNI.
- **Direct** — последний и default.

Почему `FOREIGN-Google-IP` не возвращает проблему GGC: Google-домены совпадают с `FOREIGN-Domains` раньше, чем Xray дойдёт до IP-правила, поэтому IPOnDemand их не резолвит. Для остальных соединений резолв на RU нужен только для выбора правила: при `routeOnly=false` на FOREIGN уходит сниффнутый домен, и FOREIGN резолвит его сам. Российские GGC-кэши живут в AS провайдеров и в `geoip:google` не входят. Побочный эффект: сайты на IP Google Cloud тоже выходят через FOREIGN. Диапазоны берутся из `geoip.dat`, который уже есть в Hiddify; во время работы ничего не скачивается.

### Границы доменной маршрутизации

Поле Sites/Geosites в Hiddify Manager (Xray) принимает домены и `geosite:`/`geoip:`,
но не CIDR; rule-sets доступны только в hiddify-core, а Common Proxy Core обязан
быть Xray. Поэтому произвольные CIDR туда не вставить: IP-диапазоны Google
покрывает `geoip:google` в отдельном `FOREIGN-Google-IP`, а `google.com` и `googleapis.com`
покрывают поддомены, а зоны `.google`, `.goog`, `.studio` (`gemini.google`,
`ai.studio`, `ai.google.dev`, `antigravity.google`, …) перечислены в
`config/rules/foreign-domains.txt` явно — иначе они уходили бы Direct и Google
видел бы разные exit-IP. `geosite:google-gemini` (`google-deepmind`) — резерв, но
зависит от версии geo-файлов.

Доменные правила не ловят соединения «голым IP» без SNI и трафик с ECH/DoH; это
ограничение клиента. Смену страны exit-IP и страну Google-аккаунта маршрутизация
не исправляет — см. `docs/troubleshooting.md`.

## Common Proxy Core = Xray

В Hiddify Manager v14.5:

- `geosite:`/`geoip:` применяются только в Xray-routing;
- rule-sets (`.srs`/`.json`) — только в hiddify-core routing;
- Xray-sniffing с `destOverride: [http, tls, quic]` и `routeOnly=false` переподставляет домен вместо IP, поэтому SOCKS-запрос уходит на зарубежный сервер с доменом.

Если оставить Hiddify Core, Google может уйти на зарубежный сервер по российскому IP. Поэтому в панели обязательно:

```text
Settings → Settings → Advanced Settings → Common Proxy Core = Xray
```

и у VLESS+Reality proxy `Server core = Xray`.

Даже с Common Proxy Core = Xray часть конфигов подписки обслуживает hiddify-core
(sing-box): в имени у них пометка `HC`, вход идёт через haproxy на локальные порты
hiddify-core. Hiddify переносит в его маршрутизацию только список доменов из
`FOREIGN-Domains` (`domain_suffix`). `geosite:`, `geoip:google` и `geoip:telegram` для таких
конфигов не действуют. Поэтому домены Google, YouTube и AI-сервисов в
`config/rules/foreign-domains.txt` перечислены явно, а не только через `geosite`. Если
клиент выбрал `HC`-конфиг, соединения «голым IP» к Google и Telegram уйдут Direct.
Проверка: `jq '.route.rules' /opt/hiddify-manager/generated/hiddify-core.json`.

## DNS и GGC

- Клиент: DNS `1.1.1.1` через прокси, IPv6 off, Resolve Destination off.
- RU: Xray резолвит только то, что уходит в Direct; для FOREIGN-правил домен передаётся на зарубежный сервер.
- FOREIGN: `freedom` с `domainStrategy: UseIPv4`, DNS `1.1.1.1`/`8.8.8.8` — домен резолвится на зарубежной стороне.

Так YouTube/Google не получают российские GGC-адреса, а `api.anthropic.com` видит зарубежный выход.

## IPv6-выход для Google (опция)

Собственная геобаза Google может считать IPv4 зарубежного сервера российским, даже
когда RIPE и сторонние базы показывают другую страну. Gemini проверяет именно её.
С `GOOGLE_IPV6_EGRESS=1` на FOREIGN появляется outbound `google-v6` (`freedom`,
`ForceIPv6`) и правила: `geosite:youtube` → `direct` (IPv4), затем `geosite:google` и
`geosite:google-gemini` → `google-v6`. Домен приходит на FOREIGN в SOCKS-запросе, поэтому
sniffing там не нужен.

- `ForceIPv6`, а не `UseIPv6v4`: если IPv6 пропал, запрос к Google падает, а не уходит
  молча с IPv4, который Google считает российским.
- YouTube остаётся на IPv4: видео упёрлось бы в пропускную способность туннеля, а
  региональную блокировку применяет Gemini, не YouTube.
- Без нативного IPv6 используется туннель 6in4 Hurricane Electric
  (`belka-he-ipv6.service`, `ip tunnel … mode sit`). Netplan не трогаем: `netplan apply`
  на удалённом сервере может уронить сеть и `awg0`.
- При выключенной опции конфиг Xray совпадает с прежним байт в байт, поэтому лишних
  перезапусков нет.

## Безопасность

- Приватные ключи AWG — только на своих серверах, `0600`.
- Handoff — только публичные ключи и параметры обфускации, `0600`.
- SOCKS на FOREIGN слушает только `172.16.0.1`; UFW разрешает 1080 только с `172.16.0.2` на `awg0`.
- На FOREIGN блокируются private-destination в Xray, чтобы сервер нельзя было использовать как pivot в локальную сеть.
- На RU firewall управляет Hiddify Manager; ручной ufw/iptables не добавляем.
  Удалять можно только хвосты, которые генератор Hiddify больше не создаёт
  (`docs/troubleshooting.md`, раздел про порты выключенных протоколов).
- RU не пересылает пакеты. Hiddify включает `ip_forward` в `/etc/sysctl.d/hiddify.conf`
  (установщик Hiddify пересоздаёт его при каждой загрузке) и в `wg.conf` своего
  WireGuard, а политика `FORWARD` у него `ACCEPT`. Без защиты сосед по сети хостера мог
  бы использовать RU как маршрутизатор. `install-ru.sh` пишет
  `/etc/sysctl.d/zz-belka-no-forward.conf`: файлы sysctl применяются по алфавиту,
  побеждает последнее значение, поэтому имя идёт после обоих файлов Hiddify. При смене
  `ip_forward` ядро выставляет `accept_redirects` в противоположное значение, а UFW на RU
  нет. Поэтому тот же файл выключает приём ICMP-редиректов маской `conf.*`: для IPv4
  без пересылки редирект принимается, если его разрешает `all` **или** интерфейс, а
  IPv6 не применяет `all` к уже созданным интерфейсам. WireGuard и WARP в Hiddify без
  пересылки не работают: для них `RU_IP_FORWARD=1`.
- SSH: `HARDEN_SSH=1` выключает пароли и X11-проброс файлом
  `sshd_config.d/01-belka-hardening.conf`. sshd берёт первое значение каждого
  параметра, а файлы читает по алфавиту, поэтому `01-` идёт раньше `50-cloud-init.conf`.
- Протоколы Hiddify: оставляйте только TLS/Reality на 443. Каждый лишний протокол
  открывает свой публичный порт; конфиги без TLS выключает «Allow HTTP Connection»
  (`http_proxy_enable`).
- Hiddify на RU запускает свой установщик при каждой загрузке и автообновление каждую
  ночь в 03:00 (`/etc/cron.d/hiddify_*`). Новая версия может вернуть настройки по
  умолчанию, поэтому после перезагрузки и обновлений прогоняйте `verify.sh`.
- В публичном репозитории нет секретов и адресов серверов; admin-ссылка Hiddify — секрет и в лог не пишется. Единственное исключение — `config/client/hiddify-allowedips.txt`: это список маршрутизации клиента (инверсия Direct-списка), а не идентификатор сервера.

## Ограничения схемы

- Российский сервер — единственная точка входа: при его падении VPN недоступен. Держите доступ через консоль провайдера.
- Hiddify Manager блокирует QUIC/443: YouTube/Google используют TCP. Это сохраняет SNI-маршрутизацию, но может снижать скорость на некоторых сетях.
- UDP между РФ и зарубежным сервером может резаться DPI/хостером. AmneziaWG маскирует handshake, но UDP-поток может троттлиться; при блокировке меняйте порт/параметры. На практике туннель упирался в шейпинг UDP по пути примерно на 150 Мбит/с на поток без потерь, тогда как TCP между теми же серверами шёл в 3–5 раз быстрее. Настройками это не лечится; как отличить такой потолок от проблем серверов — `docs/troubleshooting.md`.
- `write_sysctl` (`scripts/lib.sh`) поднимает потолки буферов сокетов до 64 МБ (`rmem_max`/`wmem_max`, `tcp_rmem`/`tcp_wmem`) и включает `tcp_mtu_probing`: при MTU туннеля 1280 TCP сам находит рабочий размер пакета, если PMTU-сообщения теряются. На RU те же буферы выставляет Hiddify. Пропускную способность сверх потолка пути это не поднимает, но убирает ограничение по умолчанию в 208 КБ на явный `SO_RCVBUF`/`SO_SNDBUF`.
- Claude Code не поддерживает SOCKS; на десктопе нужен TUN. WSL2/Docker могут обходить TUN — проверяйте отдельно.
