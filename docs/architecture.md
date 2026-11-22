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

`AllowedIPs` на RU = `172.16.0.1/32`, на FOREIGN = `172.16.0.2/32`. Default route не перехватывается, NAT/`ip_forward` на зарубежном сервере не нужны.

Маска в `Address` берётся из `TUNNEL_NET` (по умолчанию `172.16.0.0/24` → `/24`). Допустимы префиксы `/8`–`/30`; оба адреса тоннеля должны лежать внутри сети и не совпадать с адресом сети или broadcast — иначе `configure.sh` и установщики завершаются с ошибкой. `TUNNEL_NET` передаётся в handoff FOREIGN, поэтому на RU действует значение зарубежной стороны.

Публичные IP задаёт пользователь через `scripts/configure.sh` или `/etc/belka-vpn/*.env`. В репозитории их нет.

## Поток трафика

1. Клиент устанавливает VLESS+Reality-соединение с российским сервером.
2. Xray на RU получает SNI (sniffing), применяет правила Outbounds сверху вниз.
3. Совпало с `FOREIGN-Domains` или `FOREIGN-Telegram-IP` → соединение уходит в SOCKS5-outbound на `172.16.0.1:1080`.
4. SOCKS-трафик идёт внутри `awg0` (AmneziaWG) до зарубежного сервера.
5. Xray на FOREIGN принимает SOCKS, резолвит домен через зарубежные DNS (`1.1.1.1`, `8.8.8.8`) и открывает соединение в интернет.
6. Не совпало ни с одним FOREIGN-правилом → `Direct`, выход из России.

## Почему два outbound

Hiddify Manager (v14.5) собирает Xray-конфиг с `domainStrategy: IPOnDemand`. Если в outbound одновременно есть доменные правила и `geoip:google`, Xray может сначала резолвить Google-домен российским DNS, получить российский GGC-адрес и отправить на зарубежный сервер уже IP. Зарубежный выход подключится к российскому кэшу — это медленно и ненадёжно.

Поэтому:

- **FOREIGN-Domains** — только домены и `geosite` (google/youtube/telegram/anthropic/openai/ai). Без `geoip:google`.
- **FOREIGN-Telegram-IP** — только `geoip:telegram`, ниже FOREIGN-Domains. Telegram-клиенты ходят на hardcoded IP без SNI.
- **Direct** — последний и default.

`geoip:google` намеренно не используется. Google Play/сервисы, которые ходят по IP без SNI, могут остаться Direct — это осознанный компромисс.

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

## DNS и GGC

- Клиент: DNS `1.1.1.1` через прокси, IPv6 off, Resolve Destination off.
- RU: Xray резолвит только то, что уходит в Direct; для FOREIGN-правил домен передаётся на зарубежный сервер.
- FOREIGN: `freedom` с `domainStrategy: UseIPv4`, DNS `1.1.1.1`/`8.8.8.8` — домен резолвится на зарубежной стороне.

Так YouTube/Google не получают российские GGC-адреса, а `api.anthropic.com` видит зарубежный выход.

## Безопасность

- Приватные ключи AWG — только на своих серверах, `0600`.
- Handoff — только публичные ключи и параметры обфускации, `0600`.
- SOCKS на FOREIGN слушает только `172.16.0.1`; UFW разрешает 1080 только с `172.16.0.2` на `awg0`.
- На FOREIGN блокируются private-destination в Xray, чтобы сервер нельзя было использовать как pivot в локальную сеть.
- На RU firewall управляет Hiddify Manager; ручной ufw/iptables не добавляем.
- В публичном репозитории нет секретов и публичных IP; admin-ссылка Hiddify — секрет и в лог не пишется.

## Ограничения схемы

- Российский сервер — единственная точка входа: при его падении VPN недоступен. Держите доступ через консоль провайдера.
- Hiddify Manager блокирует QUIC/443: YouTube/Google используют TCP. Это сохраняет SNI-маршрутизацию, но может снижать скорость на некоторых сетях.
- UDP между РФ и зарубежным сервером может резаться DPI/хостером. AmneziaWG маскирует handshake, но UDP-поток может троттлиться; при блокировке меняйте порт/параметры.
- Claude Code не поддерживает SOCKS; на десктопе нужен TUN. WSL2/Docker могут обходить TUN — проверяйте отдельно.
