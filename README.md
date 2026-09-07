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
| `setup` | настроить машину (`--report` — только диагностика) |
| `init` | зарегистрировать проект (флаги: `--base`, `--claude-code`, `--codex`, `--playwright`, `--extra-apt`, `--postcreate`, `--yes`, … — см. `devstack help`) |
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
  Обновил `devstack` в `~/.local/bin` → шаблоны обновятся сами при следующем
  запуске (по версии; после обновления обычно нужен `devstack rebuild`).
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
- лимиты `MEM_LIMIT`/`CPUS`/`pids` — против «убежавших» процессов, не про
  доступ. В rootless нужны cgroups v2 + systemd (в WSL2: `/etc/wsl.conf` →
  `[boot] systemd=true`, `.wslconfig` → `kernelCommandLine = cgroup_no_v1=all`,
  затем `wsl --shutdown`; `check` и `setup` подскажут).
- сеть: полный интернет (агент ставит пакеты), но открытые тобой порты на
  хосте достижимы по gateway-IP — не держи чувствительные сервисы на 0.0.0.0.
- WSL2: проект держи на ext4 WSL (`~/code/...`), не на `/mnt/c` — `check`
  предупредит.

Опционально жёстче: `DEVSTACK_READONLY_ROOT=1` в `.env` — read-only корневая
ФС (рантайм-apt и `npm i -g` перестанут работать; системные пакеты — через
`EXTRA_APT` + `devstack rebuild`).

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
