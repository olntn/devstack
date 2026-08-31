# devstack v5 — свободный агент в герметичном контейнере

Один комплект файлов на все проекты. Под проект меняется **только `.env`**
(его генерирует `./devstack init`). Модель: **внутри контейнера агент свободен**
(пользователь dev с беспарольным sudo — root по требованию, ставит/пишет что
угодно), **снаружи хост запечатан** — единственный мостик к хосту это папка
проекта (`/workspace`).

## Файлы
| Файл | Роль | Правится под проект? |
|---|---|---|
| `compose.yaml` | сервис, сеть, том home, лимиты | нет |
| `compose.isolate.yaml` | read-only root + tmpfs (ОПЦ., off by default) | нет |
| `compose.podman.yaml` | rootless podman: keep-id (подключается сам) | нет |
| `Dockerfile` | база + Node + sudo + опц. AI-CLI (codex / claude-code) | нет |
| `entrypoint.sh` | подготовка HOME + хук проекта | нет |
| `devstack` | генератор `.env` + обёртка compose | нет |
| `.devcontainer/devcontainer.json` | интеграция с VS Code | нет |
| `.env` | всё проектное | **да** (генерируется) |

## Что установить
Хосту нужен только bash и ОДИН из движков. Сам `./devstack` зависимостей не
имеет. Ставить оба движка не нужно — выбери один.

**Podman (по умолчанию в `auto`)** — Debian/Ubuntu:
```bash
sudo apt install podman podman-compose uidmap
```
- `podman-compose` — **отдельный пакет**, `apt install podman` его НЕ тянет.
  Без него `./devstack up` не работает; `./devstack init` предупреждает сразу.
- `uidmap` даёт `newuidmap`/`newgidmap` — без них rootless не стартует вообще.
  Проверить, что диапазоны выданы: `grep "^$USER:" /etc/subuid /etc/subgid`
  (пусто -> `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 $USER`).
- версия `podman-compose` из apt (1.0.6) годится: её баг с `--in-pod`
  `./devstack` обходит сам (см. «Docker или Podman»). Новее — `pipx install
  podman-compose`.

**Docker** — Debian/Ubuntu:
```bash
sudo apt install docker.io docker-compose-v2
sudo usermod -aG docker "$USER"   # затем перелогиниться (или: newgrp docker)
```
- нужен именно compose **v2** (подкоманда `docker compose`), а не старый
  `docker-compose`. Пакет `docker-compose-v2` у `docker.io` стоит лишь в
  `Suggests` — apt его сам НЕ поставит. Проверка: `docker compose version`.
- без `usermod -aG docker` каждый вызов упрётся в права на сокет.
- официальный репозиторий Docker вместо `docker.io`: пакеты `docker-ce`,
  `docker-ce-cli`, `containerd.io`, `docker-compose-plugin`.

**WSL2**: ни Docker Desktop, ни `podman machine` не нужны — оба движка работают
нативно внутри дистро. Для лимитов `MEM_LIMIT`/`CPUS` в rootless podman
дополнительно нужны cgroups v2 + systemd (см. «Docker или Podman»).

Проверить, что всё сошлось: `./devstack init` покажет, какие движки найдены, а
`./devstack check` — периметр уже поднятого стека.

## Старт
```bash
./devstack init        # ответить на пару вопросов -> создаст .env
./devstack up          # собрать + поднять
./devstack check       # проверить периметр: единственный host-маунт = проект
./devstack shell       # bash внутри (dev; `sudo` без пароля = root по требованию)
./devstack provision   # перезапустить инициализацию проекта (см. ниже)
./devstack down        # остановить
```
Или без вопросов:
```bash
./devstack init --project ~/code/myapp --base node:22-bookworm-slim --node 0 --yes
```

## Docker или Podman
`./devstack init` спрашивает движок отдельным пунктом (и показывает, что реально
стоит на машине); без вопросов — флаг `--engine auto|docker|podman`. Значение
попадает в `.env` как `CONTAINER_ENGINE` (auto = podman, если он установлен,
иначе docker). Compose-файлы общие; вся разница спрятана в `./devstack`.
Podman идёт первым осознанно — из-за rootless (см. ниже); если при обоих
установленных нужен именно docker, ставь `CONTAINER_ENGINE=docker`.

Podman-путь (что ставить — см. «Что установить»):
- **rootless — главная причина миграции**: докеровский демон работает под
  root, и root в контейнере == root на хосте (одна дырка в периметре — и всё).
  В rootless podman демона нет вовсе, а «root» контейнера на хосте — всего лишь
  твой пользователь. Аргумент «docker всё запускает через root» закрыт по
  построению.
- devstack сам подключает `compose.podman.yaml` при rootless: `keep-id`
  отображает пользователя `dev` в ТЕБЯ, так что файлы в `/workspace` остаются
  твоими (без keep-id владельцем был бы subuid 100000+).
- лимиты `MEM_LIMIT`/`CPUS`/`pids` в rootless работают только на cgroups v2 +
  systemd. В WSL2: `/etc/wsl.conf` -> `[boot] systemd=true`, в `.wslconfig` ->
  `kernelCommandLine = cgroup_no_v1=all`, затем `wsl --shutdown`.
  `./devstack check` проверяет и подсказывает сам.
- rootless-контейнеры живут в твоей user-сессии: после `wsl --shutdown`
  просто снова `./devstack up`.
- pod'ы намеренно НЕ используются: podman не принимает `--userns=keep-id`
  вместе с `--pod` («--userns and --pod cannot be set together»), а сервис у нас
  один. `./devstack` сам выключает pod с учётом версии podman-compose: до 1.1.0
  флаг `--in-pod` объявлен как `type=bool`, и `--in-pod false` из-за
  `bool("false") == True` в Python pod как раз ВКЛЮЧАЕТ — там флаг не
  передаётся вовсе.
- миграция с docker: `CONTAINER_ENGINE=podman` в `.env`, затем
  `./devstack rebuild`. Том `home` создастся заново (это подманский том, не
  докерский) — postcreate отработает ещё раз сам.
- devcontainer: в VS Code укажи в настройках Dev Containers пути
  `dev.containers.dockerPath=podman` и `dockerComposePath=podman-compose`.

## Где лежит home
Home контейнера (`/home/dev`: VS Code Server, кэши, история, конфиг агента, mise)
— это том движка `${STACK_NAME}-home`, а НЕ папка хоста. Так агент видит его
только в `/home/dev` и не может через него добраться до других путей хоста.
Полный сброс состояния: `./devstack down` + `docker volume rm ${STACK_NAME}-home`
(на podman: `podman volume rm ${STACK_NAME}-home`).

## Провижининг проекта (универсальный механизм)
Образ намеренно НЕ знает про конкретный проект: проект — это bind-mount, во время
`docker build` его ещё нет, поэтому `npm install` и подобное в Dockerfile невозможны.
Поэтому «список команд подготовки окружения» живёт в **`.env`** (единственный
проектный файл — сам проект НЕ модифицируется), а entrypoint выполняет их на старте
контейнера в две фазы (как в devcontainers):

| Переменная .env | Когда | Для чего |
|---|---|---|
| `DEVSTACK_POSTCREATE` | **один раз** на жизнь тома `home` | тяжёлая инициализация: `npm ci`, браузеры, сиды БД |
| `DEVSTACK_POSTSTART` | **каждый** старт (опц.) | лёгкие идемпотентные шаги, запуск фоновых сервисов |

```ini
# .env — это и есть «список команд сборки окружения» (цепочка через &&):
DEVSTACK_POSTCREATE=npm ci && npx playwright install chromium
DEVSTACK_POSTSTART=
```
- **Несколько шагов** — цепочкой через `&&` (именно `&&`, не `;`: упавший шаг
  не должен пометиться как успешный). Можно звать собственные скрипты проекта
  (`npm run i_all`) — это не модификация проекта.
- **Много шагов / сложная логика** — вынеси в `hooks/postcreate.sh` (лежит рядом
  с `.env` в папке devstack, монтируется в `/opt/devstack/hooks:ro`, проект не
  трогаем) и зови его из переменной:
  ```ini
  DEVSTACK_POSTCREATE=bash /opt/devstack/hooks/postcreate.sh
  ```
  Скелет — в `hooks/postcreate.sh.example` (создаётся при `init`).
- `DEVSTACK_POSTCREATE` помечается выполненным сентинелом `~/.devstack/postcreate.done`
  в томе **только при успехе** — упавшая установка повторится на след. старте.
- Логи: `~/.devstack/postcreate.log`, `~/.devstack/poststart.log`.
- Перезапустить инициализацию вручную: `./devstack provision`.
- Полный сброс (с нуля): `./devstack down` + `docker/podman volume rm ${STACK_NAME}-home`.

## Ничего проектного в комплекте нет
Имена image/container/тома/сети выводятся из `STACK_NAME`, тулчейн и системные
пакеты — из `BASE_IMAGE` / `EXTRA_APT` / `NODE_MAJOR`, конфиги AI-CLI (напр.
`~/.codex/config.toml`) генерируются на старте через `DEVSTACK_POSTSTART`.
Всё это живёт в `.env`, который создаёт `./devstack init`.

## AI-CLI: отдельные чекбоксы (v5)
`./devstack init` спрашивает про каждый CLI отдельно; можно оба, один или ни одного.
| `.env` | Пакет | Команда внутри | Флаг init |
|---|---|---|---|
| `INSTALL_CODEX=1` | `@openai/codex` | `codex` | `--codex` |
| `INSTALL_CLAUDE_CODE=1` | `@anthropic-ai/claude-code` | `claude` | `--claude-code` |
| `AI_CLI_NPM=...` | любые доп. npm-пакеты | — | `--ai "..."` |

```bash
./devstack init --project ~/code/myapp --codex --claude-code --yes
./devstack rebuild        # после смены переключателей в .env
```
Оба CLI ставятся npm-путём и официально требуют **Node.js 22+** (пакеты тянут
нативный бинарник, который сам Node в рантайме не использует). `init` это
проверяет: если выбран CLI, а Node в образе не будет, он поднимет `NODE_MAJOR`
до 22 и предупредит; сборка с AI-CLI без npm падает с внятной ошибкой, а не молча.
Глобальный npm-префикс вынесен в `/usr/local/npm-global` и отдан пользователю
`dev`, чтобы CLI могли
автообновляться (при root-овладении префиксом автообновление не проходит).
Авторизация — внутри контейнера при первом запуске (`codex` / `claude`); ключи
и токены в образ не вшиваются.

## Пример: codex с полным доступом (без правок проекта)
В `.env` одной строкой через `DEVSTACK_POSTSTART`:
```ini
DEVSTACK_POSTSTART=mkdir -p ~/.codex && printf 'sandbox_mode = "danger-full-access"\napproval_policy = "never"\n' > ~/.codex/config.toml
```

## Playwright (браузеры без боли с версиями)
Браузеры Playwright **не вшиваются в образ** — иначе их ревизия лочится тегом
базового образа и расходится с версией `@playwright/test` в проекте (классическая
ошибка «Executable doesn't exist… update docker image as well»).

Модель разнесена на два слоя:
- **Системные библиотеки браузеров** — в образе (`INSTALL_PLAYWRIGHT=1` →
  `playwright install-deps`, под root, версионно-нейтральны).
- **Бинарники браузеров** — ставит провижининг под версию из lockfile, в
  персистентный том. Путь задан в `compose.yaml`:
  `PLAYWRIGHT_BROWSERS_PATH=/home/dev/.cache/ms-playwright` (том `home`).

Установка — через `DEVSTACK_POSTCREATE` в `.env` (install идемпотентен, no-op если
ревизия из lockfile уже в томе):
```ini
DEVSTACK_POSTCREATE=npm ci && npx playwright install chromium
```
Итог: бампнул `@playwright/test` → следующий `./devstack up` сам докачает нужную
ревизию. Пересборка образа и подгон тега базового образа не нужны.

Песочница chromium: с дефолтным набором capabilities (мы больше не делаем
`cap_drop: ALL`) chromium-sandbox работает штатно на большинстве ядер, включая
WSL2 — ничего настраивать не нужно. Если на твоём ядре песочница не поднимается —
вешай на сервис `dev` seccomp-профиль chrome через `security_opt`. Это решается на
стороне devstack, проект не трогаем.

## Модель: свободный агент, герметичный хост
Внутри — максимум свободы; граница только по периметру. Проверка: `./devstack check`.

Внутри контейнера (свобода):
- пользователь `dev` (= твой host-UID, чтобы файлы в `/workspace` были твои) с
  **беспарольным sudo** — фактически root по требованию (`sudo …` или `sudo -i`).
- корневая ФС записываемая, рантайм-`apt`/`npm i -g`/что угодно работают.
- `mise` для тулчейнов без пересборки — по-прежнему удобно (`.env.example`).

Снаружи (хост запечатан — это и есть цель):
- **единственный мостик к хосту — папка проекта** (`/workspace`, rw). Выйти из
  неё в другие пути хоста нельзя: bind отдаёт только это поддерево.
- **home — том движка**, а не папка хоста (иначе был бы второй мостик).
- **не монтируется `docker.sock`/`podman.sock`** (это был бы мгновенный root/побег на хосте),
  **нет `--privileged`**, **нет host-namespaces** (`pid/ipc/net/userns: host`),
  **не добавляем `host.docker.internal`**.
- лимиты `mem/cpus/pids` — только против «убежавших» процессов, не про доступ.

Опционально жёстче: `DEVSTACK_READONLY_ROOT=1` (read-only корневая ФС) —
сужает свободу агента, включай прицельно.
