#!/usr/bin/env bash
# ============================================================================
# 07-bootstrap-hermes-mcp.sh
# ============================================================================
# НОВЫЙ скрипт v2.0 — подключение MCP-серверов к Hermes.
#
# Подключает:
#   - postgres MCP (hermes-brain) — stdio транспорт
#   - SOA MCP (stackoverflow)    — http транспорт с OAuth 2.1
#   - github MCP                  — stdio транспорт с GITHUB_PERSONAL_ACCESS_TOKEN
#   - slack MCP (если SLACK_BOT_TOKEN задан)
#   - sentry MCP (если SENTRY_DSN задан)
#
# Включает MCP-сервер Hermes (для IDE): hermes mcp server start --port 8082
#
# Usage:
#   ./07-bootstrap-hermes-mcp.sh
# ============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Цветной вывод
# ---------------------------------------------------------------------------
ok()    { echo -e "\033[32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[31m[ERROR]\033[0m $*"; }
info()  { echo -e "\033[36m[INFO]\033[0m  $*"; }

# ---------------------------------------------------------------------------
# Константы
# ---------------------------------------------------------------------------
HERMES_CONTAINER="hermes"
POSTGRES_CONTAINER="nocodb-postgres-db"
STUDIO_DIR="/home/studio/studio"
ENV_FILE="${STUDIO_DIR}/.env"
MCP_DIR="${STUDIO_DIR}/examples/mcp"

# ---------------------------------------------------------------------------
# Загрузка .env
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE" 2>/dev/null || true
    set +a
fi

POSTGRES_USER="${POSTGRES_USER:-nocodb_user}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-nocodb_password}"
GITHUB_TOKEN="${GITHUB_PERSONAL_ACCESS_TOKEN:-}"
SLACK_TOKEN="${SLACK_BOT_TOKEN:-}"
SENTRY_DSN="${SENTRY_DSN:-}"

# ---------------------------------------------------------------------------
# 1. Проверка, что Hermes запущен
# ---------------------------------------------------------------------------
info "Проверка доступности контейнера $HERMES_CONTAINER..."
if ! docker ps --format '{{.Names}}' | grep -q "^${HERMES_CONTAINER}$"; then
    err "Контейнер $HERMES_CONTAINER не запущен."
    err "Запустите стек: ./05-deploy-stack.sh"
    exit 1
fi
ok "Контейнер $HERMES_CONTAINER найден"

info "Проверка готовности Hermes (health check)..."
if ! docker exec "$HERMES_CONTAINER" curl -sf http://localhost:8080/health >/dev/null 2>&1; then
    # Пробуем через docker exec с другой командой
    if ! curl -sf http://localhost:8082/health >/dev/null 2>&1; then
        warn "Hermes не отвечает на health check."
        warn "Проверьте: docker logs $HERMES_CONTAINER"
        warn "Продолжаем настройку MCP — но возможны ошибки."
    else
        ok "Hermes готов (http://localhost:8082/health)"
    fi
else
    ok "Hermes готов"
fi

# Проверка доступности команды hermes внутри контейнера
info "Проверка команды 'hermes mcp' внутри контейнера..."
if ! docker exec "$HERMES_CONTAINER" hermes mcp --help >/dev/null 2>&1; then
    err "Команда 'hermes mcp' недоступна внутри контейнера $HERMES_CONTAINER"
    err "Проверьте образ Hermes и его конфигурацию"
    exit 1
fi
ok "Команда 'hermes mcp' доступна"

# ---------------------------------------------------------------------------
# 2. Подключение postgres MCP (hermes-brain)
# ---------------------------------------------------------------------------
info "Подключение MCP-сервера 'hermes-brain' (postgres MCP)..."

POSTGRES_URL="postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@${POSTGRES_CONTAINER}:5432/hermes_brain"

# Удаляем существующее подключение если есть (для идемпотентности)
docker exec "$HERMES_CONTAINER" hermes mcp remove hermes-brain 2>/dev/null || true

# Подключаем postgres MCP через stdio транспорт
if docker exec -e POSTGRES_URL="$POSTGRES_URL" "$HERMES_CONTAINER" \
    hermes mcp add hermes-brain --transport stdio -- \
    npx -y @modelcontextprotocol/server-postgres "$POSTGRES_URL" 2>&1; then
    ok "MCP 'hermes-brain' подключён (stdio, postgres)"
else
    err "Не удалось подключить MCP 'hermes-brain'"
    err "Проверьте: docker exec $HERMES_CONTAINER hermes mcp add --help"
    exit 1
fi

# ---------------------------------------------------------------------------
# 3. Подключение SOA MCP (Stack Overflow for Agents)
# ---------------------------------------------------------------------------
info "Подключение MCP-сервера 'stackoverflow' (SOA MCP через OAuth 2.1)..."

docker exec "$HERMES_CONTAINER" hermes mcp remove stackoverflow 2>/dev/null || true

# Подключаем SOA MCP через http транспорт
if docker exec "$HERMES_CONTAINER" \
    hermes mcp add stackoverflow --transport http --url https://mcp.stackoverflow.com 2>&1; then
    ok "MCP 'stackoverflow' подключён (http)"
    warn "При первом вызове SOA MCP откроется браузер для OAuth 2.1 авторизации."
    warn "После авторизации токен будет сохранён и последующие вызовы будут без запроса."
else
    err "Не удалось подключить MCP 'stackoverflow'"
    warn "Проверьте доступность https://mcp.stackoverflow.com и конфигурацию OAuth 2.1"
    # Не выходим — продолжаем с другими MCP
fi

# ---------------------------------------------------------------------------
# 4. Подключение GitHub MCP
# ---------------------------------------------------------------------------
info "Подключение MCP-сервера 'github'..."

if [ -z "$GITHUB_TOKEN" ]; then
    warn "GITHUB_PERSONAL_ACCESS_TOKEN не задан в .env"
    warn "GitHub MCP будет подключён, но вызовы будут завершаться с ошибкой 401."
    warn "Создайте token: https://github.com/settings/tokens (scope: repo, read:org)"
    warn "Добавьте в .env: GITHUB_PERSONAL_ACCESS_TOKEN=ghp_xxxxxxxxxxxx"
fi

docker exec "$HERMES_CONTAINER" hermes mcp remove github 2>/dev/null || true

# Подключаем GitHub MCP через stdio с env-переменной
if docker exec -e GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_TOKEN" "$HERMES_CONTAINER" \
    hermes mcp add github --transport stdio --env GITHUB_PERSONAL_ACCESS_TOKEN="$GITHUB_TOKEN" -- \
    npx -y @modelcontextprotocol/server-github 2>&1; then
    ok "MCP 'github' подключён (stdio)"
else
    warn "Не удалось подключить MCP 'github'"
    warn "Проверьте: docker exec $HERMES_CONTAINER hermes mcp add --help"
fi

# ---------------------------------------------------------------------------
# 5. Подключение Slack MCP (если SLACK_BOT_TOKEN задан)
# ---------------------------------------------------------------------------
if [ -n "$SLACK_TOKEN" ]; then
    info "Подключение MCP-сервера 'slack' (SLACK_BOT_TOKEN задан)..."

    docker exec "$HERMES_CONTAINER" hermes mcp remove slack 2>/dev/null || true

    if docker exec -e SLACK_BOT_TOKEN="$SLACK_TOKEN" "$HERMES_CONTAINER" \
        hermes mcp add slack --transport stdio --env SLACK_BOT_TOKEN="$SLACK_TOKEN" -- \
        mcp-server-slack 2>&1; then
        ok "MCP 'slack' подключён (stdio)"
    else
        warn "Не удалось подключить MCP 'slack'"
    fi
else
    info "SLACK_BOT_TOKEN не задан — Slack MCP пропускается"
    info "Для включения добавьте в .env: SLACK_BOT_TOKEN=xoxb-xxxxxxxxxxxx"
fi

# ---------------------------------------------------------------------------
# 6. Подключение Sentry MCP (если SENTRY_DSN задан)
# ---------------------------------------------------------------------------
if [ -n "$SENTRY_DSN" ]; then
    info "Подключение MCP-сервера 'sentry' (SENTRY_DSN задан)..."

    docker exec "$HERMES_CONTAINER" hermes mcp remove sentry 2>/dev/null || true

    if docker exec -e SENTRY_DSN="$SENTRY_DSN" "$HERMES_CONTAINER" \
        hermes mcp add sentry --transport stdio --env SENTRY_DSN="$SENTRY_DSN" -- \
        mcp-server-sentry 2>&1; then
        ok "MCP 'sentry' подключён (stdio)"
    else
        warn "Не удалось подключить MCP 'sentry'"
    fi
else
    info "SENTRY_DSN не задан — Sentry MCP пропускается"
    info "Для включения добавьте в .env: SENTRY_DSN=https://xxxxx@sentry.io/xxx"
fi

# ---------------------------------------------------------------------------
# 7. Проверка: hermes mcp list
# ---------------------------------------------------------------------------
info "Проверка подключённых MCP-серверов (hermes mcp list)..."
echo ""
echo "Список подключённых MCP-серверов:"
docker exec "$HERMES_CONTAINER" hermes mcp list 2>&1 || {
    warn "Не удалось получить список MCP-серверов"
}
echo ""

# ---------------------------------------------------------------------------
# 8. Тест каждого MCP
# ---------------------------------------------------------------------------
info "Тестирование MCP-серверов..."

# hermes-brain
info "Тест MCP 'hermes-brain'..."
if docker exec "$HERMES_CONTAINER" hermes mcp test hermes-brain 2>&1; then
    ok "MCP 'hermes-brain' — тест пройден"
else
    warn "MCP 'hermes-brain' — тест НЕ пройден. Проверьте подключение к PostgreSQL."
fi

# stackoverflow
info "Тест MCP 'stackoverflow'..."
if docker exec "$HERMES_CONTAINER" hermes mcp test stackoverflow 2>&1; then
    ok "MCP 'stackoverflow' — тест пройден"
else
    warn "MCP 'stackoverflow' — тест НЕ пройден."
    warn "Возможно, требуется OAuth 2.1 авторизация (откроется браузер при первом вызове)."
fi

# github (если token задан)
if [ -n "$GITHUB_TOKEN" ]; then
    info "Тест MCP 'github'..."
    if docker exec "$HERMES_CONTAINER" hermes mcp test github 2>&1; then
        ok "MCP 'github' — тест пройден"
    else
        warn "MCP 'github' — тест НЕ пройден. Проверьте GITHUB_PERSONAL_ACCESS_TOKEN."
    fi
fi

# slack (если token задан)
if [ -n "$SLACK_TOKEN" ]; then
    info "Тест MCP 'slack'..."
    if docker exec "$HERMES_CONTAINER" hermes mcp test slack 2>&1; then
        ok "MCP 'slack' — тест пройден"
    else
        warn "MCP 'slack' — тест НЕ пройден. Проверьте SLACK_BOT_TOKEN."
    fi
fi

# sentry (если DSN задан)
if [ -n "$SENTRY_DSN" ]; then
    info "Тест MCP 'sentry'..."
    if docker exec "$HERMES_CONTAINER" hermes mcp test sentry 2>&1; then
        ok "MCP 'sentry' — тест пройден"
    else
        warn "MCP 'sentry' — тест НЕ пройден. Проверьте SENTRY_DSN."
    fi
fi

# ---------------------------------------------------------------------------
# 9. Включение MCP-сервера Hermes (для IDE)
# ---------------------------------------------------------------------------
info "Включение MCP-сервера Hermes (для подключения IDE) на порту 8082..."

# Запуск MCP-сервера Hermes в фоне внутри контейнера
# --port 8082 — пробрасывается через NAT на хост:8082 -> VM:8080
docker exec -d "$HERMES_CONTAINER" hermes mcp server start --port 8082 2>&1 || {
    warn "Не удалось запустить MCP-сервер Hermes."
    warn "Возможно, он уже запущен. Проверьте: docker exec $HERMES_CONTAINER hermes mcp server status"
}

sleep 2

# Проверка, что MCP-сервер Hermes отвечает
if curl -sf http://localhost:8082/health >/dev/null 2>&1; then
    ok "MCP-сервер Hermes запущен на http://localhost:8082"
elif docker exec "$HERMES_CONTAINER" curl -sf http://localhost:8082/health >/dev/null 2>&1; then
    ok "MCP-сервер Hermes запущен внутри контейнера на порту 8082"
else
    warn "MCP-сервер Hermes не отвечает на порту 8082."
    warn "Проверьте: docker exec $HERMES_CONTAINER hermes mcp server status"
fi

# ---------------------------------------------------------------------------
# 10. Итоговая сводка
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Подключение MCP-серверов к Hermes завершено"
echo "=========================================================="

info "Подключённые MCP-серверы:"
echo "  hermes-brain    — stdio  — PostgreSQL hermes_brain (мозг)"
echo "  stackoverflow   — http   — SOA MCP (OAuth 2.1 при первом вызове)"
echo "  github          — stdio  — GitHub (если GITHUB_PERSONAL_ACCESS_TOKEN задан)"
[ -n "$SLACK_TOKEN" ]  && echo "  slack           — stdio  — Slack"
[ -n "$SENTRY_DSN" ]   && echo "  sentry          — stdio  — Sentry"
echo ""

info "Hermes MCP-сервер (для IDE): http://localhost:8082"
echo "  В VS Code / Cursor добавьте MCP-сервер:"
echo "    { \"url\": \"http://localhost:8082\" }"
echo ""

info "Управление MCP:"
echo "  Список:    docker exec $HERMES_CONTAINER hermes mcp list"
echo "  Тест:      docker exec $HERMES_CONTAINER hermes mcp test <name>"
echo "  Удалить:   docker exec $HERMES_CONTAINER hermes mcp remove <name>"
echo ""

warn "ВАЖНО: При первом вызове SOA MCP откроется браузер для OAuth 2.1."
warn "       Авторизуйтесь через Stack Overflow для получения токена."
echo ""

ok "Готово."
exit 0
