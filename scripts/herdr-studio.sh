#!/bin/bash
# Запуск «Студии программирования» через herdr
# Предварительно разогревает Holix-агентов и открывает workspace MAXSCRM

set -e

HERDR=$(which herdr)
STUDIO=~/studio
MAXSCRM=~/studio/projects/maxscrm/repo

echo "=== Студия программирования — herdr launch ==="

# 1. Проверяем herdr сервер (должен быть запущен вручную в отдельном терминале)
if ! $HERDR status 2>/dev/null | grep -q "running"; then
  echo "⚠️  Herdr сервер не запущен."
  echo "   Открой новый терминал и выполни: herdr"
  echo "   Затем перезапусти этот скрипт."
  exit 1
fi
echo "✓ Herdr сервер: запущен"

# 2. Создаём workspace MAXSCRM если нет
if ! $HERDR workspace list 2>/dev/null | grep -q "maxscrm"; then
  echo "Creating maxscrm workspace..."
  $HERDR workspace create --cwd "$MAXSCRM" --label "MAXSCRM" --env "PATH=$PATH" &
fi

# 3. Ждём инициализации
sleep 2

# 4. Запускаем backend в pane 1
echo "Launching backend pane..."
$HERDR agent start "backend" --kind hermes --pane 1 --timeout 30000 -- \
  bash -c "cd $MAXSCRM/apps/backend && npx nest start --watch 2>&1" &

# 5. Запускаем фронтенд в pane 2
echo "Launching frontend pane..."
$HERDR agent start "frontend" --kind hermes --pane 2 --timeout 30000 -- \
  bash -c "cd $MAXSCRM/apps/frontend && npx vite --host 2>&1" &

# 6. Разогреваем Holix gateway в pane 3
if [ -f "$STUDIO/.venv/bin/holix" ]; then
  echo "Pre-warming Holix gateway (60-90s)..."
  $HERDR agent start "holix-gw" --kind hermes --pane 3 --timeout 120000 -- \
    bash -c "
      export HOLIX_HOME=~/.holix-host
      export DEEPSEEK_API_KEY=\$(grep DEEPSEEK_API_KEY $STUDIO/.env | cut -d= -f2)
      require_auth=false auto_allow_threshold=high $STUDIO/.venv/bin/holix gateway start --port 8010 2>&1
    " &
fi

sleep 3
echo "=== Готово ==="
echo "herdr запущен. Подключиться: herdr"
echo "MAXSCRM: http://localhost:5174/s/test-shop"
echo "Holix: http://localhost:8010 (если запущен)"
