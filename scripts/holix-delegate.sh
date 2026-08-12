#!/usr/bin/env bash
# holix-delegate.sh — отправить задачу holix-воркеру (HOST-архитектура, 2026-08)
# Использование:
#   holix-delegate.sh <воркер> "<задача>" [--timeout N] [--model MODEL]
#   holix-delegate.sh --list
#   holix-delegate.sh --help
#
# Воркеры (host, ~/.holix-host):
#   coordinator     — через holix run CLI (venv, v4-pro, проверено — работает)
#   python-dev, react-dev, qa, archivist,
#   backend-lead, frontend-lead, loop-checker,
#   lint, backend-executor
#                   — через HTTP API gateway 127.0.0.1:8010 (X-Holix-Profile)
#
# ВАЖНО (2026-08-10): gateway API /v1/chat/completions на тривиальных запросах
# возвращает пустой content ("Agent completed without producing a final
# response"), а на задачах с инструментами (write_file/run_terminal_command)
# ЗАВИСАЕТ. Рабочий путь — `holix run` (CLI one-shot, ~40s). Для воркеров
# gateway API использовать с осторожностью: задачи с инструментами могут
# зависнуть до --timeout.
set -euo pipefail
IFS=$'\n\t'

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VENV_HOLIX="${SCRIPT_DIR}/../.venv/bin/holix"
HOLIX_HOME="${HOLIX_HOME:-$HOME/.holix-host}"
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
    echo "Воркеры Holix (host, ~/.holix-host):"
    echo "  coordinator      holix run CLI (venv)           (v4-pro, оркестратор)"
    echo "  python-dev       gateway :8010 X-Holix-Profile  (v4-flash)"
    echo "  react-dev        gateway :8010 X-Holix-Profile  (v4-flash)"
    echo "  qa               gateway :8010 X-Holix-Profile  (v4-flash)"
    echo "  archivist        gateway :8010 X-Holix-Profile  (v4-flash)"
    echo "  backend-lead     gateway :8010 X-Holix-Profile  (v4-flash)"
    echo "  frontend-lead    gateway :8010 X-Holix-Profile  (v4-flash)"
    echo "  loop-checker     gateway :8010 X-Holix-Profile  (v4-flash)"
    echo "  lint             gateway :8010 X-Holix-Profile  (v4-flash)"
    echo "  backend-executor gateway :8010 X-Holix-Profile  (v4-flash)"
    echo ""
    echo "PITFALL: gateway API виснет на задачах с инструментами (write_file/"
    echo "run_terminal_command). Надёжный путь — holix run (CLI)."
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

# ── Coordinator: holix run CLI (host venv) ───────────────
if [ "$WORKER" = "coordinator" ]; then
    echo "→ coordinator (holix run CLI) ${MODEL:+model=$MODEL} timeout=${TIMEOUT}s"
    echo "→ задача: ${TASK:0:120}..."

    CMD=("$VENV_HOLIX" run)
    [ -n "$MODEL" ] && CMD+=(--model "$MODEL")
    CMD+=("$TASK")

    OUTPUT=$(HOLIX_HOME="$HOLIX_HOME" timeout "$TIMEOUT" "${CMD[@]}" 2>&1) || true
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

# ── Остальные воркеры: HTTP API gateway (host :8010) ────
case "$WORKER" in
    python-dev|react-dev|qa|archivist|backend-lead|frontend-lead|loop-checker|lint|backend-executor) ;;
    *) echo "ОШИБКА: неизвестный воркер '$WORKER' (см. --list)" >&2; exit 1 ;;
esac

GATEWAY="http://127.0.0.1:8010"
KEY=""
[ -f "$KEY_FILE" ] && KEY=$(cat "$KEY_FILE")

PAYLOAD=$(python3 -c "
import json,sys
m = '$MODEL' if '$MODEL' else 'deepseek-v4-flash'
print(json.dumps({'model':'holix','messages':[{'role':'user','content':sys.argv[1]}],'max_tokens':2048}))
" "$TASK")

echo "→ $WORKER (gateway :8010, X-Holix-Profile) модель=${MODEL:-v4-flash} timeout=${TIMEOUT}s"
echo "→ задача: ${TASK:0:120}..."

CURL_ARGS=(--max-time "$TIMEOUT" -X POST "$GATEWAY/v1/chat/completions"
    -H "Content-Type: application/json"
    -H "X-Holix-Profile: $WORKER")
[ -n "$KEY" ] && CURL_ARGS+=(-H "Authorization: Bearer ${KEY}")

RESP=$(curl -s "${CURL_ARGS[@]}" -d "$PAYLOAD" 2>&1)
ELAPSED=$(($(date +%s) - START))

echo "← время=${ELAPSED}s"

echo "$RESP" | python3 -c "
import json,sys
try:
    d=json.load(sys.stdin)
    c=d.get('choices',[{}])[0].get('message',{}).get('content','')
    if c: print(c[:2000])
    else: print('(пустой ответ — известный баг gateway; используйте holix run)')
except: print(sys.stdin.read()[:500])
" 2>/dev/null || echo "$RESP" | head -5
