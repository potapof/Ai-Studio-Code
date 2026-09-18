#!/bin/bash
# Запуск Holix Gateway
# Ключ API и настройки читаются из ~/.holix-host/profiles/default/.env и config.yaml
export HOLIX_HOME="$HOME/.holix-host"
# Ключ подписки OpenCode Go: подставляется в профили как ${ENV:OPENCODE_GO_API_KEY}
# (base_url профилей → релей zen-go-relay :8012, модель deepseek-v4.1-flash).
# Источник ключа — ~/studio/.env (файл .opencode-go-key.txt удалён 2026-09-18).
if [ -r "$HOME/studio/.env" ]; then
  OPENCODE_GO_API_KEY=$(grep -m1 '^OPENCODE_GO_API_KEY=' "$HOME/studio/.env" | cut -d= -f2-)
  export OPENCODE_GO_API_KEY
fi
# ReAct-агент НЕсовместим с reasoning-моделью (пустой content) — легаси-путь вместо LangGraph
export USE_LANGGRAPH=false
# Разблокировка инструментов (два слоя safety, стандарт docker-конфига):
# confirmation-гейт иначе ВЕШАЕТ write_file/run_terminal_command (проверено 2026-08-12)
export AUTO_ALLOW_THRESHOLD=high
export HOLIX_TERMINAL_COMMAND_WHITELIST=false
export NON_INTERACTIVE=true
export CONFIRMATION_TIMEOUT=30
exec "$HOME/studio/.venv/bin/holix" gateway start --port 8010
