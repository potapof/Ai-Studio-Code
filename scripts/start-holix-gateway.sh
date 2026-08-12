#!/bin/bash
# Запуск Holix Gateway
# Ключ API и настройки читаются из ~/.holix-host/profiles/default/.env и config.yaml
export HOLIX_HOME="$HOME/.holix-host"
# ReAct-агент НЕсовместим с reasoning-моделью (пустой content) — легаси-путь вместо LangGraph
export USE_LANGGRAPH=false
# Разблокировка инструментов (два слоя safety, стандарт docker-конфига):
# confirmation-гейт иначе ВЕШАЕТ write_file/run_terminal_command (проверено 2026-08-12)
export AUTO_ALLOW_THRESHOLD=high
export HOLIX_TERMINAL_COMMAND_WHITELIST=false
export NON_INTERACTIVE=true
export CONFIRMATION_TIMEOUT=30
exec "$HOME/studio/.venv/bin/holix" gateway start --port 8010
