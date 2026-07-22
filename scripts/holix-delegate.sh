#!/usr/bin/env bash
# holix-delegate.sh — отправить задачу holix-воркеру
# Использование:
#   holix-delegate.sh <воркер> "<задача>" [--timeout N] [--model MODEL]
#   holix-delegate.sh --list
#   holix-delegate.sh --help
#
# Воркеры:
#   coordinator     — через docker exec holix run (основной, v4-pro)
#   python-dev, react-dev, qa, archivist,
#   backend-lead, frontend-lead, loop-checker,
#   lint, backend-executor
#                   — через HTTP API (docker-сеть, studio-net)
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KEY_FILE="${SCRIPT_DIR}/../.holix-hermes-key.txt"
TIMEOUT=210
MODEL=""

usage() {
    cat <<'HELP'
Использование:
  holix-delegate.sh <воркер> "<задача>" [--timeout N] [--model MODEL]
  holix-delegate.sh --list
  holix-delegate.sh --help

Воркеры: coordinator, python-dev, react-dev, qa, archivist,
         backend-lead, frontend-lead, loop-checker, lint, backend-executor

Примеры:
  holix-delegate.sh coordinator "Напиши функцию сложения a+b на Python"
  holix-delegate.sh python-dev "Напиши тесты для auth.py" --timeout 300
HELP
    exit 0
}

list_workers() {
    echo "Воркеры Holix:"
    echo "  coordinator       docker exec holix-coordinator holix run  (v4-pro, оркестратор)"
    echo "  python-dev        172.20.0.45:8000  (v4-flash)"
    echo "  react-dev         172.20.0.46:8000  (v4-flash)"
    echo "  qa                172.20.0.47:8000  (v4-flash)"
    echo "  archivist         172.20.0.42:8000  (v4-flash)"
    echo "  backend-lead      172.20.0.43:8000  (v4-flash)"
    echo "  frontend-lead     172.20.0.44:8000  (v4-flash)"
    echo "  loop-checker      172.20.0.48:8000  (v4-flash)"
    echo "  lint              172.20.0.49:8000  (v4-flash)"
    echo "  backend-executor  172.18.0.14:8000  (v4-flash)"
    exit 0
}

# ── Главное ──────────────────────────────────────────────
[ $# -ge 1 ] || usage
case "$1" in
    -h|--help) usage ;;
    --list)    list_workers ;;
esac

WORKER="$1"; TASK="$2"; shift 2 || usage

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        --model)   MODEL="$2"; shift 2 ;;
        *) echo "ОШИБКА: неизвестный флаг $1" >&2; usage ;;
    esac
done

START=$(date +%s)

# ── Coordinator: docker exec holix run ───────────────────
if [ "$WORKER" = "coordinator" ]; then
    echo "→ coordinator (docker exec holix run) ${MODEL:+model=$MODEL} timeout=${TIMEOUT}s"
    echo "→ задача: ${TASK:0:120}..."

    CMD="docker exec holix-coordinator holix run"
    [ -n "$MODEL" ] && CMD="$CMD --model $MODEL"
    CMD="$CMD $(printf '%q' "$TASK")"

    OUTPUT=$(timeout "$TIMEOUT" bash -c "$CMD" 2>&1) || true
    ELAPSED=$(($(date +%s) - START))

    # Извлекаем ответ агента (всё после "🤖 Holix:")
    RESPONSE=$(echo "$OUTPUT" | sed -n '/🤖 Holix:/,$ p' | sed '1s/.*🤖 Holix: //')
    if [ -z "$RESPONSE" ]; then
        RESPONSE=$(echo "$OUTPUT" | tail -5)
    fi

    echo "← время=${ELAPSED}s"
    echo "$RESPONSE"
    exit 0
fi

# ── Остальные воркеры: HTTP API ─────────────────────────
# Карта воркеров
case "$WORKER" in
    python-dev)       IP=172.20.0.45; PORT=8000; AUTH=no ;;
    react-dev)        IP=172.20.0.46; PORT=8000; AUTH=no ;;
    qa)               IP=172.20.0.47; PORT=8000; AUTH=no ;;
    archivist)        IP=172.20.0.42; PORT=8000; AUTH=no ;;
    backend-lead)     IP=172.20.0.43; PORT=8000; AUTH=no ;;
    frontend-lead)    IP=172.20.0.44; PORT=8000; AUTH=no ;;
    loop-checker)     IP=172.20.0.48; PORT=8000; AUTH=no ;;
    lint)             IP=172.20.0.49; PORT=8000; AUTH=no ;;
    backend-executor) IP=172.18.0.14; PORT=8000; AUTH=no ;;
    *) echo "ОШИБКА: неизвестный воркер '$WORKER'" >&2; exit 1 ;;
esac

PAYLOAD=$(python3 -c "
import json,sys
m = '$MODEL' if '$MODEL' else 'deepseek-v4-flash'
print(json.dumps({'model':m,'messages':[{'role':'user','content':sys.argv[1]}],'max_tokens':2048}))
" "$TASK")

echo "→ $WORKER ($IP:$PORT) модель=${MODEL:-v4-flash} timeout=${TIMEOUT}s"
echo "→ задача: ${TASK:0:120}..."

RESP=$(curl -s --max-time "$TIMEOUT" -X POST "http://${IP}:${PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD" 2>&1)
ELAPSED=$(($(date +%s) - START))

echo "← время=${ELAPSED}s"

echo "$RESP" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    c=d.get('choices',[{}])[0].get('message',{}).get('content','')
    if c: print(c[:2000])
    else: print(json.dumps(d)[:500])
except: print(sys.stdin.read()[:500])
" 2>/dev/null || echo "$RESP" | head -5
