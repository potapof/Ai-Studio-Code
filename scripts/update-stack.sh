#!/usr/bin/env bash
# ============================================================================
# update-stack.sh
# ============================================================================
# Обновление Docker Compose стека v2.0 (Студия программирования).
#
# - docker compose pull
# - Backup через вызов backup.sh
# - docker compose up -d
# - Проверка health всех сервисов
# - docker image prune -a --filter "until=168h" --force
# - Вывод новых версий образов
# - Лог в /var/log/studio-update.log
#
# Usage:
#   ./update-stack.sh
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
LOG_FILE="/var/log/studio-update.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_SCRIPT="${SCRIPT_DIR}/backup.sh"

# Контейнеры для проверки health
POSTGRES_CONTAINER="nocodb-postgres-db"
NOCODB_CONTAINER="nocodb-web-ui"
HERMES_CONTAINER="hermes"

# ---------------------------------------------------------------------------
# Логирование
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
# 1. Проверка директории студии
# ---------------------------------------------------------------------------
log "=== Начало обновления стека v2.0 ==="
info "Проверка директории $STUDIO_DIR..."

if [ ! -d "$STUDIO_DIR" ]; then
    err "Директория $STUDIO_DIR не существует."
    log "ERROR: Директория $STUDIO_DIR не найдена"
    exit 1
fi

if [ ! -f "${STUDIO_DIR}/docker-compose.yml" ]; then
    err "docker-compose.yml не найден в $STUDIO_DIR"
    log "ERROR: docker-compose.yml не найден"
    exit 1
fi
ok "Директория студии найдена"
log "OK: Директория студии найдена"

cd "$STUDIO_DIR" || { err "Не удалось перейти в $STUDIO_DIR"; exit 1; }

# ---------------------------------------------------------------------------
# 2. Запись версий образов ДО обновления
# ---------------------------------------------------------------------------
info "Запись версий образов ДО обновления..."

IMAGES_BEFORE_FILE="/tmp/studio-images-before.txt"
docker compose images 2>/dev/null > "$IMAGES_BEFORE_FILE" || docker images > "$IMAGES_BEFORE_FILE"
ok "Версии образов до обновления сохранены"
log "OK: Версии образов ДО обновления сохранены"

# ---------------------------------------------------------------------------
# 3. docker compose pull
# ---------------------------------------------------------------------------
info "Скачивание новых образов (docker compose pull)..."

if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE" 2>/dev/null || true
    set +a
fi

if ! docker compose pull; then
    err "docker compose pull завершился с ошибкой"
    log "ERROR: docker compose pull не удался"
    exit 1
fi
ok "Образы обновлены"
log "OK: Образы обновлены через docker compose pull"

# ---------------------------------------------------------------------------
# 4. Backup перед обновлением
# ---------------------------------------------------------------------------
info "Создание backup перед обновлением..."

if [ -f "$BACKUP_SCRIPT" ]; then
    info "Запуск $BACKUP_SCRIPT..."
    if bash "$BACKUP_SCRIPT"; then
        ok "Backup перед обновлением создан"
        log "OK: Backup перед обновлением создан"
    else
        warn "Backup завершился с ошибкой. Продолжаем обновление?"
        log "WARN: Backup завершился с ошибкой"
        read -r -p "Продолжить обновление без backup? (y/N): " confirm
        if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
            info "Обновление отменено пользователем."
            log "INFO: Обновление отменено пользователем после ошибки backup"
            exit 1
        fi
    fi
else
    warn "Скрипт backup.sh не найден: $BACKUP_SCRIPT"
    warn "Обновление продолжится без backup!"
    log "WARN: Backup скрипт не найден — обновление без backup"
    read -r -p "Продолжить без backup? (y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        info "Обновление отменено пользователем."
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# 5. docker compose up -d
# ---------------------------------------------------------------------------
info "Перезапуск сервисов с новыми образами (docker compose up -d)..."

if ! docker compose up -d; then
    err "docker compose up -d завершился с ошибкой"
    log "ERROR: docker compose up -d не удался"
    err "Проверьте логи: docker compose logs"
    exit 1
fi
ok "Сервисы перезапущены"
log "OK: Сервисы перезапущены"

# ---------------------------------------------------------------------------
# 6. Проверка health всех сервисов
# ---------------------------------------------------------------------------
info "Проверка health всех сервисов..."

sleep 10

HEALTH_OK=true
HEALTH_REPORT=""

# PostgreSQL
info "Проверка PostgreSQL..."
if docker exec "$POSTGRES_CONTAINER" pg_isready -U "${POSTGRES_USER:-nocodb_user}" >/dev/null 2>&1; then
    HEALTH_REPORT+="  PostgreSQL:  OK\n"
    ok "PostgreSQL готов"
    log "OK: PostgreSQL готов"
else
    HEALTH_REPORT+="  PostgreSQL:  FAIL\n"
    err "PostgreSQL не готов"
    log "ERROR: PostgreSQL не готов"
    HEALTH_OK=false
fi

# NocoDB
info "Проверка NocoDB..."
NOCODB_OK=false
for i in 1 2 3 4 5 6; do
    if curl -sf http://localhost:8080/api/v1/health >/dev/null 2>&1; then
        NOCODB_OK=true
        break
    fi
    info "Попытка $i: NocoDB ещё не готова..."
    sleep 5
done
if [ "$NOCODB_OK" = true ]; then
    HEALTH_REPORT+="  NocoDB:       OK\n"
    ok "NocoDB готова"
    log "OK: NocoDB готова"
else
    HEALTH_REPORT+="  NocoDB:       FAIL\n"
    err "NocoDB не готова"
    log "ERROR: NocoDB не готова"
    HEALTH_OK=false
fi

# Hermes
info "Проверка Hermes..."
HERMES_OK=false
for i in 1 2 3 4 5 6; do
    if curl -sf http://localhost:8082/health >/dev/null 2>&1; then
        HERMES_OK=true
        break
    fi
    info "Попытка $i: Hermes ещё не готов..."
    sleep 5
done
if [ "$HERMES_OK" = true ]; then
    HEALTH_REPORT+="  Hermes:       OK\n"
    ok "Hermes готов"
    log "OK: Hermes готов"
else
    HEALTH_REPORT+="  Hermes:       FAIL\n"
    warn "Hermes не готов"
    log "WARN: Hermes не готов"
fi

# Portainer (опционально)
if curl -sf http://localhost:9000 >/dev/null 2>&1; then
    HEALTH_REPORT+="  Portainer:    OK\n"
    ok "Portainer готов"
else
    HEALTH_REPORT+="  Portainer:    SKIP (не проверялся)\n"
fi

# ---------------------------------------------------------------------------
# 7. docker image prune -a --filter "until=168h" --force
# ---------------------------------------------------------------------------
info "Очистка старых образов (docker image prune)..."

# sudo: не требуется — пользователь в группе docker
# --filter "until=168h" — удаляет образы старше 7 дней
# --force — без подтверждения
PRUNE_OUTPUT=$(docker image prune -a --filter "until=168h" --force 2>&1 || true)
PRUNE_SIZE=$(echo "$PRUNE_OUTPUT" | grep -oE 'reclaimed [0-9.]+[A-Z]+B' || echo "размер неизвестен")

ok "Очистка завершена: $PRUNE_SIZE"
log "OK: Очистка образов: $PRUNE_SIZE"

# ---------------------------------------------------------------------------
# 8. Вывод новых версий образов
# ---------------------------------------------------------------------------
info "Вывод новых версий образов..."

IMAGES_AFTER_FILE="/tmp/studio-images-after.txt"
docker compose images 2>/dev/null > "$IMAGES_AFTER_FILE" || docker images > "$IMAGES_AFTER_FILE"

echo ""
echo "=========================================================="
ok "Обновление стека v2.0 завершено"
echo "=========================================================="
echo ""
info "Сравнение версий образов (ДО -> ПОСЛЕ):"
echo ""

# Простое сравнение — выводим обе таблицы
echo "--- ДО обновления ---"
cat "$IMAGES_BEFORE_FILE" 2>/dev/null | head -n20
echo ""
echo "--- ПОСЛЕ обновления ---"
cat "$IMAGES_AFTER_FILE" 2>/dev/null | head -n20
echo ""

info "Health-отчёт:"
echo -e "$HEALTH_REPORT"
echo ""

if [ "$HEALTH_OK" = true ]; then
    ok "Все основные сервисы готовы"
    log "OK: Все основные сервисы готовы"
else
    warn "Некоторые сервисы не готовы — проверьте логи"
    log "WARN: Некоторые сервисы не готовы"
fi

info "Очистка образов:"
echo "  $PRUNE_SIZE"
echo ""

info "URL'ы сервисов:"
echo "  NocoDB:    http://localhost:8080"
echo "  Hermes:    http://localhost:8082"
echo "  Portainer: http://localhost:9000"
echo ""
info "Лог обновления: $LOG_FILE"
echo ""

# Очистка временных файлов
rm -f "$IMAGES_BEFORE_FILE" "$IMAGES_AFTER_FILE" 2>/dev/null || true

log "=== Обновление завершено ==="
ok "Готово."
exit 0
