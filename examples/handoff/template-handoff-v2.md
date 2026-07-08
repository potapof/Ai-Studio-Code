---
handoff_id: <uuid-v4>
task_id: <task-id>
agent: <agent-name>
timestamp: <ISO-8601>
status: success|failure|partial
model: <model-name>
qcl_score: <0-100>
---

# HANDOFF — <task title>

---

## Level 1: Executive Summary (для человека/CEO)

> ≤ 5 пунктов, ≤ 200 слов. Ключевые решения, риски, статус.

1. **Что сделано:** <одно предложение — результат задачи>
2. **Ключевое решение:** <главный архитектурный/технический выбор>
3. **Статус:** ✅ Готово | ⚠️ Частично | ❌ Не выполнено
4. **Риски:** <если есть — одной строкой, иначе «отсутствуют»>
5. **Дальше:** <что делать следующему агенту — одной строкой>

#EXPAND[technical-summary]
#EXPAND[full-detail]

---

## Level 2: Technical Summary (для передачи между агентами)

> ≤ 500 слов. Компоненты, интерфейсы, контракты, исключения.
> Агент следующей фазы читает ЭТОТ уровень. Level 3 — только по #FETCH.

### Context
- Стек: <FastAPI, PostgreSQL, ...>
- Связанные задачи: <issue/PR ссылки>
- Похожие HANDOFF: <найденные через pgvector>
- Ограничения: <бюджет, дедлайн>

### Steps Taken
1. <Шаг 1 — действие + инструмент>
2. <Шаг 2>
3. <Шаг 3>

### Decisions
- <Решение>: <причина>
- <Решение>: <причина>

### Files Modified
- `path/to/file.py` — <что изменено>
- `path/to/other.py` — <что изменено>

### QCL Result
- holix-qa: <score>/100 <✅|❌>
- holix-lint: <score>/100 <✅|❌>
- holix-loop-checker: <score>/100 <✅|❌>
- Итог: <APPROVED|RETURN|HITL>

#EXPAND[qcl-full-trace]
#EXPAND[test-results]
#EXPAND[code-diff]

---

## Level 3: Full Detail (по запросу агента)

> Полные данные. Загружаются только через #FETCH[#EXPAND[key]].

### #EXPAND[qcl-full-trace]
<Полная QCL-трассировка со всеми результатами проверок>

### #EXPAND[test-results]
<Вывод pytest, coverage report, lint output>

### #EXPAND[code-diff]
<Полный diff изменений или ссылка на PR>

### Working Memory
<Текущее состояние: что изменено, что проверено, открытые вопросы>

### Next Steps
- <Задача для следующего агента>
- <Задача для следующего агента>

### Tokens Used
- input: <N>
- output: <N>
- total: <N>
- budget: <N> (<использовано %>)

### Embedding Hints
<ключевые слова для pgvector-поиска: технология, паттерн, домен>
