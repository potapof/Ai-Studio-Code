#!/bin/bash
# Цикл деплоя staging с обходом rate-limit codeload (429): dispatch → поллинг ранна →
# если failure (429 на скачивании экшенов) → пауза 10 мин → повтор. До 6 попыток.
cd /home/potapof/studio/projects/maxscrm/repo || exit 1
TOKEN=$(git remote get-url origin | sed -E 's#https://x-access-token:([^@]+)@.*#\1#')
API="https://api.github.com/repos/maxscrmru/maxscrm"
for attempt in 1 2 3 4 5 6 7 8; do
  echo "$(date '+%F %T') attempt $attempt: cancel stale runs + dispatch"
  # Отменяем зависшие (in_progress/pending) ранны группы — иначе concurrency
  # блокирует очередь (cancel-in-progress: false), а мёртвые раннеры не завершают ранны
  for STALE in $(curl -s -m 15 -H "Authorization: Bearer $TOKEN" "$API/actions/workflows/deploy-staging.yml/runs?per_page=10" | \
    python3 -c "
import json,sys
try:
    for r in json.load(sys.stdin)['workflow_runs']:
        if r['status'] in ('in_progress','queued','pending') and r['created_at'] > '2026-08-17T00:00:00Z':
            print(r['id'])
except Exception: pass
" 2>/dev/null); do
    curl -s -o /dev/null -w "cancel $STALE: %{http_code}\n" -X POST -H "Authorization: Bearer $TOKEN" \
      -H "Accept: application/vnd.github+json" "$API/actions/runs/$STALE/cancel"
  done
  sleep 5
  code=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.github+json" "$API/actions/workflows/deploy-staging.yml/dispatches" -d '{"ref":"develop"}')
  [ "$code" != "204" ] && { echo "  dispatch HTTP $code, sleep 30"; sleep 30; continue; }
  RID=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/actions/workflows/deploy-staging.yml/runs?per_page=1" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['workflow_runs'][0]['id'])")
  echo "  run $RID"
  # Поллинг до завершения (макс 45 мин)
  for i in $(seq 1 135); do
    sleep 20
    ST=$(curl -s -H "Authorization: Bearer $TOKEN" "$API/actions/runs/$RID" | \
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'], d.get('conclusion'))" 2>/dev/null)
    case "$ST" in completed*) break;; esac
  done
  echo "  $ST"
  case "$ST" in *success*) echo "DEPLOY SUCCESS"; exit 0;; esac
  echo "  waiting 600s before retry"
  sleep 600
done
echo "DEPLOY FAILED after 8 attempts"
exit 1
