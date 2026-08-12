#!/usr/bin/env python3
"""
openhands-sdk-delegate.py — выполнить задачу через OpenHands SDK 1.36.1 (локально, без Docker).

Использование:
  openhands-sdk-delegate.py [--fast] [--timeout N] [--workspace PATH] <задача>

Требования: .venv с openhands-sdk, DEEPSEEK_API_KEY в .env.
"""
import sys, os, time, argparse, json, re

# ── CLI ──────────────────────────────────────────────────────────────────────
parser = argparse.ArgumentParser(description="OpenHands SDK delegate v1.36.1")
parser.add_argument("task", nargs="?", help="Текст задачи")
parser.add_argument("--fast", action="store_true", help="deepseek-v4-flash (быстро)")
parser.add_argument("--timeout", type=int, default=300, help="Таймаут в секундах")
parser.add_argument("--workspace", default="/tmp/openhands-workspace", help="Рабочая директория")
parser.add_argument("--no-browser", action="store_true", help="Отключить browser tools (быстрее старт)")
parser.add_argument("--max-iterations", type=int, default=40, help="Лимит итераций агента (защита от бесконечного цикла; SDK default 500)")
args = parser.parse_args()

if not args.task:
    parser.print_help()
    sys.exit(1)

MODEL = "deepseek/deepseek-v4-flash" if args.fast else "deepseek/deepseek-chat"
LABEL = "v4-flash" if args.fast else "deepseek-chat"
os.environ.setdefault("OPENHANDS_SUPPRESS_BANNER", "1")

# API key: из env или .env файла студии
API_KEY = os.environ.get("DEEPSEEK_API_KEY", "")
if not API_KEY:
    env_file = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env")
    if os.path.exists(env_file):
        for line in open(env_file):
            if line.startswith("DEEPSEEK_API_KEY="):
                API_KEY = line.strip().split("=", 1)[1].strip('"').strip("'")
                break
if not API_KEY:
    print("ERROR: DEEPSEEK_API_KEY not set", file=sys.stderr)
    sys.exit(1)

os.makedirs(args.workspace, exist_ok=True)

# ── SDK ──────────────────────────────────────────────────────────────────────
from openhands.sdk import LLM, Conversation
from openhands.sdk.security.confirmation_policy import NeverConfirm
from openhands.tools.preset import get_default_agent

llm = LLM(model=MODEL, api_key=API_KEY, base_url="https://api.deepseek.com")
agent = get_default_agent(llm=llm)

conv = Conversation(agent=agent, workspace=args.workspace, max_iteration_per_run=args.max_iterations)
conv.set_confirmation_policy(NeverConfirm())

print(f"→ OpenHands SDK 1.36.1 ({LABEL}) [{args.workspace}]")
start = time.time()

conv.send_message(args.task)
conv.run()

elapsed = time.time() - start
status = str(conv.state.execution_status)

# Извлекаем ответ
result = ""
for e in conv.state.events:
    action = str(getattr(e, "action", ""))
    kind = str(getattr(e, "kind", ""))
    source = str(getattr(e, "source", ""))
    vis = str(getattr(e, "visualize", ""))
    if "FinishAction" in action:
        idx = action.find("message='")
        if idx >= 0:
            end = action.rfind("'")
            if end > idx:
                result = action[idx + 9 : end]
                break
    if kind == "MessageEvent" and source == "agent" and vis and vis != "None":
        result = vis
        break
if not result:
    for e in reversed(conv.state.events):
        vis = str(getattr(e, "visualize", ""))
        if vis and vis != "None" and len(vis) > 3 and "System Prompt" not in vis:
            result = vis
            break

# ── Вывод ────────────────────────────────────────────────────────────────────
ok = "FINISHED" in status
print(f"{'✓' if ok else '✗'} {status} ({elapsed:.1f}s)")
if result:
    result = result.replace("\\n", "\n").replace("\\t", "\t").replace("\\'", "'")
    print(result)
else:
    print("(no output)")
print(f"→ Done ({elapsed:.1f}s total)")
sys.exit(0 if ok else 1)
