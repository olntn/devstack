#!/usr/bin/env bash
set -euo pipefail

export HOME="${HOME:-/home/dev}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$HOME/.cache}"
export NPM_CONFIG_CACHE="${NPM_CONFIG_CACHE:-$HOME/.npm}"
export GIT_CONFIG_GLOBAL="${GIT_CONFIG_GLOBAL:-$HOME/.config/git/config}"
export HISTFILE="${HISTFILE:-$HOME/.bash_history}"

mkdir -p \
  "$XDG_CACHE_HOME" \
  "$NPM_CONFIG_CACHE" \
  "$(dirname "$GIT_CONFIG_GLOBAL")" \
  "$HOME/.vscode-server"

# home — docker-том, при первом старте он наполняется содержимым /home/dev из
# образа. Подстраховка на случай пустого тома: подсеваем дефолтные дотфайлы из
# /etc/skel, чтобы интерактивный bash (./devstack shell) и активация mise
# (дописывается в ~/.bashrc) работали штатно.
for f in .bashrc .profile; do
  [ -f "$HOME/$f" ] || { [ -f "/etc/skel/$f" ] && cp "/etc/skel/$f" "$HOME/$f"; }
done

# --- Провижининг проекта (две фазы, по аналогии с devcontainers) ---
# Команды живут в .env (DEVSTACK_POSTCREATE / DEVSTACK_POSTSTART) — это «список
# команд подготовки окружения». Проект НЕ модифицируется: его собственные скрипты
# можно вызывать (напр. `npm ci && npx playwright install chromium`), но никаких
# devstack-файлов в репозиторий проекта не кладётся.
# Образ не знает про проект (он bind-mount, при build его нет) — поэтому провижининг
# здесь, на старте контейнера, а не в Dockerfile.
#   DEVSTACK_POSTCREATE — тяжёлая инициализация ОДИН РАЗ на жизнь тома home.
#   DEVSTACK_POSTSTART  — лёгкие идемпотентные шаги на КАЖДЫЙ старт (опционально).
DEVSTACK_STATE="$HOME/.devstack"
mkdir -p "$DEVSTACK_STATE"

run_phase() { # run_phase <имя> <команды>
  local name="$1" cmd="$2"
  echo "[devstack] ${name}: ${cmd}"
  ( cd /workspace && bash -lc "$cmd" ) 2>&1 | tee "$DEVSTACK_STATE/${name}.log"
}

# postcreate: гейт по сентинелу в томе home. Помечаем done ТОЛЬКО при успехе,
# чтобы упавшая инициализация повторилась на следующем старте.
if [ -n "${DEVSTACK_POSTCREATE:-}" ] && [ ! -f "$DEVSTACK_STATE/postcreate.done" ]; then
  if run_phase postcreate "$DEVSTACK_POSTCREATE"; then
    touch "$DEVSTACK_STATE/postcreate.done"
    echo "[devstack] postcreate: готово"
  else
    echo "[devstack] postcreate: ОШИБКА (лог: $DEVSTACK_STATE/postcreate.log)." >&2
    echo "[devstack] контейнер поднят — зайди ./devstack shell и чини; повтор на след. старте или ./devstack provision" >&2
  fi
fi

# poststart: каждый старт, не блокирует подъём контейнера при ошибке.
if [ -n "${DEVSTACK_POSTSTART:-}" ]; then
  run_phase poststart "$DEVSTACK_POSTSTART" \
    || echo "[devstack] poststart: предупреждение (лог: $DEVSTACK_STATE/poststart.log)" >&2
fi

exec "$@"
