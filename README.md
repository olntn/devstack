# devstack v6 — свободный агент в герметичном контейнере, одна команда

Сервис для запуска ИИ-агента (Claude Code, Codex, …) в изолированном
контейнере. Модель: **внутри контейнера агент свободен** (root по требованию,
ставит/пишет что угодно), **снаружи хост запечатан** — единственный мостик к
хосту это папка проекта (`/workspace`).

v6 — это **один файл**. Все шаблоны (compose, Dockerfile, entrypoint) вшиты в
него; конфигурация каждого проекта живёт в `~/.config/devstack/projects/<slug>/`.
В проект и рядом с ним **ничего не кладётся**.

## Установка (один раз)

```bash
install -Dm755 devstack ~/.local/bin/devstack
```

(если `~/.local/bin` не в PATH — добавь, либо положи в любой каталог из PATH)

## Обновление

```bash
devstack self-update            # скачать свежий файл из main и подменить себя
devstack self-update --check    # только сравнить версии
```

Скачанный файл проверяется перед заменой (shebang, версия, целостность
вшитых шаблонов, `bash -n`) и подменяется атомарно. Шаблоны проектов
перегенерируются при следующем запуске; если менялся Dockerfile — нужен
`devstack rebuild`. Другой источник (форк, своя ветка) — `--url URL` или
переменная `DEVSTACK_UPDATE_URL`; откат на старшую версию — `--force`.

Альтернатива с историей под рукой — клон плюс симлинк; тогда `self-update`
делает `git pull --ff-only` в клоне:

```bash
git clone https://github.com/olntn/devstack ~/code/devstack
ln -sf ~/code/devstack/devstack ~/.local/bin/devstack
```

## Новая машина (один раз)

```bash
devstack setup
```

Сам определяет, что стоит, и доводит до рабочего состояния выбранный путь:
пакеты, subuid/subgid, API-сокет podman, группа docker — все грабли из старых
README теперь внутри этой команды. Только посмотреть: `devstack setup --report`.
Форсировать конкретный путь: `--engine podman | podman-min | rootless-docker | docker`.

## Новый проект

```bash
cd ~/code/myapp
devstack init        # пара вопросов -> конфиг в ~/.config/devstack/projects/
devstack up          # собрать + поднять
devstack shell       # bash внутрь контейнера
```

Или без вопросов:

```bash
devstack init --claude-code --yes && devstack up
```

Адресация проекта — тремя способами:

```bash
devstack shell                  # из любого подкаталога проекта (по CWD)
devstack up myapp               # по имени стека (см. devstack list), откуда угодно
devstack -p ~/code/myapp down   # по пути, откуда угодно
```

Исключение: `root` и `logs` принимают только `-p`/CWD — их позиционные
аргументы уходят внутрь контейнера.

## Команды

| Команда | Что делает |
|---|---|
| `setup` | настроить машину (`--report` — только диагностика; в WSL2 ещё `.wslconfig` — см. «Windows (WSL2)») |
| `self-update` | обновить сам `devstack` (`--check` — только сравнить версии, `--force`, `--url`) |
| `init` | зарегистрировать проект (флаги: `--base`, `--claude-code`, `--codex`, `--playwright`, `--extra-apt`, `--postcreate`, `--mem`, `--cpus`, `--ports`, `--yes`, … — см. `devstack help`) |
| `up` / `down` / `rebuild` | поднять / остановить / пересобрать с нуля |
| `shell` | bash внутри (dev; `sudo` без пароля = root по требованию) |
| `root [cmd]` | команда/шелл под root: `devstack root apt install -y htop` |
| `check` | проверить периметр: единственный host-маунт = проект |
| `provision` | перезапустить DEVSTACK_POSTCREATE |
| `env` | открыть `.env` проекта в `$EDITOR` |
| `path` | папка состояния проекта (её открывать в VS Code) |
| `list` / `rm [--purge]` | список проектов / удалить конфиг (синоним `remove`; `--purge`: + том home и образ; сам проект не трогается) |
| `logs` / `config` / `devcontainer` | логи / итоговый compose / перегенерировать devcontainer.json |

## Как это устроено

- Шаблоны вшиты в сам `devstack` и материализуются в
  `~/.config/devstack/projects/<slug>/` (slug = имя папки + хэш пути).
  `devstack self-update` (или обновил файл сам) → шаблоны обновятся сами при
  следующем запуске; после обновления обычно нужен `devstack rebuild`.
- Всё проектное — в `.env` этой папки (`devstack env`). Compose-файлы и
  Dockerfile не правятся: они генерируются и перезаписываются.
- Home контейнера (`/home/dev`: кэши, конфиг агента, VS Code Server) — том
  движка `<stack>-home`, а НЕ папка хоста. Полный сброс: `devstack down` +
  `podman/docker volume rm <stack>-home` (или `devstack rm --purge`).

## Движки: auto выбирает по модели безопасности

`CONTAINER_ENGINE` в `.env`: `auto | docker | podman`. Порядок `auto`:

1. **rootless docker** — демон работает под твоим пользователем: UX настоящего
   docker, а root контейнера на хосте — всего лишь ты. Настройка:
   `devstack setup --engine rootless-docker` (нужен официальный репозиторий
   Docker для `docker-ce-rootless-extras`).
2. **podman** — rootless по построению, демона нет вовсе.
3. **рутовый docker** — работает, но root-демон = самый слабый периметр
   (`devstack check` предупредит).

Владение файлами в `/workspace` всегда твоё — механизм зависит от движка и
подключается автоматически:

| Движок | Механизм | Агент внутри |
|---|---|---|
| rootless podman | `userns_mode: keep-id` (оверлей) | `dev` + беспарольный sudo |
| rootless docker | контейнер под root (uid 0 -> ты) | root (это и есть твой uid; для Claude Code выставляется `IS_SANDBOX=1`) |
| рутовый docker / root-podman | `dev` создан с `HOST_UID`/`HOST_GID` | `dev` + беспарольный sudo |

### Ось compose-фронтенда (только для podman)

`COMPOSE_PROVIDER=auto | podman-compose | docker-compose`. `auto` предпочитает
**настоящий docker compose** поверх Docker-совместимого API-сокета podman
(совместимость эталонная; демон docker не используется, рантайм — podman;
сокет остаётся на хосте и в контейнер не монтируется). Откат на
`podman-compose`, если docker compose или сокет недоступны.

Накопленные грабли devstack обходит сам: баг `--in-pod` у podman-compose < 1.1.0
(bool("false") == True), несовместимость `--userns=keep-id` с pod'ами,
осиротевшие сети без метки `com.docker.compose.network` после
`podman-compose down`, автоподъём сокета. **Смена провайдера на живом стеке**:
сначала `devstack down` СТАРЫМ провайдером (учёт контейнеров у фронтендов по
разным меткам — devstack это детектит и предупреждает):

```bash
COMPOSE_PROVIDER=podman-compose devstack down   # затем обычный devstack up
```

Обе переменные можно перебить окружением на один запуск.

## Периметр (проверка: `devstack check`)

Снаружи (хост запечатан — это и есть цель):
- **единственный мостик к хосту — папка проекта** (`/workspace`, rw); плюс
  read-only `hooks/` из папки состояния (наши управляющие скрипты).
- **home — том движка**, не папка хоста (иначе был бы второй мостик).
- **не монтируется `docker.sock`/`podman.sock`** (мгновенный побег на хост),
  нет `--privileged`, нет host-namespaces, нет `host.docker.internal`.
- **порты наружу — только из `PORTS`** и по умолчанию на `127.0.0.1`
  (см. «Порты наружу»); `check` печатает список и отмечает `0.0.0.0`.
- лимиты `MEM_LIMIT`/`CPUS`/`pids` — против «убежавших» процессов, не про
  доступ. Дефолты `init` считает от машины: `MEM_LIMIT` ≈ 2/3 RAM, `CPUS` =
  ядра минус одно (явно: `--mem`, `--cpus`, потом `devstack env`). Лимит выше
  реальной памяти — бумажный (первым придёт OOM-killer хоста/VM), `check` на
  такое ругается. В rootless нужны cgroups v2 + systemd (в WSL2:
  `/etc/wsl.conf` → `[boot] systemd=true`, `.wslconfig` →
  `kernelCommandLine = cgroup_no_v1=all`, затем `wsl --shutdown`; `check` и
  `setup` подскажут, `setup` в WSL2 предложит дописать сам).
- сеть: полный интернет (агент ставит пакеты), но открытые тобой порты на
  хосте достижимы по gateway-IP — не держи чувствительные сервисы на 0.0.0.0.
- WSL2: проект держи на ext4 WSL (`~/code/...`), не на `/mnt/c` — `check`
  предупредит.

Опционально жёстче: `DEVSTACK_READONLY_ROOT=1` в `.env` — read-only корневая
ФС (рантайм-apt и `npm i -g` перестанут работать; системные пакеты — через
`EXTRA_APT` + `devstack rebuild`).

## Windows (WSL2)

devstack работает внутри дистро WSL2, а главный потребитель ресурсов на
Windows — сама VM WSL (`vmmem`): по умолчанию берёт ~50% RAM, после сборок
держит кэш страниц и не отдаёт его Windows, а vhdx дистро только растёт. Это
задаёт `%USERPROFILE%\.wslconfig` на Windows-стороне. `devstack setup` находит
его через `/mnt/c`, показывает текущие значения и предлагает дописать то, чего
нет (заданное не перезаписывает, бэкап `.wslconfig.devstack-bak` рядом):

| Ключ | Что даёт |
|---|---|
| `[wsl2] memory` | потолок VM; рекомендация — до 3/4 RAM Windows, но Windows остаётся не меньше 4 ГиБ (считается от реальной RAM через PowerShell) |
| `[wsl2] kernelCommandLine = cgroup_no_v1=all` | cgroups v2 для rootless-лимитов (вместе с `[boot] systemd=true` в `/etc/wsl.conf`) |
| `[experimental] autoMemoryReclaim=gradual` | возвращать Windows кэш страниц VM после простоя (WSL ≥ 2.0) |
| `[experimental] sparseVhd=true` | vhdx сжимается сам (WSL ≥ 2.0; уже существующий диск: `wsl --manage <дистро> --set-sparse true`) |

Применяется только после полного перезапуска: `wsl --shutdown` в PowerShell.
Только посмотреть: `devstack setup --report`. Старый WSL без `wsl --version`
(inbox-версия) ключи `[experimental]` не знает — сначала `wsl --update`.

Лимиты контейнера `init` считает от того, что видит изнутри: в WSL это память
и ядра VM, то есть реальный потолок. `devstack check` предупредит, если
`MEM_LIMIT` не меньше памяти VM — такой лимит бумажный, при нехватке первым
сработает OOM-killer VM. Проект держи на ext4 WSL (`~/code/...`), не на
`/mnt/c` — `check` предупредит.

## Порты наружу

Dev-серверы агента публикуются на хост списком `PORTS` в `.env` (или
`devstack init --ports "..."`), формы как у compose:

```ini
PORTS=3000 8080:80 3000-3010 5353:53/udp 0.0.0.0:5173:5173
```

- Без адреса публикуется на `127.0.0.1`: порт виден только с этой машины, не
  из локальной сети. В WSL2 Windows достаёт его как `localhost` через
  localhostForwarding. Наружу в LAN — только явным `0.0.0.0:…`, `check`
  отметит это как `[!]`.
- Из `PORTS` генерируется оверлей `compose.ports.yaml` в папке состояния и
  подключается в `devcontainer.json`. Поменял список — `devstack up`:
  контейнер пересоздастся, том home останется.
- Rootless: порты ниже 1024 без `sysctl net.ipv4.ip_unprivileged_port_start`
  не опубликуются — `check` предупредит.
- Это единственный путь «снаружи внутрь», и ровно по твоему списку. Общая
  сеть с хостом (`network_mode: host`) намеренно не предлагается: она открыла
  бы агенту всё, что слушает `localhost` хоста.

## Провижининг проекта

Образ намеренно не знает про проект (он bind-mount, при `build` его нет).
«Список команд подготовки» живёт в `.env`, entrypoint выполняет его на старте
в две фазы (как в devcontainers):

| Переменная | Когда | Для чего |
|---|---|---|
| `DEVSTACK_POSTCREATE` | **один раз** на жизнь тома home | `npm ci`, браузеры, сиды БД |
| `DEVSTACK_POSTSTART` | **каждый** старт | лёгкие идемпотентные шаги |

```ini
DEVSTACK_POSTCREATE=npm ci && npx playwright install chromium
```

- Несколько шагов — цепочкой через `&&` (не `;`: упавший шаг не должен
  пометиться успешным). Сентинел `~/.devstack/postcreate.done` ставится
  **только при успехе** — упавшая установка повторится на следующем старте.
- Сложная логика — в `hooks/postcreate.sh` (в папке состояния, монтируется
  read-only в `/opt/devstack/hooks`): скелет — `hooks/postcreate.sh.example`,
  вызов — `DEVSTACK_POSTCREATE=bash /opt/devstack/hooks/postcreate.sh`.
- Логи: `~/.devstack/postcreate.log`, `poststart.log`. Повтор вручную:
  `devstack provision`.

## AI-CLI

`init` спрашивает про каждый CLI отдельно (`--codex`, `--claude-code`,
`--ai "пакеты"`); смена переключателей в `.env` → `devstack rebuild`.
Оба требуют Node 22+ (`init` сам поднимет `NODE_MAJOR`, если надо). Глобальный
npm-префикс вынесен в `/usr/local/npm-global` и отдан пользователю — CLI могут
автообновляться. Авторизация — внутри контейнера при первом запуске
(`claude` / `codex`); ключи в образ не вшиваются.

Пример: codex с полным доступом, без правок проекта — в `.env`:

```ini
DEVSTACK_POSTSTART=mkdir -p ~/.codex && printf 'sandbox_mode = "danger-full-access"\napproval_policy = "never"\n' > ~/.codex/config.toml
```

## Playwright

Двухслойная модель против классической ошибки «Executable doesn't exist…»:
- **системные библиотеки** — в образе (`INSTALL_PLAYWRIGHT=1` →
  `playwright install-deps`, версионно-нейтральны);
- **бинарники браузеров** — ставит `DEVSTACK_POSTCREATE` под версию из
  lockfile проекта в персистентный том (`PLAYWRIGHT_BROWSERS_PATH` уже
  настроен). Бампнул `@playwright/test` → следующий `up` докачает нужную
  ревизию, пересборка образа не нужна.

## VS Code (Dev Containers)

Одной командой:

```bash
devstack code myapp
```

Она перегенерирует `.devcontainer/` под текущий движок, для podman сама
пропишет `dev.containers.dockerPath = podman` в User-настройки VS Code (с
бэкапом рядом; работает и в WSL — правит файл на Windows-стороне; чужое
значение не перезаписывает), предупредит о конфликте compose-фронтендов и
откроет папку в VS Code. Остаётся нажать **«Reopen in Container»** — редактор
покажет `/workspace`, то есть сам проект. Это единственный шаг, который
автоматизировать нельзя.

Важно понимать: VS Code показывает контейнеры того движка, на который
настроен. Без `dockerPath = podman` он смотрит в docker-демон и podman-стека
«не видит» — это и чинит `devstack code`.

Детали (обычно не нужны — `setup`/`code` делают это сами):
- сокет: `systemctl --user enable --now podman.socket` (именно `enable` —
  VS Code запускает compose мимо devstack);
- нужен `COMPOSE_PROVIDER=docker-compose` (auto его и выберет) — иначе стек и
  VS Code поднимают его разными фронтендами и получается конфликт меток сети;
- контейнер лучше отдать самому VS Code: `devstack down` → «Reopen in
  Container»;
- в сгенерированном devcontainer.json `"updateRemoteUserUID": false`
  обязателен (см. комментарий в самом файле);
- после смены движка: `devstack devcontainer` (перегенерирует, не трогая
  `.env`); нестандартный путь к настройкам VS Code — через переменную
  `DEVSTACK_VSCODE_SETTINGS`.

## Миграция с v5 (папка-комплект)

1. `install -Dm755 devstack ~/.local/bin/devstack`
2. Для каждого проекта: `cd проект && devstack init …` (старый `.env` из папки
   v5 можно открыть рядом и перенести значения; ключи те же).
3. Если `STACK_NAME` совпал со старым — существующие том `home` и образ
   подхватятся, provision повторно не побежит.
4. Папка v5 (compose-файлы и т.п.) больше не нужна.
