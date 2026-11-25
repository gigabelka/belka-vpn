# Hiddify app: настройка клиента belka-vpn

Клиент Hiddify app подключается только к российскому серверу и по умолчанию отправляет
весь трафик в **Proxy**; сервер сам решает, что отправить на зарубежный выход. В клиенте
нужно лишь исключить из туннеля адреса, к которым ходим напрямую.

Адреса и домены в примерах — заглушки (`corp.example`, `192.0.2.0/24` — TEST-NET).
Реальные значения храните локально: в репозиторий они не попадают.

## 1. Импорт профиля

1. В Hiddify Manager: **Users → Add user** — получите `vless://`-ссылку или подписку.
2. В Hiddify app: **Профили → Добавить профиль** и вставьте ссылку.
3. Если подписка по HTTPS отклоняется из-за self-signed сертификата (панель на IP без
   домена), используйте прямую `vless://`-ссылку — см. `docs/troubleshooting.md`.

## 2. Базовые настройки клиента

Десктоп (в мобильной версии названия пунктов аналогичны):

- **Прокси по умолчанию** — выход через профиль (**Proxy**; в некоторых версиях пункт
  показывает «Балансировка»), Настройки → Маршрутизация;
- **Обход LAN / Bypass LAN** — включён (Настройки → Маршрутизация);
- **Регион / Region** — `Other`: разделение трафика делает сервер;
- **IPv6** — `Disabled` (только IPv4);
- **DNS** — remote `1.1.1.1` через прокси (Настройки → DNS);
- **Resolve Destination / Определить адрес назначения** — выключен;
- на десктопе — **TUN/VPN mode**: Настройки → Входящие → режим службы `VPN`.
  Claude Code не поддерживает SOCKS; WSL2/Docker могут обходить TUN;
- **Правила маршрутизации** — два правила из `config/client/hiddify-allowedips.txt`:
  12 исключений → **Напрямую**, все 199 адресов → **Proxy** (см. §3–§4; без GUI — §8).

## 3. Правило Direct: 12 адресов в обход VPN

Клиент по умолчанию отправляет всё в **Proxy**. Адреса, к которым нужно ходить
напрямую, перечислены в шапке `config/client/hiddify-allowedips.txt` — блок
«The 12 Direct exceptions».

1. Откройте `config/client/hiddify-allowedips.txt` и скопируйте **12 строк-диапазонов**
   из этого блока (строки с CIDR, без пояснений и без `#`).
2. В Hiddify app: **Настройки → Маршрутизация → добавить правило**, условие
   **«IP CIDR назначения»** (в англ. версии `Destination IP CIDR`), outbound
   **«Напрямую»** (`Direct`), вставьте скопированные строки.
3. Сохраните правило и переподключитесь. Это правило должно стоять **выше**
   правила Proxy из §4.

Образец формата — `config/client/hiddify-bypass.txt.example` (это только формат, а не
готовый список). Свои дополнения держите в `config/client/hiddify-bypass.local.txt`:
файл gitignored через `*.local.txt` и в репозиторий не попадает.

> Публичные CIDR из этих списков не копируйте в `.md`-файлы, issues и чаты: в репозитории
> им место только в файле-источнике (это проверяет `tests/lint.sh`).

## 4. Правило Proxy: все 199 IP из `hiddify-allowedips.txt`

Тело `config/client/hiddify-allowedips.txt` — те же адреса в обратной записи:
199 CIDR «весь интернет, кроме 12 исключений», то есть полный список `AllowedIPs`.
В Hiddify app его добавляют отдельным правилом с outbound **Proxy**:

1. Откройте `config/client/hiddify-allowedips.txt` и скопируйте **все CIDR-строки
   после шапки** (начиная с `0.0.0.0/5`), без строк с `#`.
2. В Hiddify app: **Настройки → Маршрутизация → добавить правило**, условие
   **«IP CIDR назначения»**, вставьте все 199 строк, outbound **Proxy**
   («Балансировка» / «Прокси по умолчанию»).
3. Перетащите правило за ручку слева так, чтобы оно было **ниже** правила
   12 → **Напрямую** (§3): правила проверяются сверху вниз, срабатывает первое
   совпадение. Сохраните и переподключитесь.

При «Прокси по умолчанию = Балансировка» правило 199 → Proxy избыточно по эффекту,
но безвредно: оно делает список AllowedIPs явным и продолжит работать, если default
переключат на «Напрямую». В профилях, где поле `AllowedIPs` есть (сырой
sing-box/WireGuard, часть мобильных клиентов), те же 199 строк вставляются прямо
в это поле — отдельное правило Proxy не нужно.

> Не добавляйте 199 строк в правило с outbound **«Напрямую»** (в том числе
> в «Обход LAN»): это инверсия списка, и маршрутизация перевернётся — мимо VPN
> пойдёт почти весь трафик.

## 5. «Строгая маршрутизация» и корпоративный DNS

В режиме TUN «Строгая маршрутизация» (`Strict Route`) блокирует весь трафик порта 53,
идущий мимо DNS туннеля. Если на машине есть корпоративные NRPT-правила (DNS внутренней
зоны идёт на корпоративный сервер через ZeroTier), корпоративные имена перестают
резолвиться, хотя сами сайты доступны.

- Выключите **Настройки → Входящие → «Строгая маршрутизация»**, затем переподключитесь.
- Компромисс: DNS корпоративной зоны пойдёт напрямую на корпоративный сервер вне туннеля
  (это и нужно в доверенной сети); остальной DNS — как раньше через remote-DNS.
- Диагностика и проверки — раздел «Корпоративные сайты не открываются» в
  `docs/troubleshooting.md`.

## 6. Проверка

```powershell
# обычный трафик идёт с российского IP
curl.exe -s https://ipinfo.io/ip

# утечки IPv6/DNS проверяйте на https://test-ipv6.com и https://dnsleaktest.com

# адрес из Direct-списка идёт мимо туннеля:
# первый хоп — локальный шлюз, в логах Hiddify — direct
tracert -d <IP из Direct-списка>

# адрес вне 12 исключений идёт через Proxy:
# в логах Hiddify соединение помечено proxy, а не direct
```

Корпоративный DNS-кейс — `docs/troubleshooting.md`, раздел «Корпоративные сайты
не открываются».

## 7. Где хранится состояние клиента

- `%APPDATA%\Hiddify\hiddify\route_rule.proto` — правила маршрутизации, бинарный
  protobuf (см. §8);
- `%APPDATA%\Hiddify\hiddify\data\AppSettings.db` — настройки, LevelDB;
- `%APPDATA%\Hiddify\hiddify\configs\*.json` — профили, там приватные ключи;
- `C:\Program Files\Hiddify\Hiddify.exe` — лаунчер, а не конфиг.

Не редактируйте эти файлы при запущенном приложении и не кладите их в репозиторий или
общие бэкапы: ядро перезаписывает их своим состоянием. Обычный путь настройки — GUI;
исключение для `route_rule.proto` при закрытом Hiddify описано в §8.

## 8. Без GUI: правка `route_rule.proto`

Обычный путь — меню приложения (§3–§4). Если Hiddify полностью закрыт, те же два
правила можно дописать в `%APPDATA%\Hiddify\hiddify\route_rule.proto` (проверено на
Hiddify 5.9.15). Это protobuf `config.RouteRule`: встроенные правила (`builtin:*`)
приложение при запуске пересоздаёт, кастомные (`belka:*`) сохраняет; порядок правил
в файле = порядок проверки.

Поля `Rule`: `1 list_order`, `2 enabled`, `3 name`, `4 outbound` (`0` Proxy,
`1` Direct, `2` Direct with fragment, `3` Block), `13 ip_cidrs`.

1. Полностью закройте Hiddify: `Get-Process Hiddify` не должен ничего находить.
2. Из корня репозитория выполните Python 3 (только стандартная библиотека). Скрипт
   сам делает резервную копию и отказывается работать, если правила уже добавлены:

   ```python
   import os, re
   from datetime import datetime
   from pathlib import Path

   def varint(n):
       out = bytearray()
       while True:
           b = n & 0x7f
           n >>= 7
           out.append(b | 0x80 if n else b)
           if not n:
               return bytes(out)

   def field(num, wire, data):
       tag = varint((num << 3) | wire)
       return tag + (varint(len(data)) + data if wire == 2 else varint(data))

   def rule(order, name, outbound, cidrs):
       body = field(1, 0, order) + field(2, 0, 1) + field(3, 2, name.encode())
       body += field(4, 0, outbound)
       body += b''.join(field(13, 2, c.encode()) for c in cidrs)
       return field(1, 2, body)

   text = Path('config/client/hiddify-allowedips.txt').read_text(encoding='utf-8')
   direct = re.findall(r'^#\s+(\d+\.\d+\.\d+\.\d+/\d+)$', text, re.M)
   body = [l.strip() for l in text.splitlines() if l.strip() and not l.startswith('#')]
   assert (len(direct), len(body)) == (12, 199), (len(direct), len(body))

   state = Path(os.environ['APPDATA']) / 'Hiddify' / 'hiddify'
   p = state / 'route_rule.proto'
   data = p.read_bytes()
   assert b'belka:allowedIps' not in data, 'already patched'

   bak = state / f"route_rule.proto.bak-belka-{datetime.now():%Y%m%d-%H%M%S}"
   bak.write_bytes(data)
   tmp = state / 'route_rule.proto.tmp'
   tmp.write_bytes(data + rule(4, 'belka:bypassVpn', 1, direct)
                        + rule(5, 'belka:allowedIps', 0, body))
   tmp.replace(p)
   print('backup:', bak)
   print('patched:', p)
   ```

3. Запустите Hiddify и проверьте **Настройки → Маршрутизация**:
   `belka:bypassVpn` (`IP CIDR назначения | 12`, outbound «Напрямую») должен стоять
   выше `belka:allowedIps` (`| 199`, outbound «Proxy»).
4. Откат: закройте Hiddify и верните копию:

   ```powershell
   $d = Join-Path $env:APPDATA 'Hiddify\hiddify'
   Copy-Item "$d\route_rule.proto.bak-belka-<дата>" "$d\route_rule.proto" -Force
   ```

> Не правьте файл при запущенном приложении: UI держит правила в памяти и перезапишет
> файл. Не коммитьте `route_rule.proto`, `configs/*.json` и `AppSettings.db`: там
> настройки, а в `configs` — приватные ключи. Сброс правил в приложении или
> переустановка удалят кастомные правила — повторите процедуру.

## 9. Если не работает

Смотрите `docs/troubleshooting.md`: DNS-утечки и IPv6, ошибка сертификата подписки,
корпоративные сайты и «Строгая маршрутизация», YouTube/Google через Россию.
