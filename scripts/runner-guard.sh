#!/bin/bash
# Страж раннеров GitHub Actions: раннеры VM уходят в broker-backoff (сетевые обрывы
# к GitHub: SocketException Operation canceled) и перестают брать джобы на часы.
# Каждые 4 мин проверяем свежий Runner-лог на «Back off»/«SocketException» — если
# найдено после последней проверки, перезапускаем юниты (сброс backoff).
# Запуск: nohup bash ~/studio/scripts/runner-guard.sh >> ~/studio/logs/runner-guard.log 2>&1 &
LOG_DIR="$HOME/actions-runner/_diag"
LAST_CHECK=""
while true; do
  sleep 240
  LOG=$(ls -t "$LOG_DIR"/Runner_*.log 2>/dev/null | head -1)
  [ -z "$LOG" ] && continue
  NEW=$(stat -c %Y "$LOG")
  if [ -n "$LAST_CHECK" ] && [ "$NEW" -gt "$LAST_CHECK" ]; then
    if grep -qE "Back off [0-9]{4,} seconds|SocketException \(125\)" "$LOG"; then
      # Не рестартовать, если раннер прямо сейчас выполняет джобу — иначе убиваем
      # её mid-build («The runner has received a shutdown signal»). Рестарт только
      # когда раннер простаивает (нет Worker-процесса).
      if pgrep -f 'Runner.Worker' >/dev/null 2>&1; then
        echo "$(date '+%F %T') backoff detected, but job in progress — skipping restart"
      else
        echo "$(date '+%F %T') backoff detected in $(basename "$LOG") — restarting runners"
        systemctl --user restart actions-runner actions-runner-2
      fi
    fi
  fi
  LAST_CHECK=$(date +%s)
done
