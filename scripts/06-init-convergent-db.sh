#!/usr/bin/env bash
# ============================================================================
# 06-init-convergent-db.sh
# ============================================================================
# НОВЫЙ скрипт v2.0 — инициализация конвергентной БД hermes_brain.
# ЗАМЕНА 06-init-nocodb.sh из v1.0.
#
# Шаги:
#   1. Проверка, что PostgreSQL запущен
#   2. Создание БД hermes_brain если не существует
#   3. Установка расширений: vector, age, pg_trgm, pgcrypto + создание графов AGE
#   4. Выполнение SQL-скриптов по порядку из /home/studio/studio/examples/sql/
#   5. Создание тестового тенанта 'default'
#   6. Вывод проверок: таблицы, графы, расширения
#
# Usage:
#   ./06-init-convergent-db.sh
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
DB_NAME="hermes_brain"
STUDIO_DIR="/home/studio/studio"
SQL_DIR="${STUDIO_DIR}/examples/sql"
ENV_FILE="${STUDIO_DIR}/.env"

# ---------------------------------------------------------------------------
# Загрузка .env
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    # Безопасная загрузка .env
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE" 2>/dev/null || true
    set +a
fi

POSTGRES_USER="${POSTGRES_USER:-nocodb_user}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-nocodb_password}"

if [ -z "${POSTGRES_PASSWORD:-}" ]; then
    err "POSTGRES_PASSWORD не задан в $ENV_FILE"
    exit 1
fi

# ---------------------------------------------------------------------------
# 1. Проверка, что PostgreSQL запущен
# ---------------------------------------------------------------------------
info "Проверка доступности контейнера $POSTGRES_CONTAINER..."
if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    err "Контейнер $POSTGRES_CONTAINER не запущен."
    err "Запустите стек: ./05-deploy-stack.sh"
    exit 1
fi
ok "Контейнер $POSTGRES_CONTAINER найден"

info "Проверка готовности PostgreSQL (pg_isready)..."
if ! docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
    err "PostgreSQL не готов. Проверьте: docker exec $POSTGRES_CONTAINER pg_isready"
    exit 1
fi
ok "PostgreSQL готов"

# ---------------------------------------------------------------------------
# 2. Создание БД hermes_brain если не существует
# ---------------------------------------------------------------------------
info "Проверка существования базы данных '$DB_NAME'..."

DB_EXISTS=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres -tAc \
    "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME';" 2>/dev/null || echo "")

if [ "$DB_EXISTS" = "1" ]; then
    info "База данных '$DB_NAME' уже существует — пропуск создания"
else
    info "Создание базы данных '$DB_NAME'..."
    docker exec "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d postgres \
        -c "CREATE DATABASE $DB_NAME;" || { err "Не удалось создать базу данных $DB_NAME"; exit 1; }
    ok "База данных '$DB_NAME' создана"
fi

# ---------------------------------------------------------------------------
# 3. Установка расширений в hermes_brain
# ---------------------------------------------------------------------------
info "Установка расширений в '$DB_NAME'..."

# pgvector, age, pg_trgm, pgcrypto + создание графов AGE
docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" <<'SQL' || { err "Не удалось установить расширения"; exit 1; }
-- pgvector: векторные Embeddings
CREATE EXTENSION IF NOT EXISTS vector;

-- Apache AGE: графовая БД
CREATE EXTENSION IF NOT EXISTS age;

-- Загрузка AGE в текущую сессию
LOAD 'age';

-- Путь поиска: ag_catalog имеет приоритет
SET search_path = ag_catalog, "$user", public;

-- pg_trgm: fuzzy-поиск
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- pgcrypto: gen_random_uuid()
CREATE EXTENSION IF NOT EXISTS pgcrypto;
SQL
ok "Базовые расширения установлены (vector, age, pg_trgm, pgcrypto)"

# Создание графов AGE
info "Создание графов AGE: code_graph, task_graph..."
docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" <<'SQL' || { err "Не удалось создать графы AGE"; exit 1; }
LOAD 'age';
SET search_path = ag_catalog, "$user", public;

-- code_graph: граф зависимостей кода
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'code_graph') THEN
        PERFORM ag_catalog.create_graph('code_graph');
        RAISE NOTICE 'Создан граф code_graph';
    ELSE
        RAISE NOTICE 'Граф code_graph уже существует';
    END IF;
END$$;

-- task_graph: граф зависимостей задач
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM ag_catalog.ag_graph WHERE name = 'task_graph') THEN
        PERFORM ag_catalog.create_graph('task_graph');
        RAISE NOTICE 'Создан граф task_graph';
    ELSE
        RAISE NOTICE 'Граф task_graph уже существует';
    END IF;
END$$;
SQL
ok "Графы AGE созданы: code_graph, task_graph"

# ---------------------------------------------------------------------------
# 4. Выполнение SQL-скриптов по порядку
# ---------------------------------------------------------------------------
info "Выполнение SQL-скриптов из $SQL_DIR..."

if [ ! -d "$SQL_DIR" ]; then
    err "Директория $SQL_DIR не найдена."
    err "Проверьте, что репозиторий клонирован в $STUDIO_DIR"
    exit 1
fi

# Сортируем файлы по имени — должны выполняться в порядке 01-, 02-, ...
SQL_FILES=$(ls "$SQL_DIR"/*.sql 2>/dev/null | sort)

if [ -z "$SQL_FILES" ]; then
    warn "SQL-файлы не найдены в $SQL_DIR"
else
    for sql in $SQL_FILES; do
        info "Выполняю $sql..."
        # psql выполняет SQL из stdin через перенаправление
        if ! docker exec -i "$POSTGRES_CONTAINER" \
            psql -U "$POSTGRES_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 < "$sql"; then
            err "Ошибка выполнения SQL-скрипта: $sql"
            err "Проверьте содержимое файла и повторите"
            exit 1
        fi
        ok "Выполнен: $(basename "$sql")"
    done
fi
ok "Все SQL-скрипты выполнены"

# ---------------------------------------------------------------------------
# 5. Создание тестового тенанта 'default'
# ---------------------------------------------------------------------------
info "Создание тестового тенанта 'default'..."

# Функция create_tenant_schema определена в одном из SQL-скриптов (03-tenant-schema-template.sql)
docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" \
    -c "SELECT public.create_tenant_schema('default');" 2>&1 | tee /tmp/create_tenant.log || {
    warn "Не удалось создать тенант 'default' (возможно, уже существует или функция не определена)"
    warn "Проверьте: docker exec $POSTGRES_CONTAINER psql -U $POSTGRES_USER -d $DB_NAME -c '\\df public.create_tenant_schema'"
    # Не выходим — возможно, тенант уже существует
}

if grep -q "schema_default" /tmp/create_tenant.log 2>/dev/null || grep -q "already exists" /tmp/create_tenant.log 2>/dev/null; then
    ok "Тенант 'default' готов"
else
    warn "Статус создания тенанта неопределён — проверьте лог выше"
fi

# ---------------------------------------------------------------------------
# 6. Проверки: количество таблиц, графов, расширений
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Инициализация конвергентной БД '$DB_NAME' завершена"
echo "=========================================================="

info "Проверка расширений:"
docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" -c \
    "SELECT extname AS extension, extversion AS version FROM pg_extension ORDER BY extname;"

info "Проверка количества таблиц в схеме public:"
TABLE_COUNT=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';")
echo "    Таблиц в public: $TABLE_COUNT"

if [ "$TABLE_COUNT" -lt 5 ]; then
    warn "Количество таблиц меньше ожидаемого (>=5). Проверьте SQL-скрипты."
else
    ok "Количество таблиц в норме"
fi

info "Проверка графов AGE:"
docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" -c \
    "LOAD 'age'; SET search_path = ag_catalog, public; SELECT name AS graph FROM ag_graph ORDER BY name;"

GRAPH_COUNT=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" -tAc \
    "LOAD 'age'; SET search_path = ag_catalog, public; SELECT count(*) FROM ag_graph;" 2>/dev/null || echo "0")
echo "    Графов AGE: $GRAPH_COUNT"

if [ "$GRAPH_COUNT" -lt 2 ]; then
    warn "Количество графов меньше ожидаемого (>=2: code_graph, task_graph)"
else
    ok "Графы AGE присутствуют"
fi

info "Проверка схем тенантов:"
docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" -c \
    "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'studio_%' OR schema_name LIKE 'schema_%' ORDER BY schema_name;"

echo ""
info "Следующие шаги:"
echo "  1. Подключите MCP-серверы к Hermes:  ./07-bootstrap-hermes-mcp.sh"
echo "  2. Откройте NocoDB (http://localhost:8080) и подключите к БД hermes_brain"
echo "  3. (Опционально) Миграция с v1.0:    ./08-migrate-nocodb-to-postgres.sh"
echo ""

ok "Готово."
exit 0
