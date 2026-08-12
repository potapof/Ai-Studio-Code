#!/usr/bin/env bash
# log-agent-session.sh — записать сессию агента в hermes_brain.agent_sessions
# Использование:
#   log-agent-session.sh <agent> [status=completed] [model] [tokens_in] [tokens_out] [cost]
# Пример:
#   log-agent-session.sh python-dev completed deepseek-v4-flash 12000 800 0.02
set -euo pipefail

AGENT="${1:?usage: log-agent-session.sh <agent> [status] [model] [tin] [tout] [cost]}"
STATUS="${2:-completed}"
MODEL="${3:-}"
TIN="${4:-0}"
TOUT="${5:-0}"
COST="${6:-0}"

docker exec -i nocodb-postgres-db psql -U nocodb_user -d hermes_brain -t -A -c \
  "SELECT public.log_agent_session('$AGENT', '$STATUS', $( [ -n "$MODEL" ] && echo "'$MODEL'" || echo NULL ), $TIN, $TOUT, $COST);" \
  && echo "logged: $AGENT $STATUS"
