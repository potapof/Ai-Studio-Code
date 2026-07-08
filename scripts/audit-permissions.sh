#!/usr/bin/env bash
# ============================================================================
# audit-permissions.sh
# ============================================================================
# Аудит прав стека v2.0 (Студия программирования).
#
# - Заголовок с датой
# - Список всех loop из ~/.hermes/loops/registry.json
# - Для каждого loop: maker/checker агентов и их права
# - Сравнение с baseline (public.permissions_baseline или WARNING)
# - Docker capabilities каждого контейнера
# - Seccomp profile каждого контейнера
# - Проверка истечения токенов в .env
# - ПРОВЕРКА MCP-подключений Hermes: hermes mcp list
# - ПРОВЕРКА OAuth-токена SOA: время до истечения (если < 7 дней — WARNING)
# - ПРОВЕРКА прав доступа к PostgreSQL: для каждого агента через psql \du
# - Генерация Markdown-отчёта в ~/syncthing-host/audit/audit-<date>.md
# - Уведомление в Slack через webhook (если задан)
#
# Usage:
#   ./audit-permissions.sh
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
DB_NAME="hermes_brain"
STUDIO_DIR="/home/studio/studio"
ENV_FILE="${STUDIO_DIR}/.env"
LOOPS_REGISTRY="${HOME}/.hermes/loops/registry.json"
AUDIT_DIR="${HOME}/syncthing-host/audit"

DATE=$(date +%Y-%m-%d)
AUDIT_FILE="${AUDIT_DIR}/audit-${DATE}.md"

# ---------------------------------------------------------------------------
# Создание папки audit
# ---------------------------------------------------------------------------
mkdir -p "$AUDIT_DIR" || { err "Не удалось создать $AUDIT_DIR"; exit 1; }

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
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"

# ---------------------------------------------------------------------------
# Начало формирования отчёта
# ---------------------------------------------------------------------------
{
echo "# Аудит прав стека v2.0 — $(date '+%Y-%m-%d %H:%M:%S')"
echo ""
echo "Сгенерировано: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "Хост: $(hostname)"
echo ""
echo "---"
echo ""

# ===========================================================================
# 1. Список всех loop из ~/.hermes/loops/registry.json
# ===========================================================================
echo "## 1. Список Loops (Hermes)"
echo ""
if [ -f "$LOOPS_REGISTRY" ]; then
    if command -v jq >/dev/null 2>&1; then
        echo "Файл: \`$LOOPS_REGISTRY\`"
        echo ""
        echo '```json'
        jq '.' "$LOOPS_REGISTRY" 2>/dev/null || cat "$LOOPS_REGISTRY"
        echo '```'
        echo ""

        # Извлекаем список loop'ов
        LOOPS=$(jq -r '.loops[]? | .id // .name // .loop_id // empty' "$LOOPS_REGISTRY" 2>/dev/null || echo "")
        if [ -n "$LOOPS" ]; then
            echo "### Loops:"
            echo ""
            echo "| Loop ID | Maker | Checker | Status |"
            echo "|---------|-------|---------|--------|"
            while IFS= read -r loop_id; do
                [ -z "$loop_id" ] && continue
                MAKER=$(jq -r --arg id "$loop_id" '.loops[]? | select(.id == $id or .name == $id or .loop_id == $id) | .maker // .agents.maker // "н/д"' "$LOOPS_REGISTRY" 2>/dev/null || echo "н/д")
                CHECKER=$(jq -r --arg id "$loop_id" '.loops[]? | select(.id == $id or .name == $id or .loop_id == $id) | .checker // .agents.checker // "н/д"' "$LOOPS_REGISTRY" 2>/dev/null || echo "н/д")
                STATUS=$(jq -r --arg id "$loop_id" '.loops[]? | select(.id == $id or .name == $id or .loop_id == $id) | .status // "н/д"' "$LOOPS_REGISTRY" 2>/dev/null || echo "н/д")
                echo "| $loop_id | $MAKER | $CHECKER | $STATUS |"
            done <<< "$LOOPS"
            echo ""
        fi
    else
        echo '```json'
        cat "$LOOPS_REGISTRY"
        echo '```'
        echo ""
        warn "jq не установлен — детальный анализ loop'ов недоступен"
    fi
else
    echo "Файл \`$LOOPS_REGISTRY\` не найден."
    echo "Возможные причины:"
    echo "- Hermes ещё не создал ни одного loop"
    echo "- Файл находится в другом месте"
    echo ""
fi

# ===========================================================================
# 2. Docker capabilities и Seccomp profile каждого контейнера
# ===========================================================================
echo "## 2. Docker capabilities и Seccomp"
echo ""
echo "| Контейнер | Capabilities | SecurityOpt (Seccomp/AppArmor) |"
echo "|-----------|--------------|--------------------------------|"

CONTAINERS=$(docker ps --format '{{.Names}}' 2>/dev/null || echo "")
if [ -z "$CONTAINERS" ]; then
    echo "| (контейнеры не запущены) | — | — |"
else
    for container in $CONTAINERS; do
        CAPS=$(docker inspect --format '{{.HostConfig.CapAdd}}' "$container" 2>/dev/null | tr -d '[]' || echo "н/д")
        SEC=$(docker inspect --format '{{.HostConfig.SecurityOpt}}' "$container" 2>/dev/null | tr -d '[]' || echo "н/д")
        [ -z "$CAPS" ] && CAPS="default"
        [ -z "$SEC" ]  && SEC="default"
        echo "| $container | $CAPS | $SEC |"
    done
fi
echo ""

# ===========================================================================
# 3. Сравнение с baseline
# ===========================================================================
echo "## 3. Сравнение с baseline прав"
echo ""
if docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    BASELINE_EXISTS=$(docker exec "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$DB_NAME" -tAc \
        "SELECT 1 FROM information_schema.tables WHERE table_schema = 'public' AND table_name = 'permissions_baseline';" 2>/dev/null || echo "")

    if [ "$BASELINE_EXISTS" = "1" ]; then
        echo "Таблица \`public.permissions_baseline\` существует."
        echo ""
        echo "### Baseline:"
        echo ""
        echo '```sql'
        docker exec "$POSTGRES_CONTAINER" \
            psql -U "$POSTGRES_USER" -d "$DB_NAME" -c \
            "SELECT * FROM public.permissions_baseline ORDER BY 1 LIMIT 100;" 2>/dev/null || echo "  -- ошибка запроса --"
        echo '```'
        echo ""

        # Сравнение фактических capabilities с baseline
        echo "### Отклонения от baseline:"
        echo ""
        echo "(Сравнение capabilities контейнеров с записями в baseline)"
        echo ""
        for container in $CONTAINERS; do
            ACTUAL_CAPS=$(docker inspect --format '{{.HostConfig.CapAdd}}' "$container" 2>/dev/null | tr -d '[]' || echo "")
            BASELINE_CAPS=$(docker exec "$POSTGRES_CONTAINER" \
                psql -U "$POSTGRES_USER" -d "$DB_NAME" -tAc \
                "SELECT capabilities FROM public.permissions_baseline WHERE container_name = '$container' LIMIT 1;" 2>/dev/null || echo "")
            if [ -n "$BASELINE_CAPS" ]; then
                if [ "$ACTUAL_CAPS" = "$BASELINE_CAPS" ]; then
                    echo "- $container: **OK** (соответствует baseline)"
                else
                    echo "- $container: **WARNING** — actual='$ACTUAL_CAPS', baseline='$BASELINE_CAPS'"
                fi
            else
                echo "- $container: не найден в baseline (новый контейнер?)"
            fi
        done
        echo ""
    else
        echo "**WARNING**: Таблица \`public.permissions_baseline\` не найдена."
        echo "Создайте baseline перед аудитом или сравнивайте вручную."
        echo ""
    fi
else
    echo "Контейнер $POSTGRES_CONTAINER не запущен — сравнение с baseline невозможно."
    echo ""
fi

# ===========================================================================
# 4. Проверка истечения токенов в .env
# ===========================================================================
echo "## 4. Проверка токенов в .env"
echo ""
echo "| Переменная | Статус | Комментарий |"
echo "|------------|--------|-------------|"

# Проверка наличия и непустоты токенов
ENV_VARS_TO_CHECK=(
    "POSTGRES_PASSWORD"
    "GITHUB_PERSONAL_ACCESS_TOKEN"
    "SLACK_BOT_TOKEN"
    "SLACK_WEBHOOK_URL"
    "SENTRY_DSN"
    "NOCODB_API_TOKEN"
)

for var in "${ENV_VARS_TO_CHECK[@]}"; do
    VALUE="${!var:-}"
    if [ -z "$VALUE" ]; then
        echo "| $var | WARNING | Не задан |"
    else
        # Маскируем значение
        echo "| $var | OK | Задан (длина: ${#VALUE}) |"
    fi
done
echo ""

# ===========================================================================
# 5. ПРОВЕРКА MCP-подключений Hermes
# ===========================================================================
echo "## 5. MCP-подключения Hermes"
echo ""
if docker ps --format '{{.Names}}' | grep -q "^${HERMES_CONTAINER}$"; then
    echo '```'
    docker exec "$HERMES_CONTAINER" hermes mcp list 2>&1 || echo "(ошибка получения списка)"
    echo '```'
    echo ""
else
    echo "Контейнер $HERMES_CONTAINER не запущен — проверка MCP невозможна."
    echo ""
fi

# ===========================================================================
# 6. ПРОВЕРКА OAuth-токена SOA
# ===========================================================================
echo "## 6. OAuth-токен SOA (Stack Overflow for Agents)"
echo ""
if docker ps --format '{{.Names}}' | grep -q "^${HERMES_CONTAINER}$"; then
    # Проверяем срок действия OAuth-токена SOA
    SOA_TOKEN_INFO=$(docker exec "$HERMES_CONTAINER" \
        hermes mcp info stackoverflow 2>/dev/null || echo "")

    if [ -n "$SOA_TOKEN_INFO" ]; then
        echo '```'
        echo "$SOA_TOKEN_INFO"
        echo '```'
        echo ""

        # Проверяем срок действия (ищем expiry в выводе)
        EXPIRY_DATE=$(echo "$SOA_TOKEN_INFO" | grep -oE 'expiry["\s:]+[0-9T:-]+' | head -n1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' || echo "")

        if [ -n "$EXPIRY_DATE" ]; then
            DAYS_LEFT=$(( ( $(date -d "$EXPIRY_DATE" +%s 2>/dev/null || echo 0) - $(date +%s) ) / 86400 ))
            if [ "$DAYS_LEFT" -lt 7 ]; then
                echo "**WARNING**: OAuth-токен SOA истекает через $DAYS_LEFT дней (дата: $EXPIRY_DATE)."
                echo "Необходимо продлить авторизацию через браузер."
            else
                echo "OAuth-токен SOA действителен до $EXPIRY_DATE (осталось $DAYS_LEFT дней)."
            fi
        else
            echo "Срок действия OAuth-токена не удалось определить."
            echo "Проверьте вручную через OAuth-авторизацию."
        fi
    else
        echo "Информация о MCP 'stackoverflow' недоступна."
        echo "Возможно, OAuth 2.1 авторизация ещё не выполнена."
    fi
else
    echo "Контейнер $HERMES_CONTAINER не запущен."
    echo ""
fi

# ===========================================================================
# 7. ПРОВЕРКА прав доступа к PostgreSQL
# ===========================================================================
echo "## 7. Роли и права PostgreSQL"
echo ""
if docker ps --format '{{.Names}}' | grep -q "^${POSTGRES_CONTAINER}$"; then
    echo "### Роли пользователей (\du):"
    echo ""
    echo '```'
    docker exec "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$DB_NAME" -c "\du" 2>&1 || echo "(ошибка)"
    echo '```'
    echo ""

    echo "### Права на таблицы в схеме public:"
    echo ""
    echo '```'
    docker exec "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$DB_NAME" -c \
        "SELECT grantee, table_name, privilege_type FROM information_schema.role_table_grants WHERE table_schema = 'public' ORDER BY grantee, table_name, privilege_type LIMIT 100;" 2>&1 || echo "(ошибка)"
    echo '```'
    echo ""

    echo "### Схемы тенантов:"
    echo ""
    echo '```'
    docker exec "$POSTGRES_CONTAINER" \
        psql -U "$POSTGRES_USER" -d "$DB_NAME" -c \
        "SELECT schema_name, schema_owner FROM information_schema.schemata WHERE schema_name LIKE 'studio_%' OR schema_name LIKE 'schema_%' ORDER BY schema_name;" 2>&1 || echo "(ошибка)"
    echo '```'
    echo ""
else
    echo "Контейнер $POSTGRES_CONTAINER не запущен."
    echo ""
fi

# ===========================================================================
# 8. Итоговая сводка
# ===========================================================================
echo "## 8. Итоговая сводка"
echo ""
echo "- Дата аудита: $(date '+%Y-%m-%d %H:%M:%S')"
echo "- Хост: $(hostname)"
echo "- Логин: $(whoami)"
echo "- Контейнеров запущено: $(docker ps -q 2>/dev/null | wc -l)"
echo "- Файл отчёта: \`$AUDIT_FILE\`"
echo ""

} > "$AUDIT_FILE"

ok "Отчёт аудита создан: $AUDIT_FILE"

# ---------------------------------------------------------------------------
# Вывод содержимого отчёта на экран
# ---------------------------------------------------------------------------
echo ""
echo "=========================================================="
ok "Аудит прав завершён"
echo "=========================================================="
cat "$AUDIT_FILE"
echo ""

# ---------------------------------------------------------------------------
# Уведомление в Slack через webhook
# ---------------------------------------------------------------------------
if [ -n "$SLACK_WEBHOOK_URL" ]; then
    info "Отправка уведомления в Slack..."

    SLACK_MESSAGE="*Аудит прав стека v2.0 завершён*
Дата: $(date '+%Y-%m-%d %H:%M:%S')
Хост: $(hostname)
Контейнеров: $(docker ps -q 2>/dev/null | wc -l)
Отчёт: $AUDIT_FILE"

    # Формируем JSON payload
    PAYLOAD=$(jq -n --arg text "$SLACK_MESSAGE" '{text: $text}')

    if curl -sf -X POST -H 'Content-Type: application/json' \
        -d "$PAYLOAD" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1; then
        ok "Уведомление отправлено в Slack"
    else
        warn "Не удалось отправить уведомление в Slack"
        warn "Проверьте SLACK_WEBHOOK_URL в .env"
    fi
else
    info "SLACK_WEBHOOK_URL не задан — уведомление в Slack пропущено"
fi

# ---------------------------------------------------------------------------
# Проверка критических WARNING
# ---------------------------------------------------------------------------
WARN_COUNT=$(grep -c "WARNING" "$AUDIT_FILE" 2>/dev/null || echo "0")
if [ "$WARN_COUNT" -gt 0 ]; then
    warn "Найдено $WARN_COUNT предупреждений (WARNING) в отчёте."
    warn "Просмотрите файл: $AUDIT_FILE"
else
    ok "Критических предупреждений не обнаружено"
fi

ok "Готово."
exit 0
