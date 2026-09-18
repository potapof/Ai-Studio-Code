#!/bin/bash
# studio-model-switch.sh — переключение модели всей Студии: подписка OpenCode Go ↔ DeepSeek API.
#
#   auto      OpenCode Go основной, релей сам уходит на DeepSeek при сбое/квоте (по умолчанию)
#   go        только OpenCode Go, отката нет (ошибки подписки видны клиенту как есть)
#   deepseek  жёстко DeepSeek: релей вовсе не обращается к Go, Hermes переходит на провайдера deepseek
#   status    текущее состояние (режим, health релея, модель Hermes, живой смоук)
#
# Кого переключает:
#   1. релей :8012 — drop-in systemd zen-go-relay.service.d/mode.conf + рестарт
#      (через релей ходят dsh, OpenHands, open-code-review, Holix — им отдельное переключение не нужно)
#   2. Hermes — hermes config set (model.provider / model.default); файл конфига не патчим
#   3. резервная цепочка Hermes (fallback_providers → deepseek) — постоянная, режимами не снимается
#
# Живой смоук в конце обязателен: скрипт без ответа модели считается неуспешным.
set -uo pipefail

DROPIN_DIR="$HOME/.config/systemd/user/zen-go-relay.service.d"
DROPIN="$DROPIN_DIR/mode.conf"
HEALTH="http://127.0.0.1:8012/health"
GO_MODEL="deepseek-v4.1-flash"
GO_URL="https://opencode.ai/zen/go/v1"
DS_MODEL="deepseek-v4-flash-vision-exp"      # резервная модель на api.deepseek.com
DS_URL="https://api.deepseek.com"
TIMEOUT="${STUDIO_SWITCH_TIMEOUT:-180}"

fail() { echo "ОШИБКА: $*" >&2; exit 1; }

current_mode() {
  grep -h '^Environment=ZEN_RELAY_MODE=' "$DROPIN" 2>/dev/null | tail -1 | cut -d= -f3
}

hermes_switch() {  # $1 = go | deepseek
  local provider model url
  if [ "$1" = "deepseek" ]; then provider=deepseek; model="$DS_MODEL"; url="$DS_URL"
  else provider=opencode-go; model="$GO_MODEL"; url="$GO_URL"; fi
  hermes config set model.provider "$provider" >/dev/null || fail "hermes config set model.provider"
  hermes config set model.default "$model"    >/dev/null || fail "hermes config set model.default"
  hermes config set model.base_url "$url"     >/dev/null || fail "hermes config set model.base_url"
}

relay_restart() {  # $1 = режим
  mkdir -p "$DROPIN_DIR"
  printf '# Режим выдаваемой модели (управляется ~/studio/scripts/studio-model-switch.sh)\n[Service]\nEnvironment=ZEN_RELAY_MODE=%s\n' "$1" > "$DROPIN"
  systemctl --user daemon-reload
  systemctl --user restart zen-go-relay.service || fail "рестарт zen-go-relay.service"
  for _ in $(seq 1 20); do
    curl -s --max-time 3 "$HEALTH" | grep -q '"status":"ok"' && return 0
    sleep 1
  done
  fail "релей :8012 не поднялся (journalctl --user -u zen-go-relay -n 30)"
}

smoke() {  # живой ответ модели через релей + признак, кто ответил
  local out code hdr
  out=$(curl -s -m "$TIMEOUT" -D /tmp/studio-switch-hdr.txt -X POST http://127.0.0.1:8012/v1/chat/completions \
        -H 'Content-Type: application/json' \
        -d "{\"model\":\"$GO_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: SWITCH-OK\"}],\"max_tokens\":200}")
  code=$(grep -m1 -oE 'HTTP/1.1 [0-9]+' /tmp/studio-switch-hdr.txt | awk '{print $2}')
  if grep -qi '^x-zen-relay-fallback: deepseek' /tmp/studio-switch-hdr.txt; then hdr="DeepSeek (откат)"; else hdr="OpenCode Go (основной)"; fi
  echo "  смоук: HTTP ${code:-нет} · ответила: $hdr"
  echo "$out" | python3 -c "import sys,json;d=json.load(sys.stdin);print('  content:',repr(d['choices'][0]['message'].get('content')),'| model:',d.get('model'))" 2>/dev/null \
    || { echo "  тело ответа: $(echo "$out" | head -c 300)"; return 1; }
}

show_status() {
  local m; m=$(current_mode); m=${m:-auto (из юнита по умолчанию)}
  echo "Режим релея: $m"
  curl -s --max-time 5 "$HEALTH" | python3 -m json.tool 2>/dev/null || echo "  релей недоступен"
  echo "Hermes:"; hermes fallback list 2>/dev/null | sed 's/^/  /'
}

case "${1:-status}" in
  go|auto|deepseek)
    MODE="$1"
    echo "=== переключение Студии в режим: $MODE"
    relay_restart "$MODE"
    if [ "$MODE" = "deepseek" ]; then hermes_switch deepseek; else hermes_switch go; fi
    echo "  релей перезапущен, Hermes: provider=$(hermes config get model.provider 2>/dev/null | tail -1) model=$(hermes config get model.default 2>/dev/null | tail -1)"
    smoke || fail "модель не ответила через релей — Студия не готова"
    echo "  режим применён: ${MODE}"
    ;;
  status)
    show_status
    smoke || echo "  ВНИМАНИЕ: смоук не прошёл"
    ;;
  *)
    echo "Использование: $0 {auto|go|deepseek|status}" >&2; exit 2;;
esac
