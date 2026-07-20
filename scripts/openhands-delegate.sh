#!/usr/bin/env bash
# openhands-delegate.sh — отправить задачу OpenHands через HTTP API
# Использование:
#   openhands-delegate.sh "<задача>" [--timeout N]
#   openhands-delegate.sh --list                    # показать последние conversаций
#   openhands-delegate.sh --help
#
# Вывод: conversation_id, статус, время, ответ агента
set -euo pipefail

OPENHANDS_URL="${OPENHANDS_URL:-http://127.0.0.1:3000}"
TIMEOUT=300

usage() {
    cat <<'EOF' >&2
openhands-delegate.sh "<задача>" [--timeout N]
openhands-delegate.sh --list
openhands-delegate.sh --help

Отправляет задачу агенту OpenHands (оутсорс-подрядчик) и ждёт результат.
EOF
    exit 0
}

list_sessions() {
    echo "=== OpenHands Conversations ==="
    curl -s --max-time 10 "${OPENHANDS_URL}/api/conversations" \
        -H "Accept: application/json" | \
        python3 -c "
import sys, json
data = json.load(sys.stdin)
for c in data.get('results', [])[:10]:
    print(f\"  {c['conversation_id'][:12]}... {c['status']:8s} {c.get('title','?')[:60]}\")
"
    exit 0
}

[ $# -ge 1 ] || usage
case "$1" in
    -h|--help) usage ;;
    --list)    list_sessions ;;
esac

TASK="$1"; shift

while [ $# -gt 0 ]; do
    case "$1" in
        --timeout) TIMEOUT="$2"; shift 2 ;;
        *) echo "ERROR: unknown flag $1" >&2; usage ;;
    esac
done

# 1. Create conversation
echo "→ OpenHands: creating conversation..."
CID=$(curl -s --max-time 10 -X POST "${OPENHANDS_URL}/api/conversations" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d '{}' | python3 -c "import sys,json; print(json.load(sys.stdin)['conversation_id'])")

echo "→ Conversation: $CID"

# 2. Send task
echo "→ Task: ${TASK:0:120}..."
START=$(date +%s)

RESP=$(curl -s --max-time "$TIMEOUT" -X POST "${OPENHANDS_URL}/api/conversations/$CID/message" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "$(python3 -c "import json,sys; print(json.dumps({'message': sys.argv[1]}))" "$TASK")")

ELAPSED=$(($(date +%s) - START))

# 3. Parse response
echo "$RESP" | python3 -c "
import sys, json, time
data = json.load(sys.stdin)
status = data.get('status', 'unknown')
print(f'Status: {status}')
print(f'Time: ${ELAPSED}s')
if status == 'ok':
    msgs = data.get('messages', [])
    if msgs:
        last = msgs[-1]
        content = last.get('content', '')
        print(f'Response ({len(content)} chars):')
        print(content[:2000])
else:
    print(f'Error: {data.get(\"error\", \"unknown\")}')
" 2>&1

echo "→ Done. Conversation: $CID"
