# syntax=docker/dockerfile:1

# Базовый образ задаётся через .env (BASE_IMAGE). Примеры:
#   eclipse-temurin:25-jdk-noble   (Java)
#   ubuntu:24.04                   (чистый)
#   python:3.12-bookworm           (Python)
#   golang:1.22-bookworm           (Go)
ARG BASE_IMAGE=eclipse-temurin:25-jdk-noble
FROM ${BASE_IMAGE}

ARG HOST_UID=1000
ARG HOST_GID=1000
ARG NODE_MAJOR=22
ARG EXTRA_APT=""
# Отдельные переключатели AI-CLI (v5). AI_CLI_NPM — доп. npm-пакеты сверх этих.
ARG INSTALL_CODEX=0
ARG INSTALL_CLAUDE_CODE=0
ARG AI_CLI_NPM=""
ARG INSTALL_PLAYWRIGHT=0

ENV HOME="/home/dev" \
    XDG_CACHE_HOME="/home/dev/.cache" \
    NPM_CONFIG_CACHE="/home/dev/.npm" \
    GIT_CONFIG_GLOBAL="/home/dev/.config/git/config" \
    HISTFILE="/home/dev/.bash_history" \
    DEBIAN_FRONTEND=noninteractive \
    NPM_CONFIG_PREFIX="/usr/local/npm-global"
ENV PATH="/usr/local/npm-global/bin:${PATH}"

WORKDIR /workspace

# --- Базовый инструментарий (всегда) + Node из NodeSource ---
# Node ставится по умолчанию, потому что почти все AI-CLI (codex, claude-code,
# gemini-cli и т.п.) ставятся через npm. Не нужен Node — поставь NODE_MAJOR=0.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg bash git openssh-client sudo \
        build-essential python3 python3-pip \
        procps iproute2 dnsutils nano vim; \
    if [ "${NODE_MAJOR}" != "0" ]; then \
        mkdir -p /etc/apt/keyrings; \
        curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg; \
        echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
            > /etc/apt/sources.list.d/nodesource.list; \
        apt-get update; \
        apt-get install -y --no-install-recommends nodejs; \
        node --version; npm --version; \
    fi; \
    rm -rf /var/lib/apt/lists/*

# --- Доп. apt-пакеты проекта (опционально, из EXTRA_APT) ---
# Сюда уходит всё системное, что нужно конкретному проекту, например:
#   postgresql-client redis-tools imagemagick
RUN set -eux; \
    if [ -n "${EXTRA_APT}" ]; then \
        apt-get update; \
        apt-get install -y --no-install-recommends ${EXTRA_APT}; \
        rm -rf /var/lib/apt/lists/*; \
    fi

# --- AI-CLI (отдельные переключатели) + системные зависимости Playwright ---
# INSTALL_CODEX / INSTALL_CLAUDE_CODE — независимые чекбоксы (1/0).
#   codex        -> npm i -g @openai/codex@latest          (бинарь: codex)
#   claude-code  -> npm i -g @anthropic-ai/claude-code@latest (бинарь: claude)
# Оба ставятся npm-путём и официально требуют Node.js 22+ (оба пакета тянут
# нативный бинарник, который сам Node в рантайме не использует). Поэтому здесь
# явная проверка: нет npm — падаем с понятным сообщением, а не молча.
# AI_CLI_NPM — любые ДОП. npm-пакеты сверх этих двух (напр. @google/gemini-cli).
#
# Playwright: тут ставим ТОЛЬКО системные apt-зависимости браузеров (нужен root,
# версионно-нейтральны). Сами бинарники браузеров НЕ вшиваем в образ — их ставит
# провижининг (DEVSTACK_POSTCREATE в .env) строго под версию @playwright/test из
# lockfile проекта, в персистентный том (PLAYWRIGHT_BROWSERS_PATH из compose.yaml).
# Так смена версии playwright в проекте не требует пересборки образа.
RUN set -eux; \
    if [ "${INSTALL_CODEX}" = "1" ] || [ "${INSTALL_CLAUDE_CODE}" = "1" ] || [ -n "${AI_CLI_NPM}" ]; then \
        command -v npm >/dev/null 2>&1 || { \
            echo "ОШИБКА: выбран AI-CLI, но в образе нет npm."; \
            echo "Поставь NODE_MAJOR=22 (или новее) либо возьми base node:22-bookworm-slim."; \
            exit 1; }; \
    fi; \
    if [ "${INSTALL_CODEX}" = "1" ]; then \
        npm i -g @openai/codex@latest; \
        codex --version || true; \
    fi; \
    if [ "${INSTALL_CLAUDE_CODE}" = "1" ]; then \
        npm i -g @anthropic-ai/claude-code@latest; \
        claude --version || true; \
    fi; \
    if [ -n "${AI_CLI_NPM}" ]; then \
        npm i -g ${AI_CLI_NPM}; \
    fi; \
    if [ "${INSTALL_PLAYWRIGHT}" = "1" ]; then \
        npx -y playwright@latest install-deps chromium; \
    fi; \
    rm -rf /var/lib/apt/lists/* || true

# --- Пользователь dev (UID/GID хоста) + БЕСПАРОЛЬНЫЙ sudo ---
# free-agent: внутри контейнера агент свободен. dev = твой host-UID (чистое
# владение файлами в /workspace), а sudo даёт полный root внутри по требованию
# (apt, любые изменения в рантайме). Это БЕЗОПАСНО для хоста, пока снаружи нет
# мостиков (docker.sock, --privileged, host-namespaces) — см. compose.yaml.
RUN set -eux; \
    if ! getent group "${HOST_GID}" >/dev/null; then groupadd -o -g "${HOST_GID}" dev; fi; \
    if id -u dev >/dev/null 2>&1; then \
        usermod -o -u "${HOST_UID}" -g "${HOST_GID}" -d /home/dev -m -s /bin/bash dev; \
    else \
        useradd -o -u "${HOST_UID}" -g "${HOST_GID}" -d /home/dev -m -s /bin/bash dev; \
    fi; \
    echo 'dev ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/dev; \
    chmod 440 /etc/sudoers.d/dev; \
    mkdir -p /workspace /home/dev/.cache /home/dev/.npm /home/dev/.config/git /home/dev/.vscode-server \
             /usr/local/npm-global/bin /usr/local/npm-global/lib /etc/profile.d; \
    chown -R "${HOST_UID}:${HOST_GID}" /workspace /home/dev; \
    # Глобальный npm-префикс вынесен в /usr/local/npm-global (NPM_CONFIG_PREFIX
    # выше) и отдан dev: codex/claude-code автообновляются от имени пользователя,
    # а при root-овладении префиксом обновление молча не проходит (Claude Code
    # показывает уведомление при старте). dev и так имеет sudo, так что периметр
    # это не ослабляет.
    # ВАЖНО: раньше здесь был chown на "$(npm prefix -g)/bin". Для баз, где Node
    # ставится из NodeSource, префикс = /usr, то есть chown -R прилетал на весь
    # /usr/bin и снимал setuid с sudo — вся модель «root по требованию» ложилась.
    chown -R "${HOST_UID}:${HOST_GID}" /usr/local/npm-global; \
    # Логин-шелл (bash -lc в entrypoint/provision) пересобирает PATH в /etc/profile,
    # поэтому префикс возвращаем через profile.d — иначе claude/codex не найдутся.
    printf '%s\n' 'export PATH="/usr/local/npm-global/bin:$PATH"' \
        > /etc/profile.d/npm-global.sh; \
    chmod 644 /etc/profile.d/npm-global.sh

COPY entrypoint.sh /usr/local/bin/devstack-entrypoint
RUN chmod +x /usr/local/bin/devstack-entrypoint

USER dev
ENTRYPOINT ["devstack-entrypoint"]
CMD ["sleep", "infinity"]
