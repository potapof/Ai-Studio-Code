#!/usr/bin/env bash
# ============================================================================
# 05-deploy-stack.sh
# ============================================================================
# Развёртывание Docker Compose стека v2.0 (Студия программирования).
#
# Шаги:
#   1. Переход в /home/studio/studio
#   2. Проверка .env
#   3. docker compose pull
#   4. docker compose up -d
#   5. Ожидание PostgreSQL: pg_isready
#   6. Ожидание NocoDB: /api/v1/health
#   7. Ожидание Hermes: /health (на порту 8082 -> 8080 в VM)
#   8. Вывод статуса и URL'ов
#
# Usage:
#   ./05-deploy-stack.sh
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
STUDIO_DIR="/home/studio/studio"
ENV_FILE="${STUDIO_DIR}/.env"
COMPOSE_FILE="${STUDIO_DIR}/docker-compose.yml"

# Таймауты ожидания (в секундах)
WAIT_TIMEOUT_POSTGRES=120
WAIT_TIMEOUT_NOCODB=180
WAIT_TIMEOUT_HERMES=180
WAIT_INTERVAL=5

# ---------------------------------------------------------------------------
# 1. Проверка наличия директории студии
# ---------------------------------------------------------------------------
info "Проверка директории $STUDIO_DIR..."
if [ ! -d "$STUDIO_DIR" ]; then
    err "Директория $STUDIO_DIR не существует."
    err "Склонируйте репозиторий: git clone <repo> /home/studio/studio"
    exit 1
fi
ok "Директория студии найдена"

cd "$STUDIO_DIR" || { err "Не удалось перейти в $STUDIO_DIR"; exit 1; }

# ---------------------------------------------------------------------------
# 2. Проверка docker-compose.yml
# ---------------------------------------------------------------------------
info "Проверка $COMPOSE_FILE..."
if [ ! -f "$COMPOSE_FILE" ]; then
    err "docker-compose.yml не найден в $STUDIO_DIR"
    exit 1
fi
ok "docker-compose.yml найден"

# ---------------------------------------------------------------------------
# 3. Проверка .env
# ---------------------------------------------------------------------------
info "Проверка $ENV_FILE..."
if [ ! -f "$ENV_FILE" ]; then
    err ".env файл не найден в $STUDIO_DIR"
    err "Создайте .env из примера: cp examples/.env.example .env && отредактируйте значения"
    exit 1
fi
ok ".env найден"

# Проверка обязательных переменных
info "Проверка обязательных переменных в .env..."
REQUIRED_VARS=(
    "POSTGRES_USER"
    "POSTGRES_PASSWORD"
    "POSTGRES_DB"
    "POSTGRES_PORT"
)
MISSING=()
for var in "${REQUIRED_VARS[@]}"; do
    if ! grep -q "^${var}=" "$ENV_FILE" 2>/dev/null; then
        MISSING+=("$var")
    fi
done
if [ "${#MISSING[@]}" -gt 0 ]; then
    err "Отсутствуют обязательные переменные в .env: ${MISSING[*]}"
    exit 1
fi
ok "Обязательные переменные присутствуют"

# ---------------------------------------------------------------------------
# 4. Проверка Docker
# ---------------------------------------------------------------------------
info "Проверка Docker..."
if ! command -v docker >/dev/null 2>&1; then
    err "Docker не установлен. Запустите 04-install-docker.sh"
    exit 1
fi
if ! docker info >/dev/null 2>&1; then
    err "Docker daemon не запущен или нет прав. Проверьте:"
    err "  sudo systemctl status docker"
    err "  newgrp docker (или перезагрузка)"
    exit 1
fi
ok "Docker готов: $(docker --version)"

# ---------------------------------------------------------------------------
# 5. docker compose pull
# ---------------------------------------------------------------------------
info "Скачивание образов (docker compose pull)..."
# Эта операция может занять длительное время для pgvector и AGE образов
if ! docker compose pull; then
    err "docker compose pull завершился с ошибкой"
    err "Проверьте подключение к интернет и доступ к registry"
    exit 1
fi
ok "Образы скачаны"

# ---------------------------------------------------------------------------
# 6. docker compose up -d
# ---------------------------------------------------------------------------
info "Запуск Docker Compose стека v2.0 (docker compose up -d)..."
if ! docker compose up -d; then
    err "docker compose up -d завершился с ошибкой"
    err "Проверьте логи: docker compose logs"
    exit 1
fi
ok "Стек запущен"

# ---------------------------------------------------------------------------
# 7. Ожидание PostgreSQL
# ---------------------------------------------------------------------------
info "Ожидание готовности PostgreSQL (контейнер nocodb-postgres-db)..."
ELAPSED=0
while ! docker exec nocodb-postgres-db pg_isready >/dev/null 2>&1; do
    if [ "$ELAPSED" -ge "$WAIT_TIMEOUT_POSTGRES" ]; then
        err "Таймаут ожидания PostgreSQL (${WAIT_TIMEOUT_POSTGRES} сек)"
        err "Проверьте логи: docker logs nocodb-postgres-db"
        exit 1
    fi
    info "PostgreSQL ещё не готов — ждём... (${ELAPSED}/${WAIT_TIMEOUT_POSTGRES} сек)"
    sleep "$WAIT_INTERVAL"
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done
ok "PostgreSQL готов"

# ---------------------------------------------------------------------------
# 8. Ожидание NocoDB
# ---------------------------------------------------------------------------
info "Ожидание готовности NocoDB (http://localhost:8080/api/v1/health)..."
ELAPSED=0
while ! curl -sf "http://localhost:8080/api/v1/health" >/dev/null 2>&1; do
    if [ "$ELAPSED" -ge "$WAIT_TIMEOUT_NOCODB" ]; then
        err "Таймаут ожидания NocoDB (${WAIT_TIMEOUT_NOCODB} сек)"
        err "Проверьте логи: docker logs nocodb-web-ui"
        exit 1
    fi
    info "NocoDB ещё не готов — ждём... (${ELAPSED}/${WAIT_TIMEOUT_NOCODB} сек)"
    sleep "$WAIT_INTERVAL"
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done
ok "NocoDB готов (http://localhost:8080)"

# ---------------------------------------------------------------------------
# 9. Ожидание Hermes
# ---------------------------------------------------------------------------
info "Ожидание готовности Hermes (http://localhost:8082/health)..."
ELAPSED=0
while ! curl -sf "http://localhost:8082/health" >/dev/null 2>&1; do
    if [ "$ELAPSED" -ge "$WAIT_TIMEOUT_HERMES" ]; then
        err "Таймаут ожидания Hermes (${WAIT_TIMEOUT_HERMES} сек)"
        err "Проверьте логи: docker logs hermes"
        warn "Можно продолжить без Hermes — но MCP-сервер будет недоступен"
        break
    fi
    info "Hermes ещё не готов — ждём... (${ELAPSED}/${WAIT_TIMEOUT_HERMES} сек)"
    sleep "$WAIT_INTERVAL"
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if curl -sf "http://localhost:8082/health" >/dev/null 2>&1; then
    ok "Hermes готов (http://localhost:8082)"
else
    warn "Hermes не ответил за отведённое время — продолжаем"
fi

# ---------------------------------------------------------------------------
# 10. Вывод статуса и URL'ов
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Стек v2.0 развёрнут успешно"
echo "=========================================================="

info "Статус контейнеров:"
docker compose ps

echo ""
info "URL'ы сервисов:"
echo "  PostgreSQL (мозг):   localhost:5432 (через VM) или 172.20.0.30:5432"
echo "    - БД:               hermes_brain"
echo "    - Пользователь:     $(grep '^POSTGRES_USER=' "$ENV_FILE" | cut -d'=' -f2)"
echo "  NocoDB (панель):      http://localhost:8080"
echo "  Hermes (оркестратор): http://localhost:8082"
echo "  Portainer:            http://localhost:9000"
echo "  Syncthing:            http://localhost:8384"
echo "  OpenHands:            http://localhost:3000 (или как настроен)"
echo "  egress-squid:         172.20.0.100:3128"
echo ""

info "Контейнеры в сети studio-net (172.20.0.0/16):"
echo "  nocodb-postgres-db  (172.20.0.30)  — PostgreSQL 16 + pgvector + AGE"
echo "  nocodb-web-ui       (172.20.0.20)  — NocoDB (приборная панель)"
echo "  hermes              (172.20.0.10)  — оркестратор"
echo "  holix-coordinator   (172.20.0.x)   — Holix-агенты"
echo "  openhands           (172.20.0.60)  — внешний исполнитель"
echo "  portainer           (172.20.0.70)  — мониторинг"
echo "  syncthing           (172.20.0.80)  — синхронизация с Windows"
echo "  egress-squid        (172.20.0.100) — egress proxy с whitelist"
echo ""

info "Следующие шаги:"
echo "  1. Инициализируйте конвергентную БД:  ./06-init-convergent-db.sh"
echo "  2. Подключите MCP-серверы к Hermes:   ./07-bootstrap-hermes-mcp.sh"
echo "  3. (Опционально) Миграция с v1.0:     ./08-migrate-nocodb-to-postgres.sh"
echo ""

ok "Готово."
exit 0
