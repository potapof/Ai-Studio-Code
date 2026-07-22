#!/usr/bin/env bash
# Convenience wrapper: перенаправляет вызовы на SDK-версию
# openhands-delegate.sh "<задача>" [--fast] [--timeout N]
exec python3 /home/potapof/studio/scripts/openhands-sdk-delegate.py "$@"
