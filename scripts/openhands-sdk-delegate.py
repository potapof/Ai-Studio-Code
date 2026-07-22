#!/usr/bin/env python3
"""
openhands-sdk-delegate.py — выполнить задачу через OpenHands SDK (внутри контейнера).

Использование:
  openhands-sdk-delegate.py [--fast] [--timeout N] [--workspace PATH] <задача>
  openhands-sdk-delegate.py --help
"""
import sys, os, time, argparse, json, subprocess

parser = argparse.ArgumentParser(description="OpenHands SDK delegate")
parser.add_argument("task", nargs="?", help="Текст задачи")
parser.add_argument("--fast", action="store_true", help="deepseek-v4-flash (контейнер openhands-fast)")
parser.add_argument("--timeout", type=int, default=300, help="Таймаут в секундах")
parser.add_argument("--workspace", default="/app/workspace", help="Рабочая директория в контейнере")
args = parser.parse_args()

if not args.task:
    parser.print_help()
    sys.exit(1)

CONTAINER = "openhands-fast" if args.fast else "openhands-outsourcer"
MODEL = "deepseek/deepseek-v4-flash" if args.fast else "deepseek/deepseek-chat"
LABEL = "v4-flash" if args.fast else "deepseek-chat"

# SDK-скрипт для выполнения внутри контейнера. Выводит JSON-результат в stdout.
sdk_script = f'''
import os, time, json, re

# Регистрируем инструменты
from openhands.tools.execute_bash import BashTool
from openhands.tools.file_editor import FileEditorTool
from openhands.tools.task_tracker import TaskTrackerTool
from openhands.sdk.tool.registry import register_tool
register_tool("BashTool", BashTool)
register_tool("FileEditorTool", FileEditorTool)
register_tool("TaskTrackerTool", TaskTrackerTool)

from openhands.sdk import LLM, Agent, Conversation, Tool
from openhands.sdk.security.confirmation_policy import NeverConfirm

llm = LLM(
    model="{MODEL}",
    api_key=os.environ.get("LLM_API_KEY", ""),
    base_url="https://api.deepseek.com",
)

agent = Agent(llm=llm, tools=[
    Tool(name="BashTool"),
    Tool(name="FileEditorTool"),
    Tool(name="TaskTrackerTool"),
])

conv = Conversation(agent=agent, workspace="{args.workspace}")
conv.set_confirmation_policy(NeverConfirm())

task = {json.dumps(args.task)}
conv.send_message(task)

start = time.time()
try:
    conv.run()
    status = str(conv.state.agent_status)
except Exception as e:
    status = f"ERROR: {{e}}"
elapsed = time.time() - start

# Извлекаем ответ агента: сначала ищем FinishAction, потом MessageEvent
result = ""
events = conv.state.events
for e in events:
    kind = str(getattr(e, "kind", ""))
    source = str(getattr(e, "source", ""))
    vis = str(getattr(e, "visualize", ""))
    action = str(getattr(e, "action", ""))
    
    # FinishAction — основной результат tool-using задач
    if "FinishAction" in action:
        # message='...' — учитываем вложенные кавычки через более надёжный парсинг
        idx = action.find("message='")
        if idx >= 0:
            # Ищем закрывающую кавычку с учётом экранирования
            rest = action[idx + 9:]  # после message='
            # message закрывается последней одиночной кавычкой перед закрывающей скобкой или концом
            end = rest.rfind("'")
            if end >= 0:
                result = rest[:end]
                break
    
    # MessageEvent от агента — результат chat-задач
    if kind == "MessageEvent" and source == "agent" and vis and vis != "None":
        result = vis
        break

# Если не нашли — берём последнее visualize от любого события
if not result:
    for e in reversed(events):
        vis = str(getattr(e, "visualize", ""))
        if vis and vis != "None" and len(vis) > 3 and "System Prompt" not in vis:
            result = vis
            break

# JSON-вывод (парсим снаружи)
output = {{
    "status": status,
    "time": round(elapsed, 1),
    "events": len(events),
    "result": result[:4000] if result else "(no output)",
}}
print("HERMES_RESULT:" + json.dumps(output, ensure_ascii=False))
'''

print(f"→ OpenHands SDK ({LABEL}) [{MODEL}]")
start = time.time()

proc = subprocess.run(
    ["docker", "exec", "-i", CONTAINER, "python3", "-c", sdk_script],
    capture_output=True, text=True, timeout=args.timeout + 30
)

elapsed = time.time() - start

# Ищем JSON-результат в выводе
for line in proc.stdout.split("\n"):
    if line.startswith("HERMES_RESULT:"):
        try:
            data = json.loads(line[len("HERMES_RESULT:"):])
            status = data["status"]
            result = data["result"].replace("\\n", "\n").replace("\\t", "\t").replace("\\'", "'")
            if "ERROR" in status:
                print(f"✗ {status}")
            else:
                print(f"✓ {status} ({data['time']}s, {data['events']} events)")
            print(result)
            print(f"→ Done ({elapsed:.1f}s total)")
            sys.exit(0 if "ERROR" not in status else 1)
        except json.JSONDecodeError:
            pass

# Если JSON не найден — что-то пошло не так
print(f"✗ No result (exit={proc.returncode})")
if proc.stderr:
    print(proc.stderr[-2000:])
sys.exit(1)
