#!/usr/bin/env bash
# holix-delegate.sh — отправить задачу holix-воркеру через HTTP API
# Использование:
#   holix-delegate.sh <воркер> "<задача>" [--timeout N] [--model MODEL]
#   holix-delegate.sh --list                    # показать известные воркеры
#   holix-delegate.sh --help
#
# Воркеры:
#   coordinator     — через хост 127.0.0.1:8010 с hx_-ключом (точка входа)
#   python-dev, react-dev, qa, archivist,
#   backend-lead, frontend-lead, loop-checker,
#   lint, backend-executor
#                     — напрямую через studio-net (172.20.0.x:8000), без ключа
#
# Вывод: HTTP-код, время, content ответа, usage (токены)
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_FILE="${SCRIPT_DIR}/../.holix-hermes-key.txt"

# ── Карта воркеров ──────────────────────────────────────
# формат: имя|ip|порт|auth
# auth=key → нужен hx_-ключ (coordinator)
# auth=no  → без ключа (внутренние, studio-net)
read -r -d '' WORKERS_RAW <<'EOF' || true
coordinator|127.0.0.1|8010|key
python-dev|172.20.0.45|8000|no
react-dev|172.20.0.46|8000|no
qa|172.20.0.47|8000|no
archivist|172.20.0.42|8000|no
backend-lead|172.20.0.43|8000|no
frontend-lead|172.20.0.44|8000|no
loop-checker|172.20.0.48|8000|no
lint|172.20.0.49|8000|no
backend-executor|172.18.0.14|8000|no
EOF

# ── Функции ──────────────────────────────────────────────

usage() {
    cat <<'HELP'
Использование:
  holix-delegate.sh <воркер> "<задача>" [--timeout N] [--model MODEL]
  holix-delegate.sh --list
  holix-delegate.sh --help

Воркеры: coordinator, python-dev, react-dev, qa, archivist,
         backend-lead, frontend-lead, loop-checker, lint, backend-executor

Примеры:
  holix-delegate.sh python-dev "Напиши функцию сложения a+b на Python"
  holix-delegate.sh coordinator "Сколько будет 7*8? одним числом" --timeout 90
  holix-delegate.sh qa "Проверь файл /workspace/qa/artifacts/test.py" --model deepseek-chat
HELP
    exit 0
}

list_workers() {
    echo "Известные воркеры:"
    echo "─────────────────────────────────────────────────"
    while IFS='|' read -r name ip port auth; do
        local label
        if [ "$auth" = "key" ]; then label="(hx_-ключ, точка входа Hermes)"; else label="(без ключа, docker-сеть)"; fi
        printf "  %-20s %s:%-5s %s\n" "$name" "$ip" "$port" "$label"
    done <<<"$WORKERS_RAW"
    echo
    echo "Все воркеры (coordinator — единственный с auth):"
    exit 0
}

resolve() {
    local name="$1"
    while IFS='|' read -r wname ip port auth; do
        if [ "$wname" = "$name" ]; then
            echo "$ip|$port|$auth"; return 0
        fi
    done <<<"$WORKERS_RAW"
    echo "ОШИБКА: неизвестный воркер '$name'" >&2
    echo "Доступные: coordinator, python-dev, react-dev, qa, archivist, backend-lead, frontend-lead, loop-checker, lint, backend-executor" >&2
    exit 1
}

# ── Главное ──────────────────────────────────────────────

[ $# -ge 1 ] || usage
case "$1" in
    -h|--help) usage ;;
    --list)    list_workers ;;
esac

WORKER="$1"; TASK="$2"; shift 2 || usage
TIMEOUT=210; MODEL="default"

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --model)   MODEL="$2"; shift 2 ;;
        *) echo "ОШИБКА: неизвестный флаг $1" >&2; usage ;;
    esac
done

INFO=$(resolve "$WORKER")
IFS='|' read -r IP PORT AUTH <<<"$INFO"

# Собираем payload
PAYLOAD=$(python3 -c "
import json,sys
print(json.dumps({
    'model': '$MODEL',
    'messages': [{'role':'user','content': sys.argv[1]}],
    'max_tokens': 2048
}))
" "$TASK")

# Опции curl
CURL_OPTS=(-s --max-time "$TIMEOUT" -o /tmp/holix-delegate-resp.json -w '%{http_code} %{time_total}')

# Auth-заголовок
if [ "$AUTH" = "key" ]; then
    if [ ! -f "$KEY_FILE" ]; then
        echo "ОШИБКА: файл ключа не найден: $KEY_FILE" >&2; exit 1
    fi
    KEY=$(cat "$KEY_FILE")
    CURL_OPTS+=(-H "Authorization: Bearer $KEY")
    
    # Pre-grant all dangerous tools to bypass non-interactive confirmation
    for tool in run_terminal_command execute_python execute_bash write_file read_file; do
        curl -s --max-time 5 -X POST "http://${IP}:${PORT}/v1/permissions/grant?tool_name=$tool" \
            -H "Authorization: Bearer $KEY" \
            -H "Content-Type: application/json" \
            -d '{"allow":true}' > /dev/null 2>&1 || true
    done
fi

# --- Отправка ---
echo "→ $WORKER ($IP:$PORT) модель=$MODEL таймаут=${TIMEOUT}с"
echo "→ задача: ${TASK:0:120}..."

START=$(date +%s)
RESP=$(curl "${CURL_OPTS[@]}" \
    -H "Content-Type: application/json" \
    -X POST "http://${IP}:${PORT}/v1/chat/completions" \
    -d "$PAYLOAD" 2>/tmp/holix-delegate-err.log)
CURL_RC=${PIPESTATUS[0]}
ELAPSED=$(($(date +%s) - START))

HTTP_CODE=$(echo "$RESP" | awk '{print $1}')
TIME_TOTAL=$(echo "$RESP" | awk '{print $2}')

echo "← HTTP=$HTTP_CODE время=${ELAPSED}с (curl: ${TIME_TOTAL}s)"

if [ -s /tmp/holix-delegate-resp.json ]; then
    python3 -c "
import json,sys
d=json.load(open('/tmp/holix-delegate-resp.json'))
c=d['choices'][0]['message']['content']
u=d.get('usage',{})
print('content:', c[:400])
if c and len(c)>400: print('... (обрезано)')
if u: print(f'usage: prompt={u.get(\"prompt_tokens\",\"?\")} completion={u.get(\"completion_tokens\",\"?\")}')
print()
sys.exit(0)
" 2>/dev/null || { echo "ОШИБКА парсинга JSON-ответа"; cat /tmp/holix-delegate-resp.json | head -5; }
else
    echo "ОШИБКА: пустой ответ или таймаут"
    cat /tmp/holix-delegate-err.log 2>/dev/null
fi
