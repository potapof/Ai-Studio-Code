#!/usr/bin/env bash
# Convenience wrapper: перенаправляет вызовы на SDK-версию
# openhands-delegate.sh "<задача>" [--fast] [--timeout N]
# Python — из venv Студии: openhands SDK стоит там (системный python3 → ModuleNotFoundError).
exec /home/potapof/studio/.venv/bin/python3 /home/potapof/studio/scripts/openhands-sdk-delegate.py "$@"
