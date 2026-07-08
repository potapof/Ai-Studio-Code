#!/usr/bin/env bash
# ============================================================================
# backup.sh
# ============================================================================
# Backup стека v2.0 (Студия программирования).
#
# - Создание ~/syncthing-host/backup/
# - Дамп PostgreSQL hermes_brain
# - Дамп всех schemas (для мультитенантности) — schema-only
# - Архивирование конфигов: ~/.hermes ~/.holix ~/studio/.env
# - Архивирование NocoDB metadata
# - Дамп графов AGE (через cypher export) в JSON-файл
# - Удаление старых бэкапов (> 7 дней)
# - Логирование в /var/log/studio-backup.log
#
# Usage:
#   ./backup.sh
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
NOCODB_CONTAINER="nocodb-web-ui"
HERMES_CONTAINER="hermes"
DB_NAME="hermes_brain"
STUDIO_DIR="/home/studio/studio"
ENV_FILE="${STUDIO_DIR}/.env"
BACKUP_BASE="${HOME}/syncthing-host/backup"
LOG_FILE="/var/log/studio-backup.log"

DATE=$(date +%Y-%m-%d)
BACKUP_DIR="${BACKUP_BASE}/${DATE}"

# ---------------------------------------------------------------------------
# Логирование (в файл и stdout)
# ---------------------------------------------------------------------------
log() {
    local timestamp
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] $*" | sudo tee -a "$LOG_FILE" >/dev/null
}

# sudo: для записи в /var/log/ требуются права root
sudo touch "$LOG_FILE" 2>/dev/null || true
sudo chmod 644 "$LOG_FILE" 2>/dev/null || true

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

# ---------------------------------------------------------------------------
# 1. Проверка контейнеров
# ---------------------------------------------------------------------------
log "=== Начало backup v2.0 ==="
info "Проверка контейнеров..."

if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    err "Контейнер $POSTGRES_CONTAINER не запущен."
    log "ERROR: Контейнер $POSTGRES_CONTAINER не запущен"
    exit 1
fi
ok "Контейнер $POSTGRES_CONTAINER найден"

# ---------------------------------------------------------------------------
# 2. Создание папки backup
# ---------------------------------------------------------------------------
info "Создание папки $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR" || { err "Не удалось создать $BACKUP_DIR"; exit 1; }
ok "Папка backup готова: $BACKUP_DIR"

# ---------------------------------------------------------------------------
# 3. Дамп PostgreSQL hermes_brain
# ---------------------------------------------------------------------------
info "Создание дампа БД '$DB_NAME'..."

BACKUP_DB_FILE="${BACKUP_DIR}/hermes_brain-${DATE}.sql.gz"

if docker exec "$POSTGRES_CONTAINER" \
    pg_dump -U "$POSTGRES_USER" -d "$DB_NAME" 2>/dev/null | \
    gzip > "$BACKUP_DB_FILE"; then
    DB_SIZE=$(du -h "$BACKUP_DB_FILE" | cut -f1)
    ok "Дамп БД создан: $BACKUP_DB_FILE ($DB_SIZE)"
    log "OK: Дамп БД $DB_NAME ($DB_SIZE)"
else
    err "Не удалось создать дамп БД '$DB_NAME'"
    log "ERROR: Не удалось создать дамп БД $DB_NAME"
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Дамп всех schemas (schema-only — для мультитенантности)
# ---------------------------------------------------------------------------
info "Создание дампа схем (schema-only, для мультитенантности)..."

BACKUP_SCHEMAS_FILE="${BACKUP_DIR}/all-schemas-${DATE}.sql.gz"

if docker exec "$POSTGRES_CONTAINER" \
    pg_dump -U "$POSTGRES_USER" -d "$DB_NAME" --schema-only 2>/dev/null | \
    gzip > "$BACKUP_SCHEMAS_FILE"; then
    SCHEMAS_SIZE=$(du -h "$BACKUP_SCHEMAS_FILE" | cut -f1)
    ok "Дамп схем создан: $BACKUP_SCHEMAS_FILE ($SCHEMAS_SIZE)"
    log "OK: Дамп схем ($SCHEMAS_SIZE)"
else
    warn "Не удалось создать дамп схем"
    log "WARN: Не удалось создать дамп схем"
fi

# ---------------------------------------------------------------------------
# 5. Архивирование конфигов: ~/.hermes ~/.holix ~/studio/.env
# ---------------------------------------------------------------------------
info "Архивирование конфигов (~/.hermes, ~/.holix, $STUDIO_DIR/.env)..."

BACKUP_CONFIGS_FILE="${BACKUP_DIR}/configs-${DATE}.tar.gz"

# Собираем только существующие пути
CONFIG_PATHS=()
[ -d "$HOME/.hermes" ] && CONFIG_PATHS+=("$HOME/.hermes")
[ -d "$HOME/.holix" ]  && CONFIG_PATHS+=("$HOME/.holix")
[ -f "$ENV_FILE" ]     && CONFIG_PATHS+=("$ENV_FILE")

if [ "${#CONFIG_PATHS[@]}" -gt 0 ]; then
    if tar czf "$BACKUP_CONFIGS_FILE" "${CONFIG_PATHS[@]}" 2>/dev/null; then
        CONFIGS_SIZE=$(du -h "$BACKUP_CONFIGS_FILE" | cut -f1)
        ok "Конфиги архивированы: $BACKUP_CONFIGS_FILE ($CONFIGS_SIZE)"
        log "OK: Конфиги архивированы ($CONFIGS_SIZE)"
    else
        warn "Не удалось архивировать конфиги"
        log "WARN: Не удалось архивировать конфиги"
    fi
else
    warn "Не найдено конфигов для архивирования (~/.hermes, ~/.holix, $ENV_FILE)"
    log "WARN: Конфиги не найдены"
fi

# ---------------------------------------------------------------------------
# 6. Архивирование NocoDB metadata
# ---------------------------------------------------------------------------
info "Архивирование NocoDB metadata (из контейнера $NOCODB_CONTAINER)..."

BACKUP_NOCODB_FILE="${BACKUP_DIR}/nocodb-data-${DATE}.tar.gz"

# Проверка, запущен ли NocoDB
if docker ps --format '{{.Names}}' | grep -q "^${NOCODB_CONTAINER}$"; then
    if docker exec "$NOCODB_CONTAINER" \
        tar czf - /usr/app/data/ 2>/dev/null > "$BACKUP_NOCODB_FILE"; then
        NOCODB_SIZE=$(du -h "$BACKUP_NOCODB_FILE" | cut -f1)
        ok "NocoDB metadata архивированы: $BACKUP_NOCODB_FILE ($NOCODB_SIZE)"
        log "OK: NocoDB metadata ($NOCODB_SIZE)"
    else
        warn "Не удалось архивировать NocoDB metadata"
        log "WARN: Не удалось архивировать NocoDB metadata"
    fi
else
    warn "Контейнер $NOCODB_CONTAINER не запущен — пропускаем NocoDB metadata"
    log "WARN: NocoDB не запущен — metadata пропущены"
fi

# ---------------------------------------------------------------------------
# 7. Дамп графов AGE (через cypher export) в JSON-файл
# ---------------------------------------------------------------------------
info "Дамп графов AGE (code_graph, task_graph) в JSON..."

BACKUP_GRAPHS_FILE="${BACKUP_DIR}/age-graphs-${DATE}.json"

# Экспорт вершин и рёбер из code_graph и task_graph через Cypher
# sudo: не требуется — выводим в файл пользователя
docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" -tA <<'SQL' > "$BACKUP_GRAPHS_FILE" 2>/dev/null || true
LOAD 'age';
SET search_path = ag_catalog, "$user", public;

-- code_graph: вершины
SELECT '--- code_graph vertices ---';
SELECT json_agg(v) FROM (
    SELECT * FROM ag_catalog.cypher('code_graph', $$
        MATCH (n) RETURN n
    $$) AS (v ag_catalog.agtype)
) AS vertices;

-- code_graph: рёбра
SELECT '--- code_graph edges ---';
SELECT json_agg(e) FROM (
    SELECT * FROM ag_catalog.cypher('code_graph', $$
        MATCH ()-[r]->() RETURN r
    $$) AS (e ag_catalog.agtype)
) AS edges;

-- task_graph: вершины
SELECT '--- task_graph vertices ---';
SELECT json_agg(v) FROM (
    SELECT * FROM ag_catalog.cypher('task_graph', $$
        MATCH (n) RETURN n
    $$) AS (v ag_catalog.agtype)
) AS vertices;

-- task_graph: рёбра
SELECT '--- task_graph edges ---';
SELECT json_agg(e) FROM (
    SELECT * FROM ag_catalog.cypher('task_graph', $$
        MATCH ()-[r]->() RETURN r
    $$) AS (e ag_catalog.agtype)
) AS edges;
SQL

if [ -s "$BACKUP_GRAPHS_FILE" ]; then
    GRAPHS_SIZE=$(du -h "$BACKUP_GRAPHS_FILE" | cut -f1)
    ok "Графы AGE экспортированы: $BACKUP_GRAPHS_FILE ($GRAPHS_SIZE)"
    log "OK: Графы AGE ($GRAPHS_SIZE)"
else
    warn "Экспорт графов AGE пуст или завершился с ошибкой"
    log "WARN: Экспорт графов AGE пуст"
fi

# ---------------------------------------------------------------------------
# 8. Дополнительно: список схем тенантов (для справки)
# ---------------------------------------------------------------------------
info "Сохранение списка схем тенантов..."

TENANTS_FILE="${BACKUP_DIR}/tenants-${DATE}.txt"

docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" -tAc \
    "SELECT schema_name FROM information_schema.schemata WHERE schema_name LIKE 'studio_%' OR schema_name LIKE 'schema_%' ORDER BY schema_name;" \
    > "$TENANTS_FILE" 2>/dev/null || warn "Не удалось получить список тенантов"

TENANTS_COUNT=$(wc -l < "$TENANTS_FILE" 2>/dev/null || echo "0")
ok "Список тенантов сохранён: $TENANTS_FILE ($TENANTS_COUNT схем)"

# ---------------------------------------------------------------------------
# 9. Удаление старых бэкапов (> 7 дней)
# ---------------------------------------------------------------------------
info "Удаление старых бэкапов (> 7 дней)..."

OLD_COUNT=$(find "$BACKUP_BASE" -maxdepth 1 -type d -mtime +7 2>/dev/null | wc -l)

if [ "$OLD_COUNT" -gt 0 ]; then
    find "$BACKUP_BASE" -maxdepth 1 -type d -mtime +7 -exec rm -rf {} \;
    ok "Удалено старых бэкапов: $OLD_COUNT"
    log "OK: Удалено старых бэкапов: $OLD_COUNT"
else
    info "Старых бэкапов не найдено"
    log "OK: Старых бэкапов не найдено"
fi

# Также удаляем старые gzip/tar файлы в корне backup (если есть)
find "$BACKUP_BASE" -maxdepth 1 -type f -mtime +7 -delete 2>/dev/null || true

# ---------------------------------------------------------------------------
# 10. Итоговая сводка
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Backup v2.0 завершён: $DATE"
echo "=========================================================="
info "Созданные файлы:"
ls -lh "$BACKUP_DIR" 2>/dev/null | tail -n +2 | awk '{print "  " $9 " (" $5 ")"}'
echo ""
info "Расположение: $BACKUP_DIR"
info "Лог:           $LOG_FILE"
info "Тенантов:      $TENANTS_COUNT схем"
echo ""

log "=== Backup завершён успешно ==="
ok "Готово."
exit 0
