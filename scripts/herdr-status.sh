#!/usr/bin/env bash
# herdr-status.sh — статусы агентов herdr для цикла оркестрации
# Выводит: панель | агент | статус (idle/working/blocked/unknown) | cwd
herdr agent list 2>/dev/null | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    agents = d.get('result', {}).get('agents', [])
    if not agents:
        print('(no herdr agents)')
    for a in agents:
        print(f\"{a.get('pane_id','?'):8} {a.get('agent','?'):12} {a.get('agent_status','?'):10} {a.get('cwd','')}\")
except Exception as e:
    print(f'parse error: {e}')
" 2>/dev/null || echo 'herdr CLI недоступен (нужен запущенный daemon)'
