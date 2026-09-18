#!/usr/bin/env python3
"""Delegator: DeepSeek Harness (dsh) — третий исполнитель Студии (рядом с Holix/OpenHands).

Использование:
  dsh-delegate.py "задача" [--workspace DIR] [--session-id ID] [--timeout SEC]

Ключ: DEEPSEEK_API_KEY из ~/studio/.env (или окружения). Модель: DSH_MODEL
(дефолт deepseek-v4-flash). Сессии: ~/studio/logs/dsh-sessions/<id>.jsonl
"""
import argparse
import os
import sys
import time
from pathlib import Path

SDK = "/home/potapof/studio/.venv-dsh/bin/python"
CONFIG = Path("/home/potapof/studio/dsh/minimal.cordis.yml").resolve()
SESSION_ROOT = Path("/home/potapof/studio/logs/dsh-sessions")

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("task", help="задача агенту")
    ap.add_argument("--workspace", default="/tmp/dsh-workspace", help="рабочий каталог агента")
    ap.add_argument("--session-id", default=None, help="id сессии (по умолчанию dsh-<ts>)")
    ap.add_argument("--timeout", type=int, default=600, help="таймаут, сек")
    args = ap.parse_args()

    ws = Path(args.workspace).resolve()
    ws.mkdir(parents=True, exist_ok=True)
    sid = args.session_id or f"dsh-{int(time.time())}"
    SESSION_ROOT.mkdir(parents=True, exist_ok=True)

    from deepseek_harness import DeepSeekHarness

    print(f"[dsh] session={sid} workspace={ws}", flush=True)
    t0 = time.time()
    with DeepSeekHarness(
        provider="deepseek-official",
        model=os.environ.get("DSH_MODEL", "deepseek-v4.1-flash"),
        max_tokens=49_152,
        cwd=str(ws),
        session_root=str(SESSION_ROOT.resolve()),
        cordis=str(CONFIG),
    ) as harness:
        result = harness.run(args.task, session_id=sid)
    print(f"[dsh] done in {time.time()-t0:.0f}s", flush=True)
    print(result.final_response)

if __name__ == "__main__":
    sys.exit(main())
