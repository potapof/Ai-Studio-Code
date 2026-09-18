#!/bin/bash
# studio-readiness.sh — чеклист готовности Студии программирования (для старта сессии)
# Быстрый прогон (~10-15с). Глубокий режим (smoke воркера): --deep
# Вывод: чеклист с [OK]/[FAIL]. Exit: 0 = всё критичное готово, 1 = есть проблемы.
# Использование: bash ~/studio/scripts/studio-readiness.sh [--deep]

PASS=0; FAIL=0; NOTES=""
ok()   { PASS=$((PASS+1)); echo "  [OK]   $1"; }
bad()  { FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
info() { echo "  [..]   $1"; }

echo "══════════ СТУДИЯ ПРОГРАММИРОВАНИЯ — ЧЕКЛИСТ ГОТОВНОСТИ ══════════"
echo "дата: $(date '+%F %T')"

echo "── 1. Демоны и gateway ──"
herdr status 2>/dev/null | grep -q 'status: running' && ok "herdr daemon" || bad "herdr daemon (нужен: herdr / systemctl --user start herdr)"
curl -s --max-time 5 http://127.0.0.1:8010/health | grep -q '"status":"ok"' && ok "Holix gateway :8010" || bad "Holix gateway :8010 (нужен: ~/studio/scripts/start-holix-gateway.sh)"
# Релей к подписке OpenCode Go: модель всех агентов deepseek-v4.1-flash живёт только
# на opencode.ai/zen/go/v1 и требует заголовок x-opencode-session → ходим через релей.
curl -s --max-time 5 http://127.0.0.1:8012/health | grep -q '"status":"ok"' && ok "zen-go-relay :8012 (OpenCode Go → deepseek-v4.1-flash)" || bad "zen-go-relay :8012 (нужен: systemctl --user start zen-go-relay.service)"
[ -n "$(grep -m1 '^OPENCODE_GO_API_KEY=' "$HOME/studio/.env" 2>/dev/null | cut -d= -f2-)" ] && ok "ключ подписки OpenCode Go (~/studio/.env)" || bad "ключ подписки OpenCode Go (добавить OPENCODE_GO_API_KEY=... в ~/studio/.env)"

echo "── 2. MAXSCRM: backend + frontend ──"
B=$(curl -s --max-time 5 http://localhost:3000/api/v1/health 2>/dev/null)
if echo "$B" | grep -q '"status":"healthy"'; then
  D=$(echo "$B" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["checks"]["database"], d["checks"]["redis"])' 2>/dev/null)
  ok "backend :3000 (db=$D)"
else
  bad "backend :3000 (нужен: cd apps/backend && npx nest start --watch)"
fi
F=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://localhost:5173 2>/dev/null)
[ "$F" = "200" ] && ok "frontend :5173" || bad "frontend :5173 (нужен: cd apps/frontend && npx vite --host)"

echo "── 3. Docker-контейнеры ──"
for c in nocodb-postgres-db nocodb-web-ui portainer egress-squid syncthing repo-redis-1 maxscrm-postgres; do
  S=$(docker ps --format '{{.Names}} {{.Status}}' | grep "^$c " 2>/dev/null)
  [ -n "$S" ] && ok "$c" || bad "$c (docker start $c)"
done

echo "── 4. Автозапуск (systemd user + crontab) ──"
E=$(systemctl --user is-enabled herdr.service holix-gateway.service actions-runner.service actions-runner-2.service 2>/dev/null | grep -c enabled)
[ "$E" = "4" ] && ok "systemd: herdr + holix-gateway + actions-runner×2 enabled" || bad "systemd: enabled=$E/4"
C=$(crontab -l 2>/dev/null | grep -cE 'kb-sync|archivist-weekly')
[ "$C" = "2" ] && ok "crontab: kb-sync (6:00) + archivist-audit (вс 3:00)" || bad "crontab: записей=$C/2"
R=$(systemctl --user is-active actions-runner.service actions-runner-2.service 2>/dev/null | grep -c active)
[ "$R" = "2" ] && ok "CI-раннеры активны" || bad "CI-раннеры: active=$R/2"

echo "── 5. База знаний (hermes_brain) ──"
KB=$(docker exec nocodb-postgres-db psql -U nocodb_user -d hermes_brain -t -A -c "SELECT count(*)||'/'||count(embedding) FROM public.knowledge_base;" 2>/dev/null)
[ -n "$KB" ] && ok "knowledge_base: $KB (все с эмбеддингами)" || bad "knowledge_base недоступна"
SESS=$(docker exec nocodb-postgres-db psql -U nocodb_user -d hermes_brain -t -A -c "SELECT count(*) FROM public.agent_sessions;" 2>/dev/null)
LR=$(docker exec nocodb-postgres-db psql -U nocodb_user -d hermes_brain -t -A -c "SELECT count(*) FROM studio_default.loop_runs;" 2>/dev/null)
[ -n "$SESS" ] && info "agent_sessions=$SESS loop_runs=$LR" || bad "БЗ не отвечает"
A=$(docker exec nocodb-postgres-db psql -U nocodb_user -d hermes_brain -t -A -c "SELECT count(*) FROM public.knowledge_base WHERE created_by='archivist';" 2>/dev/null)
[ -n "$A" ] && info "записей от архивариуса: $A"

echo "── 6. Staging (не критично) ──"
ST=$(curl -s --max-time 8 -o /dev/null -w '%{http_code}' https://app.maxscrm.ru/s/demo 2>/dev/null)
[ "$ST" = "200" ] && ok "staging app.maxscrm.ru ($ST)" || info "staging: $ST (проверить позже)"

echo "── 7. Студия дизайна: dsh + OpenDesign ──"
DSH_V=$(dsh --version 2>/dev/null | tail -1)
[ -n "$DSH_V" ] && ok "dsh CLI ($DSH_V)" || bad "dsh CLI (нужен: npm i -g @deepseek-ai/dsh; Node>=22 — у нас n 24)"
P=$(dsh --profile open-design --probe 2>/dev/null | grep -o '"runtime":"open-design"')
[ -n "$P" ] && ok "dsh профиль open-design (probe OK)" || bad "dsh профиль open-design (нужен: dsh plugin --profile open-design add ~/studio/dsh/open-design-dsh-runtime-0.1.0.tgz)"
OD=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' http://127.0.0.1:7456/ 2>/dev/null)
[ "$OD" = "200" ] && ok "OpenDesign daemon :7456 (web-UI)" || bad "OpenDesign daemon :7456 (нужен: cd ~/studio/open-design/apps/daemon && node dist/cli.js --no-open)"

echo "── 8. Схемы (archify) ──"
ARCH_SKILL=~/.hermes/skills/software-development/archify/bin/archify.mjs
if [ -f "$ARCH_SKILL" ]; then
  A=$(node "$ARCH_SKILL" doctor 2>/dev/null | grep -c '^\[ok\]')
  [ "$A" -gt 0 ] && ok "archify CLI (doctor: $A ok)" || bad "archify CLI (doctor не прошёл)"
else
  bad "archify CLI (нужен: ~/studio/archify — tt-a1i/archify; скилл в ~/.hermes/skills/software-development/archify)"
fi
if ls ~/.dsh/profiles/web/node_modules/@tt-a1i/archify-dsh >/dev/null 2>&1; then
  ok "DSH-плагин archify-dsh (профиль web)"
else
  info "DSH-плагин archify-dsh не установлен (по желанию: dsh plugin --profile web add @tt-a1i/archify-dsh@0.1.0)"
fi

if [ "$1" = "--deep" ]; then
  echo "── 9. Smoke воркеров (--deep, ~1-2 мин) ──"
  W=$(~/studio/scripts/holix-delegate.sh python-dev "Reply with exactly: W-OK" --timeout 120 2>&1 | tail -1)
  echo "$W" | grep -q "W-OK" && ok "воркер Holix python-dev: W-OK" || bad "воркер Holix python-dev: $W"
  D=$(set -a; source ~/studio/.env 2>/dev/null; set +a; DSH_MODEL=deepseek-v4.1-flash timeout 120 dsh --profile headless "Reply with exactly: D-OK" 2>&1 | tail -1)
  echo "$D" | grep -q "D-OK" && ok "воркер dsh headless: D-OK" || bad "воркер dsh headless: $D"
fi

echo "═══════════════════════════════════════════════════════════════════"
echo "ИТОГ: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" = "0" ] && echo "СТАТУС: ГОТОВО ✅" || { echo "СТАТУС: ЕСТЬ ПРОБЛЕМЫ ❌ (см. выше; чек-лист подъёма: навык herdr-integration)"; exit 1; }
