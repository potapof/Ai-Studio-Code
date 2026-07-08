#!/usr/bin/env bash
# ============================================================================
# restore.sh
# ============================================================================
# Восстановление стека v2.0 из backup.
#
# - Принимает дату YYYY-MM-DD как аргумент
# - Если дата не указана — выводит список доступных бэкапов
# - Останавливает сервисы кроме PostgreSQL
# - Восстанавливает PostgreSQL hermes_brain
# - Восстанавливает конфиги (~/.hermes, ~/.holix, ~/studio/.env)
# - Восстанавливает NocoDB metadata
# - Перезапускает docker compose up -d
# - Проверка health всех сервисов
#
# Usage:
#   ./restore.sh                      # выведет список доступных бэкапов
#   ./restore.sh 2025-01-15           # восстановит бэкап за указанную дату
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
DB_NAME="hermes_brain"
STUDIO_DIR="/home/studio/studio"
ENV_FILE="${STUDIO_DIR}/.env"
BACKUP_BASE="${HOME}/syncthing-host/backup"
LOG_FILE="/var/log/studio-backup.log"

# ---------------------------------------------------------------------------
# 1. Обработка аргументов
# ---------------------------------------------------------------------------
RESTORE_DATE="${1:-}"

if [ -z "$RESTORE_DATE" ]; then
    info "Дата восстановления не указана."
    info "Доступные бэкапы в $BACKUP_BASE:"
    echo ""

    if [ ! -d "$BACKUP_BASE" ]; then
        err "Папка backup не найдена: $BACKUP_BASE"
        err "Сначала создайте backup: ./backup.sh"
        exit 1
    fi

    # Вывод списка папок с датами
    AVAILABLE_DATES=$(find "$BACKUP_BASE" -maxdepth 1 -type d -name "20*" | sort -r)
    if [ -z "$AVAILABLE_DATES" ]; then
        err "Бэкапы не найдены в $BACKUP_BASE"
        exit 1
    fi

    printf "  %-15s %-10s %s\n" "Дата" "Размер" "Файлы"
    printf "  %-15s %-10s %s\n" "----" "------" "-----"

    for dir in $AVAILABLE_DATES; do
        dir_date=$(basename "$dir")
        dir_size=$(du -sh "$dir" 2>/dev/null | cut -f1)
        files_count=$(find "$dir" -type f | wc -l)
        printf "  %-15s %-10s %s файлов\n" "$dir_date" "$dir_size" "$files_count"
    done

    echo ""
    info "Использование: $0 <YYYY-MM-DD>"
    exit 0
fi

# Валидация формата даты
if ! echo "$RESTORE_DATE" | grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2}$"; then
    err "Некорректный формат даты: $RESTORE_DATE"
    err "Ожидаемый формат: YYYY-MM-DD (например, 2025-01-15)"
    exit 1
fi

BACKUP_DIR="${BACKUP_BASE}/${RESTORE_DATE}"

if [ ! -d "$BACKUP_DIR" ]; then
    err "Бэкап за $RESTORE_DATE не найден: $BACKUP_DIR"
    err "Запустите без аргументов для списка доступных бэкапов: $0"
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Подтверждение восстановления
# ---------------------------------------------------------------------------
warn "ВНИМАНИЕ: Восстановление перезапишет текущие данные!"
warn "Дата восстановления: $RESTORE_DATE"
warn "Папка backup: $BACKUP_DIR"
echo ""
info "Файлы в backup:"
ls -lh "$BACKUP_DIR" 2>/dev/null | tail -n +2
echo ""

read -r -p "Продолжить восстановление? (yes/N): " confirm
if [ "$confirm" != "yes" ]; then
    info "Восстановление отменено."
    exit 0
fi

# ---------------------------------------------------------------------------
# 3. Загрузка .env
# ---------------------------------------------------------------------------
if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE" 2>/dev/null || true
    set +a
fi

POSTGRES_USER="${POSTGRES_USER:-nocodb_user}"

# ---------------------------------------------------------------------------
# 4. Проверка контейнеров
# ---------------------------------------------------------------------------
info "Проверка контейнеров..."

if ! docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    err "Контейнер $POSTGRES_CONTAINER не запущен."
    err "Запустите стек: ./05-deploy-stack.sh"
    exit 1
fi
ok "Контейнер $POSTGRES_CONTAINER найден"

# ---------------------------------------------------------------------------
# 5. Остановка сервисов кроме PostgreSQL
# ---------------------------------------------------------------------------
info "Остановка сервисов (кроме PostgreSQL)..."

cd "$STUDIO_DIR" || { err "Не удалось перейти в $STUDIO_DIR"; exit 1; }

# Останавливаем все сервисы кроме postgres
SERVICES_TO_STOP=(
    "nocodb-web-ui"
    "hermes"
    "holix-coordinator"
    "holix-archivist"
    "holix-backend-lead"
    "holix-frontend-lead"
    "holix-qa"
    "holix-loop-checker"
    "holix-lint"
    "openhands"
)

for svc in "${SERVICES_TO_STOP[@]}"; do
    info "Останавливаю $svc..."
    docker compose stop "$svc" 2>/dev/null || warn "Не удалось остановить $svc (возможно, не запущен)"
done
ok "Сервисы остановлены (PostgreSQL продолжает работать)"

# ---------------------------------------------------------------------------
# 6. Восстановление PostgreSQL hermes_brain
# ---------------------------------------------------------------------------
DB_BACKUP_FILE="${BACKUP_DIR}/hermes_brain-${RESTORE_DATE}.sql.gz"

if [ ! -f "$DB_BACKUP_FILE" ]; then
    err "Файл дампа БД не найден: $DB_BACKUP_FILE"
    err "Проверьте содержимое backup."
    exit 1
fi

info "Восстановление PostgreSQL из $DB_BACKUP_FILE..."

# sudo: не требуется — gzip и docker exec доступны пользователю

# Сначала пересоздаём БД (удаляем и создаём заново для чистого восстановления)
info "Пересоздание БД '$DB_NAME'..."
docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres \
    -c "DROP DATABASE IF EXISTS $DB_NAME;" 2>/dev/null || {
    warn "Не удалось удалить БД '$DB_NAME' (возможно, есть активные подключения)"
    warn "Принудительно завершаю подключения..."
    docker exec "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d postgres \
        -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$DB_NAME' AND pid <> pg_backend_pid();" 2>/dev/null || true
    docker exec "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d postgres \
        -c "DROP DATABASE IF EXISTS $DB_NAME;" 2>/dev/null || {
        err "Не удалось удалить БД '$DB_NAME'"
        exit 1
    }
}

docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d postgres \
    -c "CREATE DATABASE $DB_NAME;" || { err "Не удалось создать БД $DB_NAME"; exit 1; }
ok "БД '$DB_NAME' пересоздана"

# Восстановление из дампа
info "Загрузка дампа в '$DB_NAME'..."
if gunzip -c "$DB_BACKUP_FILE" | \
    docker exec -i "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" -v ON_ERROR_STOP=0 2>&1 | tail -n20; then
    ok "БД '$DB_NAME' восстановлена"
else
    err "Ошибка восстановления БД '$DB_NAME'"
    err "Проверьте файл дампа: $DB_BACKUP_FILE"
    exit 1
fi

# ---------------------------------------------------------------------------
# 7. Восстановление конфигов
# ---------------------------------------------------------------------------
CONFIGS_BACKUP_FILE="${BACKUP_DIR}/configs-${RESTORE_DATE}.tar.gz"

if [ -f "$CONFIGS_BACKUP_FILE" ]; then
    info "Восстановление конфигов из $CONFIGS_BACKUP_FILE..."

    # Backup текущих конфигов (на случай отката)
    if [ -d "$HOME/.hermes" ] || [ -d "$HOME/.holix" ] || [ -f "$ENV_FILE" ]; then
        info "Создание backup текущих конфигов перед восстановлением..."
        CURRENT_BACKUP="${BACKUP_BASE}/configs-current-$(date +%Y-%m-%d-%H%M%S).tar.gz"
        CONFIG_PATHS=()
        [ -d "$HOME/.hermes" ] && CONFIG_PATHS+=("$HOME/.hermes")
        [ -d "$HOME/.holix" ]  && CONFIG_PATHS+=("$HOME/.holix")
        [ -f "$ENV_FILE" ]     && CONFIG_PATHS+=("$ENV_FILE")
        tar czf "$CURRENT_BACKUP" "${CONFIG_PATHS[@]}" 2>/dev/null || warn "Не удалось создать backup текущих конфигов"
    fi

    # Восстановление
    if tar xzf "$CONFIGS_BACKUP_FILE" -C / 2>/dev/null; then
        ok "Конфиги восстановлены"
    else
        warn "Не удалось восстановить конфиги (tar завершился с ошибкой)"
        warn "Возможно, пути в архиве отличаются от ожидаемых."
    fi
else
    warn "Файл конфигов не найден: $CONFIGS_BACKUP_FILE — пропуск"
fi

# ---------------------------------------------------------------------------
# 8. Восстановление NocoDB metadata
# ---------------------------------------------------------------------------
NOCODB_BACKUP_FILE="${BACKUP_DIR}/nocodb-data-${RESTORE_DATE}.tar.gz"

if [ -f "$NOCODB_BACKUP_FILE" ]; then
    info "Восстановление NocoDB metadata..."

    # NocoDB должен быть запущен для копирования в контейнер
    info "Запуск NocoDB для восстановления metadata..."
    docker compose start nocodb-web-ui 2>/dev/null || docker compose up -d nocodb-web-ui 2>/dev/null || true
    sleep 5

    # Копируем архив в контейнер
    if docker cp "$NOCODB_BACKUP_FILE" "${NOCODB_CONTAINER}:/tmp/nocodb-restore.tar.gz"; then
        # Распаковываем внутри контейнера
        if docker exec "$NOCODB_CONTAINER" tar xzf /tmp/nocodb-restore.tar.gz -C / 2>/dev/null; then
            ok "NocoDB metadata восстановлены"
            docker exec "$NOCODB_CONTAINER" rm -f /tmp/nocodb-restore.tar.gz 2>/dev/null || true
        else
            warn "Не удалось распаковать NocoDB metadata в контейнере"
        fi
    else
        warn "Не удалось скопировать архив в контейнер $NOCODB_CONTAINER"
    fi
else
    warn "Файл NocoDB metadata не найден: $NOCODB_BACKUP_FILE — пропуск"
fi

# ---------------------------------------------------------------------------
# 9. Перезапуск docker compose up -d
# ---------------------------------------------------------------------------
info "Перезапуск всех сервисов (docker compose up -d)..."
cd "$STUDIO_DIR" || { err "Не удалось перейти в $STUDIO_DIR"; exit 1; }

if docker compose up -d; then
    ok "Сервисы запущены"
else
    err "Ошибка запуска сервисов."
    err "Проверьте: docker compose logs"
    exit 1
fi

# ---------------------------------------------------------------------------
# 10. Проверка health всех сервисов
# ---------------------------------------------------------------------------
info "Проверка health всех сервисов..."

sleep 15

# PostgreSQL
info "Проверка PostgreSQL..."
if docker exec "$POSTGRES_CONTAINER" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
    ok "PostgreSQL готов"
else
    err "PostgreSQL не готов"
fi

# NocoDB
info "Проверка NocoDB..."
for i in 1 2 3 4 5 6; do
    if curl -sf http://localhost:8080/api/v1/health >/dev/null 2>&1; then
        ok "NocoDB готов"
        break
    fi
    info "Попытка $i: NocoDB ещё не готова..."
    sleep 5
done

# Hermes
info "Проверка Hermes..."
for i in 1 2 3 4 5 6; do
    if curl -sf http://localhost:8082/health >/dev/null 2>&1; then
        ok "Hermes готов"
        break
    fi
    info "Попытка $i: Hermes ещё не готов..."
    sleep 5
done

# Проверка таблиц в восстановленной БД
info "Проверка восстановления — количество таблиц в public:"
TABLE_COUNT=$(docker exec "$POSTGRES_CONTAINER" \
    psql -U "$POSTGRES_USER" -d "$DB_NAME" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public';" 2>/dev/null || echo "0")
echo "    Таблиц в public: $TABLE_COUNT"

# ---------------------------------------------------------------------------
# 11. Итоговая сводка
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Восстановление из backup $RESTORE_DATE завершено"
echo "=========================================================="
info "Источник: $BACKUP_DIR"
info "БД: $DB_NAME ($TABLE_COUNT таблиц в public)"
echo ""
info "URL'ы сервисов:"
echo "  NocoDB:    http://localhost:8080"
echo "  Hermes:    http://localhost:8082"
echo "  Portainer: http://localhost:9000"
echo ""
warn "Если наблюдаются проблемы, проверьте логи:"
echo "  docker compose logs --tail=50 <service>"
echo ""

# Логирование
# sudo: для записи в /var/log/ требуются права root
echo "[$(date '+%Y-%m-%d %H:%M:%S')] Restore из backup $RESTORE_DATE завершён" | \
    sudo tee -a "$LOG_FILE" >/dev/null 2>/dev/null || true

ok "Готово."
exit 0
