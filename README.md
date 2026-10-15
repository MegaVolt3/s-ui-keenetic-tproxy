# s-ui-keenetic-tproxy

Обвязка для [s-ui](https://github.com/alireza0/s-ui) (sing-box) на роутерах
**Keenetic / Netcraze с Entware**: заворачивает клиентов выбранной политики
Keenetic в прозрачный прокси s-ui (TCP через REDIRECT, UDP через TProxy),
держит служебные и локальные назначения напрямую и восстанавливает свои правила
после того, как NDM пересоберёт свой firewall.

Панель s-ui сама по себе не умеет привязываться к политике Keenetic и не
переживает перестройку iptables — этим и занимается `sui-tproxy`.

```
LAN-клиент (политика SUI-TProxy, mark 0xffffaac)
        │
        ├─ TCP ─► nat PREROUTING (connmark = mark политики) ─► REDIRECT :7787 ─┐
        └─ UDP ─► mangle PREROUTING (connmark = mark) ─► TPROXY :7788 ────────┤
                                                                              ▼
                                                              s-ui / sing-box (routes, VPN out)
```

## Состав репозитория

| Файл | Куда ставится | Назначение |
|------|---------------|------------|
| `sbin/sui-tproxy` | `/opt/sbin/sui-tproxy` | основной скрипт: строит правила, генерирует хук, умеет `start/stop/restart/apply/schedule/status` |
| `etc/init.d/S99sui-tproxy` | `/opt/etc/init.d/` | применять обвязку при загрузке (после `S90s-ui`) |
| `etc/sui-tproxy/sui-tproxy.conf.example` | `/opt/etc/sui-tproxy/sui-tproxy.conf` | локальные настройки: описание политики, порты, исключения |
| `etc/ndm/netfilter.d/sui-tproxy.sh.example` | генерируется автоматически | хук, который NDM вызывает после пересборки firewall; в репозитории — только для понимания |
| `examples/zz-public-ip-local.sh` | `/opt/etc/ndm/netfilter.d/` (опционально) | если публичный адрес живёт на вышестоящем NAT: не пускать локальный трафик к нему в прокси и DNAT-ить его на роутер |
| `sbin/sui-update` | `/opt/sbin/sui-update` | установка/обновление **бинарника s-ui** из релизов апстрима: проверка SHA256, бэкап, авто-откат, `--check`, `--from-file` |
| `etc/init.d/S90s-ui` | `/opt/etc/init.d/` | минимальный init самой панели — ставится только если своего `S90s-ui` ещё нет |
| `bootstrap.sh` | запускается на роутере | установка одной строкой: зависимости, файлы проекта, свежий бинарник, запуск и проверка |
| `install.sh` | запускается на роутере | установка/удаление/статус файлов проекта |

## Требования

- KeeneticOS / NetcrazeOS с Entware (`/opt`), проверено на **5.1.8 aarch64**;
- Entware-пакеты: `ipset`, `iptables`, `iproute2` (модуль `xt_TPROXY` — из ядра Keenetic);
- работающий s-ui (`/opt/etc/s-ui`) с инбаундами:
  - TCP **redirect** на `REDIRECT_PORT` (по умолчанию 7787),
  - UDP **tproxy** на `TPROXY_PORT` (по умолчанию 7788);
- на роутере должна существовать политика (Policy) с описанием
  `SUI-TProxy` и ненулевым `mark` — скрипт достаёт mark через
  `ndmc -c "show ip policy"`. Устройства, которые должны ходить через прокси,
  помещаются в эту политику.

Установка s-ui на Keenetic — задача апстримного скрипта
[s-ui-keenetic](https://gitlab.com/own-open-source/s-ui-keenetic) (GPLv3), этот
репозиторий его не заменяет и не содержит.

## Установка одной строкой

На роутере, от root. Скачать и запустить bootstrap (BusyBox-овый `wget` на части
прошивок Keenetic не умеет TLS и падает — берите Entware-овый `/opt/bin/wget`
или `curl`):

```sh
/opt/bin/wget -qO- https://raw.githubusercontent.com/MegaVolt3/s-ui-keenetic-tproxy/main/bootstrap.sh | sh -s --
# или, если в системе есть curl:
curl -fsSL https://raw.githubusercontent.com/MegaVolt3/s-ui-keenetic-tproxy/main/bootstrap.sh | sh -s --
```

Обратите внимание на `sh -s --`: без `--` шелл сам съедает аргументы.

Что делает bootstrap: ставит недостающие пакеты Entware (`wget-ssl`, `curl`,
`ca-certificates`, `ipset`, `iptables`), распаковывает проект и вызывает
`install.sh`, затем ставит через `sui-update` **последний релиз s-ui**,
поднимает панель и обвязку и печатает проверку (порты, ipset, цепочки, mark
политики). Полезные ключи:

| Ключ | Смысл |
|------|-------|
| `--sui-version latest\|X.Y.Z` | какую версию s-ui поставить (по умолчанию latest) |
| `--skip-sui` | не трогать бинарник панели (например, уже стоит свой) |
| `--no-glue` | поставить файлы, но не применять правила firewall |
| `--policy-desc NAME` | описание политики Keenetic (пишется в конфиг) |
| `--from-file FILE` | поставить проект из локального tarball (офлайн) |
| `--dry-run` | показать план и ничего не менять |

Создание самой политики Keenetic остаётся ручным (два клика в UI): нужна
политика с описанием из `POLICY_DESCRIPTION` и ненулевым `mark`. Пока её нет,
панель работает, но проксирования не будет — обвязка подхватит mark при
следующем событии NDM.

### Вручную (без bootstrap)

```sh
# на роутере, из каталога с распакованным репозиторием
./install.sh --start
```

или совсем вручную:

```sh
opkg install ipset iptables iproute2
mkdir -p /opt/etc/sui-tproxy /opt/etc/ndm/netfilter.d
cp sbin/sui-tproxy /opt/sbin/ && chmod 755 /opt/sbin/sui-tproxy
cp etc/init.d/S99sui-tproxy /opt/etc/init.d/ && chmod 755 /opt/etc/init.d/S99sui-tproxy
cp etc/sui-tproxy/sui-tproxy.conf.example /opt/etc/sui-tproxy/sui-tproxy.conf
vi /opt/etc/sui-tproxy/sui-tproxy.conf
/opt/etc/init.d/S99sui-tproxy start
```

`install.sh` не перезаписывает существующий конфиг и делает бэкап файлов,
которые заменяет (`/opt/etc/sui-tproxy/backup/`). Префикс можно переопределить
(`PREFIX=/tmp/x ./install.sh`) — это тестовый режим без изменения firewall.

## Настройка

`sui-tproxy.conf` — обычный POSIX-sh, который скрипт «сорсит»:

| Переменная | Смысл |
|------------|-------|
| `POLICY_DESCRIPTION` | описание политики Keenetic, по нему ищется mark (по умолчанию `SUI-TProxy`) |
| `POLICY_MARK` | необязательно: жёстко задать mark вместо опроса `ndmc` |
| `REDIRECT_PORT` / `TPROXY_PORT` | порты TCP-REDIRECT и UDP-TProxy инбаундов s-ui |
| `TPROXY_MARK` / `TPROXY_TABLE` | fwmark и таблица policy routing для локального маршрута TProxy |
| `BYPASS_PORTS` | порты, которые всегда идут напрямую; по умолчанию только 123 и 2095, всё остальное — ваше |
| `EXTRA_BYPASS_NETS` | дополнительные сети напрямую: ваш публичный WAN-адрес, соседние подсетки |

Приватные и служебные сети (`0.0.0.0/8`, `10/8`, `172.16/12`, `192.168/16`,
`224/4`, …) исключаются всегда, плюс все адреса самого роутера.

В репозитории нет значений конкретной площадки: единственный встроенный список
исключений — `RESERVED_NETS` с каноническими RFC-диапазонами (loopback, RFC1918,
link-local, multicast), без которых локальный трафик уходил бы в прокси. Свои
порты и сети задаются только в конфиге, в примерах для наглядности оставлены
одна-две записи.

## Проверка

```sh
/opt/etc/init.d/S99sui-tproxy status      # policy/mark, ipset, цепочки, правило fwmark
ndmc -c "show ip policy" | grep -A3 SUI-TProxy
iptables -t nat -S | grep 7787
iptables -t mangle -S | grep 7788
grep -a . /proc/net/nf_conntrack | grep "sport=7787"     # живые клиентские потоки
```

В conntrack на таком роутере видно две стороны одного потока: клиент
(`src=192.168.x.x dst=<цель>`) и сам REDIRECT-инбаунд (`src=<роутер> sport=7787`).
`[ASSURED]` означает, что соединение дошло до цели, `[UNREPLIED] packets=0` — что
ответа нет (это уже вопрос к правилам/узлу s-ui, а не к обвязке).

## Обновление бинарника s-ui

Бинарник панели обновляется скриптом `sui-update` — прямо на роутере или по ssh
с рабочей машины:

```sh
/opt/sbin/sui-update --check        # что стоит, что доступно, есть ли флаг +x
/opt/sbin/sui-update                # поставить последний релиз
/opt/sbin/sui-update --version 1.6.4
/opt/sbin/sui-update --from-file /tmp/s-ui-linux-arm64.tar.gz   # офлайн-архив
/opt/sbin/sui-update --force        # переустановить (например, починить права)

# из рабочей машины:
ssh root@<router> /opt/sbin/sui-update --check
ssh root@<router> /opt/sbin/sui-update
```

Что гарантируется:

- скачанный `s-ui-linux-<arch>.tar.gz` проверяется по `SHA256SUMS` релиза
  (`sha256sum` есть и в BusyBox, и в Entware), а распакованный файл — на
  ELF-магию и разумный размер;
- ставится **только бинарник**: upstream-овские `s-ui.sh` и `s-ui.service` из
  архива игнорируются, поэтому ваш `db/`, `config/` и скрипт меню (если он есть
  от s-ui-keenetic) остаются нетронутыми;
- установленный файл всегда получает `chmod 755` — это и есть лечение ошибки
  `nice: can't execute '/opt/etc/s-ui/sui': Permission denied`, которая
  появляется после ручной заливки бинарника без флага исполнения;
- предыдущая версия копируется в `/opt/etc/s-ui/backups/` (по умолчанию
  хранятся 2), и если панель не поднялась на своём порту за 90 с — версия
  автоматически откатывается из бэкапа;
- если версия уже актуальна, ничего не делается (`--force` — переустановить), а
  если бинарник потерял флаг исполнения, переустановка идёт даже без `--force`.

Коды выхода: `0` — успех/уже актуально, `1` — есть обновление (`--check`) или
обновление не удалось, `2` — ошибка аргументов/окружения.

## Если что-то не работает

- **s-ui не стартует, в `/opt/var/log/script_s-ui.log` строка
  `nice: can't execute '/opt/etc/s-ui/sui': Permission denied`.**
  У бинарника панели потерян флаг исполнения — типично после замены бинарника
  вручную (копирование/загрузка файла не сохраняет режим). Лечение:
  `chmod 755 /opt/etc/s-ui/sui && /opt/etc/init.d/S90s-ui start`.
  Повторяемость проверяется по `stat /opt/etc/s-ui/sui`: если `Change` совпадает
  с `Modify`, после перезаписи файла chmod никто не делал.
- **`download failed` или `Segmentation fault` при скачивании.** В `PATH` на
  части прошивок Keenetic `wget` — это BusyBox-овый: TLS он не умеет и падает.
  Используйте `/opt/bin/wget` (пакет `wget-ssl`) или `curl`; `bootstrap.sh` сам
  поставит их через opkg. BusyBox-овый wget разрешается явно только ключом
  `--allow-busybox-wget`.
- **`tar: invalid option -- 'c'`.** Снова BusyBox tar в `PATH`; скрипты сами
  ищут GNU tar (`/opt/bin/tar`, пакет `tar`), а при ручной распаковке указывайте
  его явно.
- **Скрипт по ssh отвечает «unknown argument».** При запуске через
  `... | sh -s` аргументы надо отделять: `| sh -s -- --check`.
- **`Keenetic policy 'SUI-TProxy' not found`.** Описание политики не совпало с
  `POLICY_DESCRIPTION` (`ndmc -c "show ip policy"` показывает `description = …:`),
  либо у политики нет `mark`. Правило ищет mark до 120 с — после переименования
  политики правила применятся при следующем событии NDM.
- **`ipset unavailable` / `bypass set missing`.** Не установлен пакет `ipset`
  (или `ipset` недоступен в PATH) — правила не применяются намеренно, чтобы не
  остаться без исключений.
- **UDP не идёт через прокси.** Не загружен `xt_TPROXY`; скрипт пытается
  `modprobe`/`insmod` и пишет предупреждение — проверьте `lsmod | grep TPROXY`.
- **Правила исчезли после перезагрузки или смены политики.** NDM пересобирает
  свои цепочки; наш хук `/opt/etc/ndm/netfilter.d/sui-tproxy.sh` вызывается на
  каждое такое событие и заново применяет правила (`sui-tproxy schedule` —
  повторные попытки с задержками).
- **Нет проксирования у конкретного устройства.** Поток до обвязки не доходит:
  устройство не в той политике / у него свой маршрут (например, свой VPN или
  IPv6) — проверять по `ndmc -c "show ip policy"` и по conntrack.

## Ограничения

- Только IPv4: IPv6-правила для прокси здесь не создаются.
- Правила живут в собственных цепочках (`sui_tproxy_nat`, `sui_tproxy_mangle`) и
  не трогают NDM-овские `_NDM_*`, поэтому вручную добавлять в них ничего не нужно.
- Скрипт рассчитан на `iptables` (xtables-legacy). Комбинация с `nfqws2`/zapret
  допустима: обвязка выпускает «завёрнутый» трафик в WAN, DPI-обход работает на
  своих хуках PREROUTING/POSTROUTING.
- Скрипт не управляет самой панелью s-ui и её конфигом (правила, аутбаунды,
  подписки) — это задача панели.

## Лицензии

- Наши скрипты (`sui-tproxy`, init, хуки, installer) — **MIT**, см. `LICENSE`.
- s-ui — GPL-3.0 ([alireza0/s-ui](https://github.com/alireza0/s-ui)).
- s-ui-keenetic (апстримный обёрточный `s-ui.sh`) — GPLv3
  ([own-open-source/s-ui-keenetic](https://gitlab.com/own-open-source/s-ui-keenetic));
  в этот репозиторий его код не входит.

## English summary

A small, site-agnostic glue layer that makes [s-ui](https://github.com/alireza0/s-ui)
work as a **transparent proxy on Keenetic / Netcraze routers with Entware**:

- reads the NDM **policy mark** (`ndmc -c "show ip policy"`) and matches it in
  `PREROUTING` via `connmark`, so only devices inside that policy are proxied;
- builds TCP `REDIRECT` into s-ui's redirect inbound and UDP `TPROXY` into its
  tproxy inbound, with an `ipset` of reserved/private/bypass destinations that
  always stay direct;
- installs a `/opt/etc/ndm/netfilter.d/` hook plus a debounced scheduler so the
  rules survive NDM firewall rebuilds (boot, interface and policy changes);
- optional `examples/zz-public-ip-local.sh` keeps local access to a public NAT
  address local instead of sending it through the proxy;
- `bootstrap.sh` installs everything in one line on the router: Entware
  packages, the project files, the **latest s-ui binary**, then starts the panel
  and the glue and verifies the result;
- `sui-update` installs/updates the s-ui binary itself: release download
  verified against `SHA256SUMS`, backup of the previous version, automatic
  rollback if the panel does not come back, and `--check` for a dry report -
  run it on the router or over ssh.

One-line install on the router (root):

    /opt/bin/wget -qO- https://raw.githubusercontent.com/MegaVolt3/s-ui-keenetic-tproxy/main/bootstrap.sh | sh -s --

Then tune `/opt/etc/sui-tproxy/sui-tproxy.conf`. Requirements: Entware packages
`ipset`, `iptables` (plus `wget-ssl`/`curl` for downloads), a Keenetic policy
with a non-zero mark and a matching description, and s-ui inbounds on the
redirect/tproxy ports. IPv4 only.
