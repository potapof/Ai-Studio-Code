#!/usr/bin/env bash
# ============================================================================
# 08-migrate-nocodb-to-postgres.sh
# ============================================================================
# НОВЫЙ скрипт v2.0 — миграция с v1.0 (NocoDB как мозг) на v2.0 (PostgreSQL).
#
# Шаги:
#   1. Проверка, что старая БД studio_db существует
#   2. Backup старой БД studio_db
#   3. Выполнение examples/sql/06-migration-from-nocodb.sql
#   4. Отчёт о миграции: количество перенесённых навыков
#   5. Инструкция по отключению старых NocoDB MCP-подключений в Hermes
#   6. Перенастройка NocoDB на подключение к hermes_brain (а не к studio_db)
#   7. Проверка: NocoDB видит таблицы public.skills, public.handoff_documents
#
# Usage:
#   ./08-migrate-nocodb-to-postgres.sh
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
POSTGRES_CONTAINER="nocodb-postgres-db"
HERMES_CONTAINER="hermes"
NOCODB_CONTAINER="nocodb-web-ui"
OLD_DB_NAME="studio_db"
NEW_DB_NAME="hermes_brain"
STUDIO_DIR="/home/studio/studio"
ENV_FILE="${STUDIO_DIR}/.env"
MIGRATION_SQL="${STUDIO_DIR}/examples/sql/06-migration-from-nocodb.sql"
BACKUP_DIR="${HOME}/syncthing-host/backup"

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

# ---------------------------------------------------------------------------
# 1. Проверка, что PostgreSQL и контейнеры запущены
# ---------------------------------------------------------------------------
info "Проверка доступности контейнеров..."

for container in "$POSTGRES_CONTAINER" "$HERMES_CONTAINER" "$NOCODB_CONTAINER"; do
    if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
        err "Контейнер $container не запущен."
        err "Запустите стек: ./05-deploy-stack.sh"
        exit 1
    fi
done
ok "Все необходимые контейнеры запущены"

# Проверка готовности PostgreSQL
if ! docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
    err "PostgreSQL не готов."
    exit 1
fi
ok "PostgreSQL готов"

# ---------------------------------------------------------------------------
# 2. Проверка, что старая БД studio_db существует
# ---------------------------------------------------------------------------
info "Проверка существования старой БД '$OLD_DB_NAME'..."

OLD_DB_EXISTS=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$OLD_DB_NAME';" 2>/dev/null || echo "")

if [ "$OLD_DB_EXISTS" != "1" ]; then
    warn "Старая БД '$OLD_DB_NAME' не найдена."
    warn "Возможные причины:"
    warn "  - Миграция уже выполнена"
    warn "  - v1.0 никогда не была установлена"
    warn "  - Имя БД отличается от '$OLD_DB_NAME'"

    read -r -p "Продолжить миграцию без backup studio_db? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "Миграция отменена пользователем."
        exit 0
    fi
    SKIP_BACKUP=1
else
    ok "Старая БД '$OLD_DB_NAME' найдена"
    SKIP_BACKUP=0
fi

# ---------------------------------------------------------------------------
# 3. Проверка, что новая БД hermes_brain существует и инициализирована
# ---------------------------------------------------------------------------
info "Проверка существования новой БД '$NEW_DB_NAME'..."

NEW_DB_EXISTS=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$NEW_DB_NAME';" 2>/dev/null || echo "")

if [ "$NEW_DB_EXISTS" != "1" ]; then
    err "База данных '$NEW_DB_NAME' не существует."
    err "Сначала запустите: ./06-init-convergent-db.sh"
    exit 1
fi
ok "БД '$NEW_DB_NAME' существует"

# Проверка, что таблица skills существует в hermes_brain
SKILLS_TABLE_EXISTS=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$NEW_DB_NAME" -tAc \
    "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'skills';" 2>/dev/null || echo "")

if [ "$SKILLS_TABLE_EXISTS" != "1" ]; then
    err "Таблица 'public.skills' не найдена в '$NEW_DB_NAME'."
    err "Сначала запустите: ./06-init-convergent-db.sh"
    exit 1
fi
ok "Таблица 'public.skills' присутствует в '$NEW_DB_NAME'"

# ---------------------------------------------------------------------------
# 4. Backup старой БД studio_db
# ---------------------------------------------------------------------------
if [ "$SKIP_BACKUP" = "0" ]; then
    info "Создание backup старой БД '$OLD_DB_NAME'..."

    mkdir -p "$BACKUP_DIR" || { err "Не удалось создать $BACKUP_DIR"; exit 1; }

    BACKUP_FILE="${BACKUP_DIR}/studio_db-v1-backup-$(date +%Y-%m-%d).sql.gz"

    # pg_dumpall — для дампа всех БД и пользователей
    # Используем pg_dump конкретной БД для уменьшения размера
    info "Выполняю pg_dump БД '$OLD_DB_NAME'..."
    if docker exec "$POSTGRES_CONTAINER" \
        pg_dump -U "$POSTGRES_USER" -d "$OLD_DB_NAME" 2>/dev/null | \
        gzip > "$BACKUP_FILE"; then
        BACKUP_SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        ok "Backup создан: $BACKUP_FILE ($BACKUP_SIZE)"
    else
        err "Не удалось создать backup БД '$OLD_DB_NAME'"
        err "Прерывание миграции — без backup небезопасно продолжать."
        exit 1
    fi
else
    warn "Backup старой БД пропущен (БД не найдена)"
fi

# ---------------------------------------------------------------------------
# 5. Выполнение SQL-скрипта миграции
# ---------------------------------------------------------------------------
info "Проверка наличия SQL-скрипта миграции: $MIGRATION_SQL..."

if [ ! -f "$MIGRATION_SQL" ]; then
    err "SQL-скрипт миграции не найден: $MIGRATION_SQL"
    err "Проверьте, что репозиторий клонирован корректно."
    exit 1
fi
ok "SQL-скрипт миграции найден"

info "Выполнение SQL-скрипта миграции..."
info "(Перенос данных из '$OLD_DB_NAME' в '$NEW_DB_NAME')..."

if ! docker exec -i "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$NEW_DB_NAME" -v ON_ERROR_STOP=1 < "$MIGRATION_SQL"; then
    err "Ошибка выполнения SQL-скрипта миграции."
    err "Проверьте $MIGRATION_SQL и логи PostgreSQL."
    err "Backup старой БД доступен: $BACKUP_FILE"
    exit 1
fi
ok "SQL-скрипт миграции выполнен успешно"

# ---------------------------------------------------------------------------
# 6. Отчёт о миграции: количество перенесённых навыков
# ---------------------------------------------------------------------------
echo ""
info "Отчёт о миграции:"
echo "  БД-источник:   $OLD_DB_NAME"
echo "  БД-приёмник:   $NEW_DB_NAME"

# Количество навыков в новой БД
SKILLS_COUNT=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$NEW_DB_NAME" -tAc \
    "SELECT count(*) FROM public.skills;" 2>/dev/null || echo "0")
echo "  Навыков в public.skills:           $SKILLS_COUNT"

# Количество handoff-документов
HANDOFF_COUNT=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$NEW_DB_NAME" -tAc \
    "SELECT count(*) FROM public.handoff_documents;" 2>/dev/null || echo "0")
echo "  Документов в public.handoff_documents: $HANDOFF_COUNT"

# Количество циклов (loops)
LOOPS_COUNT=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$NEW_DB_NAME" -tAc \
    "SELECT count(*) FROM public.loops;" 2>/dev/null || echo "0")
echo "  Циклов в public.loops:             $LOOPS_COUNT"

if [ "$SKILLS_COUNT" -gt 0 ]; then
    ok "Данные успешно перенесены"
else
    warn "Количество перенесённых навыков = 0. Возможно, миграция не требуется."
fi

# ---------------------------------------------------------------------------
# 7. Инструкция по отключению старых NocoDB MCP-подключений в Hermes
# ---------------------------------------------------------------------------
info "Отключение старых NocoDB MCP-подключений в Hermes..."

# Проверяем, есть ли подключение 'nocodb-mcp' в Hermes
OLD_MCP_EXISTS=$(docker exec "$HERMES_CONTAINER" \
    hermes mcp list 2>/dev/null | grep -c "nocodb-mcp" || echo "0")

if [ "$OLD_MCP_EXISTS" -gt 0 ]; then
    info "Найдено старое MCP-подключение 'nocodb-mcp'. Удаляю..."
    if docker exec "$HERMES_CONTAINER" hermes mcp remove nocodb-mcp 2>&1; then
        ok "Старое MCP-подключение 'nocodb-mcp' удалено"
    else
        warn "Не удалось удалить 'nocodb-mcp' автоматически. Удалите вручную:"
        warn "  docker exec $HERMES_CONTAINER hermes mcp remove nocodb-mcp"
    fi
else
    info "Старое MCP-подключение 'nocodb-mcp' не найдено — пропуск"
fi

# Также удаляем возможные варианты имени
for old_name in "nocodb" "nocodb-mcp-server" "studio-mcp"; do
    if docker exec "$HERMES_CONTAINER" hermes mcp list 2>/dev/null | grep -q "$old_name"; then
        info "Удаление старого MCP-подключения '$old_name'..."
        docker exec "$HERMES_CONTAINER" hermes mcp remove "$old_name" 2>/dev/null || true
    fi
done

# ---------------------------------------------------------------------------
# 8. Перенастройка NocoDB на подключение к hermes_brain
# ---------------------------------------------------------------------------
info "Перенастройка NocoDB на подключение к '$NEW_DB_NAME'..."

# Читаем текущее значение NC_DB из docker-compose.yml
COMPOSE_FILE="${STUDIO_DIR}/docker-compose.yml"

if [ ! -f "$COMPOSE_FILE" ]; then
    err "docker-compose.yml не найден: $COMPOSE_FILE"
    err "Перенастройте NocoDB вручную."
    exit 1
fi

# Проверка текущего значения NC_DB
CURRENT_NC_DB=$(grep -E "^\s*NC_DB" "$COMPOSE_FILE" 2>/dev/null | head -n1 || echo "")
info "Текущее значение NC_DB в docker-compose.yml: $CURRENT_NC_DB"

if echo "$CURRENT_NC_DB" | grep -q "$OLD_DB_NAME"; then
    warn "NocoDB подключена к старой БД '$OLD_DB_NAME'. Требуется перенастройка."
    info "Обновляю NC_DB в docker-compose.yml..."

    # Backup docker-compose.yml
    cp "$COMPOSE_FILE" "${COMPOSE_FILE}.bak.$(date +%Y%m%d-%H%M%S)"

    # Заменяем studio_db на hermes_brain в строке NC_DB
    # sudo: docker-compose.yml может принадлежать root или studio-пользователю
    if [ -w "$COMPOSE_FILE" ]; then
        sed -i "s|${OLD_DB_NAME}|${NEW_DB_NAME}|g" "$COMPOSE_FILE"
        ok "NC_DB обновлён в docker-compose.yml"
    else
        sudo sed -i "s|${OLD_DB_NAME}|${NEW_DB_NAME}|g" "$COMPOSE_FILE" || {
            warn "Не удалось обновить docker-compose.yml автоматически."
            warn "Отредактируйте вручную: замените $OLD_DB_NAME на $NEW_DB_NAME в NC_DB"
        }
    fi

    # Пересоздание контейнера NocoDB
    info "Пересоздание контейнера NocoDB..."
    cd "$STUDIO_DIR" || { err "Не удалось перейти в $STUDIO_DIR"; exit 1; }
    if docker compose up -d "$NOCODB_CONTAINER" --force-recreate; then
        ok "Контейнер NocoDB пересоздан"
    else
        err "Не удалось пересоздать контейнер NocoDB"
        err "Проверьте: docker compose logs $NOCODB_CONTAINER"
        exit 1
    fi
else
    info "NocoDB уже подключена к корректной БД или NC_DB не содержит '$OLD_DB_NAME'"
    info "Если NocoDB не видит таблицы, проверьте настройку подключения в UI: http://localhost:8080"
fi

# ---------------------------------------------------------------------------
# 9. Проверка: NocoDB видит таблицы public.skills, public.handoff_documents
# ---------------------------------------------------------------------------
info "Ожидание запуска NocoDB (15 секунд)..."
sleep 15

info "Проверка доступности NocoDB API..."
for i in 1 2 3 4 5 6; do
    if curl -sf http://localhost:8080/api/v1/health >/dev/null 2>&1; then
        ok "NocoDB отвечает"
        break
    fi
    info "Попытка $i: NocoDB ещё не готова..."
    sleep 5
done

info "Проверка таблиц через NocoDB API..."

# Получаем список проектов через NocoDB API (если есть API-токен)
NOCODB_API_TOKEN="${NOCODB_API_TOKEN:-}"

if [ -n "$NOCODB_API_TOKEN" ]; then
    info "Получение списка баз через NocoDB API..."
    PROJECTS=$(curl -sf -H "xc-token: $NOCODB_API_TOKEN" \
        http://localhost:8080/api/v2/meta/projects 2>/dev/null || echo "")

    if echo "$PROJECTS" | jq -e '.list' >/dev/null 2>&1; then
        info "Проекты NocoDB:"
        echo "$PROJECTS" | jq -r '.list[].title' 2>/dev/null | head -n20
    else
        warn "Не удалось получить список проектов через API"
    fi
else
    warn "NOCODB_API_TOKEN не задан — пропускаем API-проверку"
    warn "Проверьте вручную в UI: http://localhost:8080"
fi

# Прямая проверка через PostgreSQL — NocoDB использует ту же БД
info "Проверка таблиц через PostgreSQL (NocoDB использует ту же БД):"
docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$NEW_DB_NAME" -c \
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'public' AND table_name IN ('skills', 'handoff_documents', 'loops') ORDER BY table_name;"

# ---------------------------------------------------------------------------
# 10. Итоговая сводка
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Миграция v1.0 -> v2.0 завершена"
echo "=========================================================="
info "Перенесено данных:"
echo "  Навыков:           $SKILLS_COUNT"
echo "  Handoff-документов: $HANDOFF_COUNT"
echo "  Циклов:            $LOOPS_COUNT"
info "Backup:"
if [ "$SKIP_BACKUP" = "0" ]; then
    echo "  Файл: $BACKUP_FILE"
    echo "  Размер: $(du -h "$BACKUP_FILE" | cut -f1)"
else
    echo "  Пропущен (старая БД не найдена)"
fi
info "Действия с MCP:"
echo "  Старое 'nocodb-mcp' подключение удалено (если было)"
echo "  Подключите новый MCP 'hermes-brain': ./07-bootstrap-hermes-mcp.sh"
info "NocoDB:"
echo "  URL: http://localhost:8080"
echo "  БД:  $NEW_DB_NAME (через переменную NC_DB)"
echo ""
info "Следующие шаги:"
echo "  1. Если не подключали MCP: ./07-bootstrap-hermes-mcp.sh"
echo "  2. Проверьте NocoDB UI:    http://localhost:8080"
echo "  3. Проверьте Hermes:        docker exec $HERMES_CONTAINER hermes mcp list"
echo "  4. Создайте backup:         ./backup.sh"
echo ""

ok "Готово."
exit 0
